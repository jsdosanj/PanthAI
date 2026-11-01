# ipadAI

A free, private, native AI workstation for iPad (M-series, iPadOS 26+) by Dosanjh Labs.
On-device Apple Foundation Models and MLX models, MCP servers, local RAG, GitHub, and SSH/SFTP.
No accounts. No data collected.

See [PLAN.md](PLAN.md) for the architecture, safety model and roadmap.

## Build

```sh
brew install xcodegen
xcodegen generate     # creates ipadAI.xcodeproj from project.yml
open ipadAI.xcodeproj
```

Signing team: Selfless Services Ltd. Archive from Xcode and upload to TestFlight.

## License

MIT. See [NOTICE.md](NOTICE.md) for third-party attributions.
