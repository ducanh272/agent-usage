# Architecture

`AgentUsageApp` is the SwiftUI menu bar executable. `AgentUsageCore` contains the Codex setup check, App Server transport, account response mapping, refresh coordination, presentation helpers, and local storage. The core has no UI dependency, and `UsageProvider` is the boundary for future data providers. Only the current Codex CLI account is supported today.

The app locates the Codex executable, checks `codex login status`, then starts `codex app-server --listen stdio://`. The transport performs the initialize/initialized handshake and sends read-only account requests. `CodexUsageProvider` maps account, quota, and token responses separately, so one missing capability does not hide the others. The transport drains CLI stderr without retaining it and returns sanitized error categories instead of raw protocol output.

`UsageRefreshCoordinator` coalesces refreshes, polls at the selected interval, refreshes after wake or panel opening when needed, and asks for a fresh reading after a quota reset. `UsageRefreshController` connects it to SwiftUI, stores identified account snapshots, and issues optional local notifications. The app shows cached values with their observation time and stale state; passing a reset time never manufactures a new quota value.

`LocalUsageStore` writes settings, account snapshots, and alert deduplication data beneath `~/Library/Application Support/Agent Usage`. Snapshot filenames use a hash of the account ID. See [privacy](privacy.md) for the fields stored and deletion steps. Tests under `Tests/AgentUsageCoreTests` use Swift Testing and synthetic fixtures in `docs/fixtures`.

## Data flow

```text
Codex CLI sign-in → Codex App Server (stdio) → CodexUsageProvider
                                           → UsageRefreshCoordinator
                                           → menu bar panel / local cache / optional alerts
```
