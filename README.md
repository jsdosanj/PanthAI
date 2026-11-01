# PanthAI

A free, private, native AI workstation for iPad (M-series, iPadOS 26+) by Dosanjh Labs.
No accounts. No data collected. Open source (MIT).

- **Models:** Apple Foundation Models (on-device and Private Cloud), MLX models you download, Claude / OpenAI / GitHub Models by API key, and LM Studio or Ollama on your own network.
- **Work:** tools that edit your GitHub repos (diffs, undo, commit, pull requests), web search, a JavaScript sandbox, MCP connectors, memory, agents, and Shortcuts tasks.
- **SSH:** a real terminal, SFTP file manager, Claude Code or Codex on your own machine.
- **Lab:** compare models, benchmark, evals, LoRA fine-tuning, request inspector.
- **Trust:** a network activity log, offline mode, Face ID lock. See [SECURITY.md](SECURITY.md).

## Build it (about 15 minutes the first time)

You need a Mac with **Xcode 27** (iOS 27 SDK) and, to run real models, an **M-series iPad**. The simulator runs the UI but not Apple Intelligence or MLX.

```sh
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain     # MLX needs it; the build fails without it
xcodegen generate                                # makes PanthAI.xcodeproj from project.yml
open PanthAI.xcodeproj
```

1. In Xcode, select the **PanthAI** target › Signing & Capabilities and choose your own team (the project ships with Dosanjh Labs' team ID).
2. When Xcode asks, choose **Trust & Enable** for the Swift packages' macros.
3. Pick your iPad (or an iPad simulator) and press Run. The first build compiles MLX and takes several minutes.

From the command line:

```sh
xcodebuild -project PanthAI.xcodeproj -scheme PanthAI -destination 'generic/platform=iOS' \
  -skipMacroValidation -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
```

## Test

```sh
xcodebuild -project PanthAI.xcodeproj -scheme PanthAI \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -skipMacroValidation -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO test
```

The unit tests cover the safety rules (path confinement, redaction, command guard, network policy), the tool protocol, diffs, and model-fit estimates. `ScreenSmokeTests` builds every screen in a window and saves PNGs to `/tmp/panthai-shots`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `cannot execute tool 'metal'` | `xcodebuild -downloadComponent MetalToolchain` |
| "Macro … must be enabled before it can be used" | Trust & Enable in Xcode, or add `-skipMacroValidation` |
| `Device isn't registered in your developer account` | Build once with `-allowProvisioningUpdates -allowProvisioningDeviceRegistration`, or add the device in Xcode |
| Package resolution conflict on `mlx-swift` | `mlx-swift-lm` pins a matching `mlx-swift`; keep both in step in `project.yml` |

## Layout

`App/Sources` is grouped by feature: `Chat`, `InferenceKit` (providers), `Tools` (what the assistant can do), `MCP`, `Remote` (SSH), `Lab`, `Security`, `Network`, `Shell` (windows and sidebar). `project.yml` is the source of truth for the Xcode project; `*.xcodeproj` is generated and ignored.

See [PLAN.md](PLAN.md) for the original architecture and [CONTRIBUTING.md](CONTRIBUTING.md) to help.

## License

MIT. See [NOTICE.md](NOTICE.md) for third-party attributions.
