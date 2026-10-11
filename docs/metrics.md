# Metrics and compatibility

The app reads the current signed-in account through Codex App Server. CLI `0.159.3` was verified on October 10, 2026 with `account/read`, `account/rateLimits/read`, and `account/usage/read`. It is the only version verified for this project. The methods may change in other versions; unsupported token activity is displayed as unavailable independently of quota. See [protocol findings](codex-protocol.md) for the observed response shape.

| Display | Source and meaning |
| --- | --- |
| Quota window | A primary or secondary window returned by `account/rateLimits/read`. The app prefers `rateLimitsByLimitId` and uses the legacy `rateLimits` field only as a fallback. |
| Remaining % | `100 - usedPercent`, bounded to 0–100 for display. It is a quota percentage, not a token balance. The menu bar uses the lowest available remaining percentage. |
| Reset time | The provider's `resetsAt` timestamp. When it passes, the app requests new data; it does not assume quota was restored. |
| Lifetime tokens | `summary.lifetimeTokens` from `account/usage/read`, if present. This is account activity, not a billable total. |
| Peak day | `summary.peakDailyTokens`, if present. |
| Daily tokens | `dailyUsageBuckets` dates and token counts, when present. The panel shows the most recent five buckets. |
| Last updated | Time of the last successful account read. Saved data is marked stale after ten minutes. |

Each internal metric records its source, account scope, and observation time. Missing fields and unsupported methods appear as unavailable, never as zero. The app does not calculate model-level usage, costs, or billing reconciliation.
