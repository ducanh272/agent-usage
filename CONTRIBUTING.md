# Contributing

Build on macOS 14 or later with a compatible Swift 6 toolchain and macOS SDK. Run `swift test --disable-sandbox` from the repository root, then `sh scripts/build-app.sh`. The Command Line Tools setup used by this project needs the SDK, cache, and Swift Testing plugin arguments shown in `README.md`. Use Swift Testing (`import Testing`, `@Test`, `#expect`) for new unit tests.

Keep changes small and include tests for behavior that can fail independently. Use synthetic, sanitized fixtures for Codex responses. Do not commit account identifiers, email addresses, authentication files, raw App Server logs, or conversation content. If a Codex response changes, record the CLI version and update `docs/codex-protocol.md`, the mapper, and its tests together.

Before proposing a release, run the tests and app bundle build, review the package contents, and complete the manual checks tracked in Tasks 14 and 15 of `PLAN.md`. `scripts/package-release.sh` can create a local preview package without release credentials; publishing is a separate maintainer action.
