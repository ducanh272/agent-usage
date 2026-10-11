# Agent Usage

An MIT-licensed macOS 14+ menu bar app for Codex account usage. The panel shows quota windows, reset countdowns, and available account token activity. It checks the Codex CLI installation and ChatGPT sign-in, refreshes in the background every five minutes by default, and offers manual refresh. Saved readings stay visible with dated stale or disconnected labels.

The menu bar shows the lowest remaining Codex quota percentage beside its icon. Settings offers icon-only mode. When current quota is unavailable, the percentage is replaced by a dash.

Quota reset times trigger an early refresh. An expired reset or failed refresh keeps the last reading labeled stale until Codex returns a new quota reading; the panel provides recovery steps for sign-in, CLI, and version problems.

Settings can enable local quota alerts at 20% and 5% remaining and register the packaged app to launch at login. Both are off by default. Alerts use fresh account readings, and sent alert keys are saved locally so a restart does not repeat them.

Settings offers refresh intervals of 1, 5, or 15 minutes and a confirmed cache clearing action. The app finds Codex automatically and uses its existing CLI sign-in, including a custom `CODEX_HOME` when set. The panel explains what account data it reads and provides keyboard shortcuts for Refresh (Command-R), Settings (Command-Comma), and Quit (Command-Q).

Settings and account snapshots are stored locally in `~/Library/Application Support/Agent Usage`. Snapshots are separated by account and include only account identity and usage readings, not credentials or conversation content. Cached readings are labeled and become stale after ten minutes.

## Requirements and setup

Install the Codex CLI and sign in to a ChatGPT Plus account with `codex login`. Agent Usage uses the CLI's current account and does not need a separate login. CLI `0.159.3` is the version verified for the account methods used here. Other versions have not been verified; the app reports unavailable methods when it can. See [metrics and compatibility](docs/metrics.md).

## Build and test

Requires Swift 6 and a compatible macOS SDK. From the repository root, run:

```sh
swift test --disable-sandbox
sh scripts/build-app.sh
open .build/AgentUsage.app
```

On the current development Mac, the installed Swift compiler needs a specific SDK and writable caches:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/agent-usage-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/agent-usage-swift-cache \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
swift test --disable-sandbox \
  -Xswiftc -plugin-path \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
CLANG_MODULE_CACHE_PATH=/private/tmp/agent-usage-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/agent-usage-swift-cache \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
sh scripts/build-app.sh
open .build/AgentUsage.app
```

The app runs in the menu bar without a Dock icon. Click its chart icon to see setup status and recheck sign-in. Open `Package.swift` in Xcode to work on the app and core module.

The app bundle build omits debug symbols so it can run inside restricted command sandboxes. CI runs tests and builds the app on macOS. See [architecture](docs/architecture.md), [privacy](docs/privacy.md), and [contributing](CONTRIBUTING.md).

## Package a preview or signed release

`sh scripts/package-release.sh` builds `.build/AgentUsage.app` and writes a versioned ZIP, release notes, and SHA-256 checksum file to `dist/`. The version comes from `Resources/Info.plist`. With no credentials, the ZIP is named `AgentUsage-0.1.0-unsigned-preview.zip`: its ad hoc signature only supports local launch. This preview is not notarized and may require an explicit macOS approval to open.

For a Developer ID build, install a valid **Developer ID Application** certificate in the signing keychain and set `SIGNING_IDENTITY` to its identity name or hash. To notarize, first store maintainer credentials in an `xcrun notarytool` keychain profile, then set `NOTARY_PROFILE` to that profile name. The packaging script submits the ZIP, waits for acceptance, staples the app, recreates the ZIP, and computes checksums from the final files. It exits on notarization failure. Do not place signing credentials in this repository.

```sh
SIGNING_IDENTITY='Developer ID Application: Example (TEAMID)' \
NOTARY_PROFILE='agent-usage' \
sh scripts/package-release.sh
cd dist && shasum -a 256 -c AgentUsage-0.1.0-SHA256SUMS.txt
```

A Developer ID package without `NOTARY_PROFILE` is signed but not notarized. Check the package status before sharing it. Publishing the package is a separate action. See [release notes](RELEASE_NOTES.md); Tasks 14 and 15 in [PLAN.md](PLAN.md) still track core and manual validation before a general release.
