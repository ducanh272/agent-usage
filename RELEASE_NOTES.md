# Agent Usage 0.1.0 — preview

This is an **unsigned preview** when downloaded as `AgentUsage-0.1.0-unsigned-preview.zip`. Its app bundle has an ad hoc signature for local launch; it has no Developer ID signature or Apple notarization. A later `AgentUsage-0.1.0-macos.zip` package is only a signed release if the maintainer builds it with a Developer ID certificate. Check the package's signing and notarization status before distributing it.

## Included

- macOS 14+ menu bar app showing Codex quota windows, remaining percentages, and reset times.
- Account token activity when the installed Codex CLI returns it.
- Local cache with stale labels, configurable refresh interval, optional quota alerts, and optional launch at login.
- Setup and sign-in recovery guidance.

## Requirements and current limits

- Codex CLI installed and signed in with ChatGPT Plus. CLI `0.159.3` was verified against the account methods used by this version; other CLI versions have not been verified.
- Token activity is account-wide. Model breakdown, billing totals, and conversation content are not provided.
- Complete manual validation in Tasks 14 and 15 of `PLAN.md` remains open. Treat this build as a preview until those checks are complete.

See `README.md` for setup, data definitions, privacy details, and checksum verification.
