# PanthAI — Plan v1

A free, private, native iPadOS AI workstation by Dosanjh Labs. Runs Apple Foundation Models and MLX models on-device, optionally calls remote providers, connects to remote MCP servers, indexes your files/photos locally, works on GitHub repos and SSH/SFTP hosts, and never collects user data.

UX and agent architecture are modelled on [Osaurus](https://github.com/osaurus-ai/osaurus) (MIT) — agents, memory, tools/skills, MCP client, plan/auto modes — rebuilt for iPadOS with a stricter safety model.

## 1. Decisions locked

| Area | Decision |
|---|---|
| Distribution | TestFlight first, then App Store. Built and uploaded from Xcode. |
| Platform | iPadOS 26+, M-series iPads only. SwiftUI, Swift 6 strict concurrency. English only (all strings still go through String Catalogs so adding languages later is cheap). |
| Name / ID | PanthAI, bundle ID `com.dosanjhlabs.panthai`, listed as a Dosanjh Labs product. |
| Price | Free forever. No ads, IAP, accounts, or analytics SDKs. |
| Privacy | App Store label "Data Not Collected". Crash reports come only from Apple's Xcode Organizer / MetricKit (user opts in at OS level). No third-party SDKs touch user data. |
| Model backends | (1) Apple Foundation Models, (2) MLX local models, (3) remote providers (OpenRouter first, then OpenAI-compatible, Anthropic). |
| Terminal | A sandboxed command interpreter we write — not a real shell. Fixed allowlist, no downloaded executables (App Store 2.5.2). |
| Agent modes | Suggest (user approves each command), Auto, Plan, Scheduled. |
| MCP | Remote only, HTTPS (streamable HTTP/SSE), OAuth 2.1 + DCR or pasted token, tokens in Keychain. Per-tool approval prompts. |
| Sync | iCloud (CloudKit via SwiftData): settings, chats, MCP configs, SSH hosts. Secrets via iCloud Keychain. RAG indexes and model files stay local. |
| RAG | Photos, Files, drag-drop. Vision OCR for images/PDFs. Per-source toggle. All on-device. |
| Network | Rely on the Tailscale iOS app being connected. MagicDNS names and 100.x addresses just work. SSH + SFTP only (no plain FTP). |
| GitHub | Full workflow: clone, branch, edit, commit, push, PRs, issues, public + private repos. |

## 2. Things the platform will not let us do (read these)

1. **Scheduled runs are best-effort.** iOS does not allow GPU/Metal work in the background, so **local MLX inference cannot run while the app is backgrounded**. `BGProcessingTask` is also opportunistic — iOS decides when. So:
   - Scheduled jobs using remote models/MCP/Foundation Models-free steps can run in background tasks (best-effort, no guaranteed time).
   - Jobs needing local MLX run when the app is next foregrounded, or while it is open. A local notification tells the user "N scheduled runs are ready".
   - The UI must say this plainly. We should not promise cron semantics.
2. **Memory.** iPadOS kills apps that exceed their jetsam limit. We need the `increased-memory-limit` entitlement and a memory manager that refuses to load a model that won't fit (this is also what powers the compatibility badges). 16 GB iPads (Pro, 1 TB+) can hold roughly 8–10 GB for the app; 8 GB iPads far less.
3. **No stdio MCP servers.** Remote-only, as decided.
4. **No in-app Tailscale.** If the Tailscale app isn't connected, SSH to tailnet hosts fails; we detect and explain.
5. **Secure Enclave SSH keys** only support P-256 and need a custom signer. v1 uses Ed25519 keys in the Keychain (this-device-only, not synced). Secure Enclave is a stretch goal.
6. **Osaurus can't be copied wholesale.** It depends on macOS-only pieces (Containerization VMs, Sparkle, a NIO HTTP server, plugin dylibs). We reuse ideas and, with MIT attribution, small portable pieces — not the package.
7. Apple guideline 4.2/2.5.2 risk: a "coding agent that runs commands" draws scrutiny. Mitigations are the allowlisted interpreter, no remote code download, and clear review notes. Keep TestFlight external testing as the fallback.

## 3. Safety model ("no destructive commands")

Defence in depth, strictest layer wins:

1. **Sandbox.** The interpreter can only touch the app container + user-granted security-scoped folders. No path escapes (canonicalise, reject `..`/symlinks out).
2. **Command allowlist.** Local commands are a fixed set (`ls cat grep find head tail wc diff mkdir touch cp mv git curl-less…`). Anything unknown is rejected, never passed through. No `eval`, no network fetch-and-run.
3. **Risk classes** on every tool and command: `read` → auto-allowed; `write` → approval unless the user raised trust for this agent; `destructive` → **hard denied locally** (recursive delete, overwrite outside the project, force-push default branch, etc.), and on SSH requires typed confirmation of the host name + command preview.
4. **Per-tool MCP approval** with the exact arguments shown. Servers that can move money or delete resources (Stripe, Cloudflare, Render) default to read-only until the user enables write tools per server.
5. **Auto mode** is bounded: allowlisted `read`/`write` only, step and token budgets, a visible kill switch, and an audit log you can export.
6. **Prompt-injection hygiene.** Content from files, web, MCP, and repos is marked untrusted; tool calls that originate after untrusted content require approval regardless of mode.
7. **Secrets** never enter prompts, logs, or sync payloads; redaction pass on tool output.

## 4. Architecture

Swift package split (one Xcode app target + local packages), so each module is testable on its own:

- `AppShell` — SwiftUI scenes, multi-window (`WindowGroup` + `openWindow`, per-window chat/terminal/repo), `NavigationSplitView`, keyboard shortcuts, drag & drop, Stage Manager/external display.
- `InferenceKit` — `ModelProvider` protocol; `FoundationModelsProvider`, `MLXProvider` (mlx-swift + mlx-swift-lm), `RemoteProvider` (OpenRouter / OpenAI-compatible / Anthropic). Streaming, tool calling, cancellation, single resident-model scheduler.
- `ModelStore` — Hugging Face catalog browse, background `URLSession` downloads (resumable), checksum, storage manager (sizes, delete, "optimise storage"), excluded from iCloud backup.
- `MemoryKit` — device profile (chip, RAM, `os_proc_available_memory`), model footprint + KV-cache estimator, compatibility badges (Runs great / Runs / Tight / Won't fit), load-time guardrails, thermal-state throttling.
- `AgentKit` — agents (prompt, tools, memory, theme), modes (suggest/auto/plan/scheduled), plan-then-execute loop, step budgets, audit log, command suggestion.
- `MCPKit` — wraps the official `modelcontextprotocol/swift-sdk` client; OAuth via `ASWebAuthenticationSession`; one-tap catalog (GitHub, Cloudflare, Stripe, Clerk, Resend, Hugging Face, Canva, OpenRouter, pCloud, Render, Expo…); per-tool policy.
- `RAGKit` — ingestion pipeline (PhotoKit, `UIDocumentPicker`, drop), Vision `VNRecognizeTextRequest` OCR, PDFKit text, chunking, embeddings (MLX embedding model, `NLContextualEmbedding` fallback), local vector store (SQLite + vector index), per-source toggles, reindex/purge.
- `SandboxShell` — interpreter, command registry, risk classifier, virtual FS.
- `RemoteKit` — SSH/SFTP via `apple/swift-nio-ssh` + Citadel, host-key pinning (TOFU with change warnings), key management, Tailscale status hint.
- `GitKit` — libgit2-based clone/branch/commit/push + GitHub REST/GraphQL for PRs and issues; GitHub OAuth device flow or fine-grained PAT; diff + editor view. **Needs a spike** (see §6).
- `SyncKit` — SwiftData models with CloudKit, iCloud Keychain wrapper.
- `Security` — Keychain, approvals, redaction, audit log.
- `DesignSystem` — Liquid Glass per the HIG, Dynamic Type, VoiceOver labels/rotor actions, Reduce Motion/Transparency, high contrast.

Performance targets: cold launch < 1 s to interactive, first token from a resident model < 300 ms, 120 Hz scrolling in long chats (lazy stacks, incremental markdown rendering off the main actor), model load on a background actor with progress.

## 5. Phased roadmap

- **Phase 0 — Foundations (1–2 days).** Xcode project, entitlements (increased memory, iCloud, background modes), CI skeleton, DesignSystem, SwiftData+CloudKit schema, privacy manifest (`PrivacyInfo.xcprivacy`).
- **Phase 1 — Chat + models.** Foundation Models chat, streaming UI, multi-window, MLX provider with one hand-picked model, MemoryKit badges, background downloads + storage manager. **First TestFlight build.**
- **Phase 2 — Remote providers + MCP.** OpenRouter, MCP client with OAuth, per-tool approval UI, Keychain, iCloud sync of configs.
- **Phase 3 — RAG.** Files + drag-drop, then Photos, Vision OCR, per-source toggles, purge.
- **Phase 4 — Sandbox shell + agents.** Interpreter, risk classes, suggest mode, then plan and auto modes, audit log.
- **Phase 5 — GitHub.** Spike, then clone/edit/commit/push, PRs/issues, editor.
- **Phase 6 — SSH/SFTP + Tailscale awareness.**
- **Phase 7 — Scheduling.** Per §2.1 semantics.
- **Phase 8 — Hardening + App Store.** Accessibility audit, perf pass, security review (`/cso`), threat model, review notes, App Store listing, privacy label.

## 6. Risks / spikes to run early

1. **libgit2 on iOS** — pick a maintained Swift wrapper (SwiftGitX vs. building libgit2 ourselves) and prove HTTPS clone/push of a private repo with a token on-device. If it fails, fall back to the GitHub Git Data API (no local `.git`).
2. **MLX on iPad memory ceilings** — measure real loadable model sizes on the target iPads before fixing the badge thresholds.
3. **App Review** for the command-suggestion/auto-agent features.
4. **Name collision** — check "PanthAI" on the App Store before investing in branding.

## 7. Open items for you

1. Run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` (type `! sudo xcode-select -s …` in the prompt). Xcode is installed, but the active developer directory is still Command Line Tools, so `xcodebuild` can't run yet.
2. Apple Developer Team ID for signing, and a physical M-series iPad for testing (the simulator can't run MLX/Metal faithfully)?
3. Should private SSH keys and MCP tokens sync via iCloud Keychain (convenient, end-to-end encrypted) or stay on one device? Default here: MCP tokens sync, SSH private keys don't.
4. Which MLX models should be the curated defaults (a small ~1–2B, a mid ~4B, a larger ~8B tier)?
5. Repo license: open source (MIT like Osaurus) or closed?
6. Git identity: this machine's git email is `jasvant@omnigroup.com`. I'll set the repo-local identity to your GitHub noreply address before committing — what's that address, or should I look it up?
