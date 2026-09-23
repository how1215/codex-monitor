# Codex Usage Monitor Architecture

## Purpose and boundaries

Codex Usage Monitor is a native macOS 14+ menu bar app. It starts the locally installed Codex CLI App Server and reads ChatGPT account and Codex quota data over stdio JSONL. It does not read authentication files or tokens, estimate quota from local token counts, purchase paid resets, or provide arbitrary quota clearing.

## Components

| Component | Responsibility |
| --- | --- |
| `CodexMonitorApp` | Menu bar scene and shared monitor and floating panel. |
| `UsageMonitor` | UI state, coalesced event-driven refresh, five-minute polling, manual Energy Saving Mode, wake refresh, reconnection, and reset workflow. |
| `CodexAppServerClient` | Actor-isolated JSON-RPC request correlation, timeout, cancellation, and server events. |
| `AppServerTransport` / `ProcessAppServerTransport` | Injectable stdio transport and local Codex child-process lifecycle. |
| `JSONLMessageBuffer` | Bounded line framing and malformed-message detection. |
| `UsageParser` | Account, quota, credit, and reset models. |
| `ResetAttemptStore` | Persists an unconfirmed reset's opaque credit ID and idempotency key. |
| `MonitorView` | Quota display, countdowns, sign-in, reset, and settings. |
| `FloatingPanelController` | Always-on-top panel across Spaces. |

## Data flow

1. Locate an executable `codex` in PATH or known local installation paths.
2. Start `codex app-server --listen stdio://` and complete `initialize` / `initialized`.
3. Read `account/read`; only a ChatGPT account proceeds to `account/rateLimits/read`.
4. Account and login notifications trigger a full refresh. Rate-limit notifications trigger a quota-only refresh after a 250 ms coalescing window. Poll every five minutes for a full fallback synchronization and refresh after system wake. Opening a panel triggers a quota-only refresh if the last successful read is over 60 seconds old.
5. Compute countdowns locally from official `resetsAt` timestamps using one shared one-second timeline while the view is visible.

Energy Saving Mode is off on every launch. When enabled, it cancels polling, event refreshes, and reconnection, then stops the App Server. Opening a panel or waking the Mac does not fetch data. Refresh temporarily starts the server, reads account and quota, and stops it again; sign-in and reset have their own temporary connection lifetimes. Browser and device-code sign-in keep the server running until completion, cancellation, or a ten-minute timeout. The menu bar labels the retained value as paused. Visible countdowns use deadline-aligned minute updates and switch to seconds in the final minute; hidden views schedule no countdown work. The snapshot's Updated label uses a fixed timestamp in this mode.

The menu bar and primary summary select the highest `usedPercent` among windows with `windowDurationMins == 300`, breaking ties by earliest reset time. A compact one-week summary uses the same rule for `windowDurationMins == 10080`. Clock and calendar headings distinguish the summaries. The primary summary omits the repeated five-hour window caption. Both display remaining quota (`100 - usedPercent`), used percentage, and reset countdown; their bars fill to the remaining percentage. Other windows remain in expandable details, where bars fill to the used percentage. Reset and credit values occupy a separate card with internal dividers; Settings uses grouped system-colored rows. The menu bar dot and panel progress bars use the same usage thresholds: green below 50% used, yellow from 50%, red from 80%, and gray when data is unavailable or stale. Hover help and the accessibility label identify the five-hour remaining-quota context. This is a presentation of the last fetched backend value, not a local usage estimate.

The menu bar panel and floating window share `MonitorView` cards and controls. Content scrolls while the header and actions remain available. `ViewThatFits` stacks the five-hour and one-week cards at narrow widths and places them side by side when the floating window is wide enough. Dynamic macOS system colors support light and dark appearances. The floating `NSPanel` keeps standard window controls and closes through its own Close Window action.

Events arriving during a refresh request one additional synchronization after the current one completes. Account changes clear any previous account's visible quota snapshot.

## Reliability and reset safety

- Requests use unique IDs, a 15-second timeout, and Swift task cancellation. Process termination fails all pending requests.
- JSONL framing supports partial and multiple messages and rejects malformed or oversized lines. An async stream preserves chunk order before actor parsing.
- App termination awaits monitor shutdown so the child App Server process is stopped before the app exits.
- Reconnection uses bounded exponential backoff: 2, 4, 8, 16, then 30 seconds with up to 0.5 seconds of jitter.
- A reset request is sent only after its UUID idempotency key and optional credit ID have been stored. Timeout or disconnect preserves the attempt. Retrying reuses the original key.
- A corrupt recovery record blocks any new reset until the user explicitly discards it after checking the account. A valid pending attempt is never discarded automatically.
- Terminal reset outcomes (`reset`, `alreadyRedeemed`, `nothingToReset`, `noCredit`) clear the record, followed by a fresh rate-limit read. The app never infers a new quota from a reset response.

## Security and privacy

- App Server communication remains local. No analytics, telemetry, or token access is implemented.
- Browser and device-code URLs must use HTTPS on OpenAI or ChatGPT domains; userinfo and explicit ports are rejected.
- Reset storage contains only a UUID, optional opaque credit ID, and timestamp.
- App Server stderr is not written to ordinary logs.

## UI states

`loading`, `ready`, `stale`, `signedOut`, `unsupportedAuth`, `incompatibleResponse`, `cliMissing`, and `offline` are explicit states. Stale data remains visible with its last successful update time; signed-out and unsupported accounts do not display the previous account's quota.

## Tests and packaging

Tests use mock services and an injectable fake transport. They cover parser compatibility, JSONL framing, request correlation, timeout, cancellation, server errors, process termination, authentication states, reset eligibility and retry across restarts, corrupt recovery, URL validation, and reconnect delays. Tests never call the live reset endpoint. An opt-in `CODEX_MONITOR_REAL_SMOKE=1` test reads only account and rate-limit data from an installed Codex CLI.

`scripts/build-app.sh` packages a release build and ad-hoc signs the local app. CI builds, tests, packages, validates the plist, and verifies the signature on macOS. This repository distributes source only; Developer ID signing, notarization, and downloadable releases are not configured.

## Maintenance rules

- Record user-visible changes in `CHANGELOG.md` under `Unreleased` before a version bump.
- Add fixture tests for new App Server fields and remain backward compatible where possible.
- Reset behavior changes require failure, timeout, and retry coverage. Never use the live reset endpoint in tests.
- Do not put real account data, tokens, or authentication URLs in logs, fixtures, or analytics.
