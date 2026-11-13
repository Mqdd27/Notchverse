# Contributing

- Pure logic goes in `Sources/LyricsCore` (no AppKit) with a test in `Tests/LyricsCoreTests`.
- App code (AppKit/SwiftUI) goes in `App/`.
- Do not copy code from GPL projects (e.g. boring.notch). MPL code (LyricsX) only with MPL compliance.
- Never commit lyrics data.
- Run `swift test` and `scripts/build-app.sh` before opening a PR. Mention which players you tested manually.
