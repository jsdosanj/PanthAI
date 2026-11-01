# Contributing

Thanks for helping. A few rules keep the app safe and fast.

1. **Branch, then pull request.** Don't push to `main`.
2. **Run the tests** (see the README) and add one for any safety rule or parser you touch.
3. **No new data collection.** No analytics SDKs, no servers. Every network call must go through `AppNet.session` so it shows in the activity log and respects offline mode.
4. **Tools are a security boundary.** A new tool needs a risk level (`read`, `write`, `network`, `networkWrite`, `execute`, `remote`) and must be confined to its folder, redact secrets in output, and ask for approval unless it is read-only. Read `SECURITY.md` first.
5. **Follow Apple's design guidelines.** Native controls, Dynamic Type, 44 pt touch targets, labels on icon-only buttons, Liquid Glass only for controls floating over content.
6. **Edit `project.yml`, not the `.xcodeproj`.** Then run `xcodegen generate`.
7. **Secrets** (API keys, tokens, SSH keys) belong in the Keychain through `Keychain`, never in `UserDefaults`, files, logs or tests.

Report security problems privately through a GitHub security advisory.
