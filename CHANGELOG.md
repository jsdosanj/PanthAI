# Changelog

## 0.1.0 build 3
- Fixed: models wouldn't download ("unable to resolve cached file path for tokenizer.json"). Downloads no longer use the Hugging Face cache; each file is fetched, size-checked and placed in a plain folder.
- Background downloads: model downloads continue when you switch apps or lock the iPad, resume after the app is closed, and notify you when done.
- Knowledge (RAG): add text, notes, code, PDFs (scanned pages are read with text recognition) and photos (text recognition plus what they show) from Files, Photos or by drag and drop. Search combines meaning (on-device embeddings) and keywords. Chats look up your documents automatically; code sessions get a search tool. Stored only on the iPad, not synced, not backed up.
- Optional iCloud sync (off by default): chats, agents, templates, tasks, providers, connectors, SSH hosts (no keys) and settings, through your own private iCloud.
- Fixed: App Store rejection over App Intent descriptions (build 2).
- Fixed: git push keeps the executable bit; reloading a repo asks before replacing unpushed edits; Siri and the open chat no longer overwrite each other; saved history is redacted; a sturdier remote-command guard.

## 0.1.0 (first TestFlight build)
- Chat on Apple Foundation Models, MLX models, cloud providers and LM Studio.
- Code sessions with GitHub repos, file tools, diffs, undo, commit, pull requests, CI help.
- MCP connectors, memory, agents, web search, JavaScript sandbox, Shortcuts tasks, Siri.
- SSH terminal, SFTP, Claude Code and Codex over SSH.
- Lab: compare, benchmark, evals, fine-tuning, request inspector.
- Network activity log, offline mode, Face ID lock, redaction, prompt-injection guard.
