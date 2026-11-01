# PanthAI security

What the app does to protect you, and where the limits are.

## Data
- **No accounts, no analytics, no servers of ours.** The privacy manifest declares no collected data.
- **Network activity log** (Settings › Privacy & network) lists every request the app makes. **Offline mode** blocks them all.
- Chats, memory and repos stay on the iPad unless you turn on iCloud sync (Settings › iCloud, off by default). Sync then sends chats, agents, templates, tasks, provider and connector settings, SSH host entries (never keys or passwords) and a short list of preferences to your own private iCloud (CloudKit and the key-value store). It is handled by iPadOS, so it is not in the network activity log, and it is paused in offline mode. Model files, Knowledge, repository files and security switches never sync.
- Knowledge (documents and photos you add) keeps only extracted text, in its own local store that is excluded from backups. Document text is treated as untrusted: after the assistant reads it, anything that changes something asks first, the same as after a web page.
- Files are encrypted by iPadOS until first unlock; **Maximum file protection** re-encrypts them whenever the iPad is locked.
- **Erase all data** removes chats, memory, repos, models, keys and tokens.

## Secrets
- API tokens live in the Keychain (iCloud Keychain, end-to-end encrypted). SSH keys and passwords are stored **on this iPad only**, readable only after Face ID, Touch ID or passcode when "Require Face ID for SSH keys" is on.
- Secret-looking text (private keys, tokens, `password=`) is removed from tool output before a model sees it or it is saved.
- Network activity records only host, path and size, never request contents or query strings.

## The app itself
- Optional **Face ID / passcode lock** with a grace period, and a privacy shield that blurs content in the app switcher.
- App Transport Security stays on. The only exception is local-network HTTP (LM Studio, Ollama).

## What the assistant can do
- It has no shell on the iPad. Tools are a fixed set; there is no way to run downloaded code.
- Reads are automatic. Edits, code runs, pushes, connector calls and remote commands ask first. Edits are diffed and undoable.
- After a chat reads the web, a connector or a remote machine, "always allow" and auto-accept stop applying, because that content could carry hidden instructions (prompt injection).
- Paths are confined to the repo; `..` and absolute paths are rejected. Pushes to a repo's default branch are refused.
- Remote commands matching destructive patterns (`rm -rf /`, `mkfs`, `dd of=/dev`, shutdown…) are refused even if approved.
- JavaScript runs in a web view with network access blocked and a 10-second limit.
- Scheduled (Shortcuts) tasks cannot ask for approval, so anything needing approval is declined.

## SSH
- Host keys are pinned on first trust; a changed key is refused, not prompted.
- Ed25519 keys are generated on the iPad; the private key is never shown or exported.

## Remote commands
- The remote-command guard is a best-effort filter that refuses obviously destructive commands (recursive deletes of system or home folders, `find -delete`, piping downloads into a shell, writing to disks, shutdown). It is not a security boundary; every remote command still needs your approval.

## Honest limits
- Prompt injection is mitigated, not solved. Read approval prompts.
- Apple's Private Cloud Compute model and sign-in sheets are handled by iPadOS and don't appear in the network log.
- A model that is allowed to run commands on your machine over SSH or Claude Code/Codex can do whatever your account can. Use a restricted account for anything sensitive.
- No jailbreak or debugger detection: it is easy to bypass and gives false assurance.

Report a vulnerability by opening a private security advisory on the GitHub repository.
