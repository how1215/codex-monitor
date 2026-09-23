# Changelog

User-visible changes follow the Keep a Changelog format. Versions use Semantic Versioning.

## [Unreleased]

### Added

- An optional Energy Saving Mode that pauses background updates and stops the Codex App Server. Refresh reads a new snapshot on demand; the setting resets to off when the app restarts.
- Distinct clock and calendar headings with a divider between the five-hour and one-week summaries.

### Changed

- In Energy Saving Mode, visible reset countdowns update by the minute until their final minute, then by the second. Sign-in and earned resets temporarily connect only while needed.
- The panel removes the redundant five-hour window caption, separates resets and credits from quota, and groups settings into system-style rows.

## [0.5.0] - 2026-09-23

### Changed

- The menu bar now shows five-hour quota remaining instead of quota used. Its accessibility label and hover help state the new meaning.
- The panel leads with the most constrained five-hour window's remaining quota and reset countdown. The one-week window appears beneath it in a compact summary; other windows are available in an expandable section.
- The menu bar, summary, and window progress bars use the same warning thresholds: 50% and 80% used.
- Full fallback synchronization now runs every five minutes. Opening a panel refreshes quota in the background when the last successful read is over one minute old.

## [0.4.0] - 2026-09-16

### Added

- A color-coded five-hour usage indicator in the menu bar: green below 50%, yellow from 50%, and red from 80%. Unavailable or stale data uses gray.
- Accessibility text for the menu bar usage indicator and tests for its threshold behavior.

### Changed

- The menu bar shows only a compact color dot and usage percentage; Codex and five-hour context remain in its accessibility label and hover help.
- Rate-limit notifications now read quota only; account notifications and the 60-second fallback still perform full synchronization. Closely spaced notifications are coalesced for 250 milliseconds.
- The one-second countdown timeline runs only while its view is visible.
- The usage panel scrolls when needed, supports a wider floating window, groups settings and diagnostics, and shows relative update age and clearer stale-data messaging.
- The floating panel has a minimum size and remembers its frame.

### Fixed

- Restored visible usage bars and quota details when opening the menu bar panel; scrolling remains limited to the floating window.

## [0.3.0] - 2026-09-16

### Added

- Explicit unsupported-account and incompatible-response states.
- Device-code sign-in when browser sign-in is unavailable.
- Fail-closed reset recovery and a confirmed way to discard a corrupt recovery record.
- Wake-triggered refresh, resolved Codex CLI path diagnostics, and bounded JSONL framing.
- Ordered App Server output processing and clean child-process shutdown on app quit.
- Injectable App Server transport with request correlation, timeout, cancellation, and termination tests.
- macOS GitHub Actions build, test, package, plist, and signature checks.
- Additional parser, authentication, reset recovery, and JSONL tests.
- Opt-in read-only integration test against the locally installed Codex CLI.

### Changed

- Application interface, errors, architecture documentation, and changelog now use English.
- Signed-out and unsupported account states clear any previous account's visible quota.
- All quota countdowns share one one-second timeline.

## [0.2.0] - 2026-09-16

### Added

- 15-second request timeout and Swift task cancellation.
- Exponential reconnection backoff with jitter.
- Locally persisted reset attempt and idempotency key for safe retries.
- HTTPS login URL allowlist and malformed JSONL reporting.
- Architecture documentation and reset, backoff, and URL tests.

### Changed

- App Server client now uses Swift actor isolation.
- Usage notifications received during refresh schedule one follow-up refresh.
- Missing pipes and stopped processes fail requests explicitly.
- App Server client version comes from the app bundle.
- Packaging removes any older app bundle before rebuilding.

## [0.1.0] - 2026-09-16

### Added

- Initial macOS 14+ menu bar app with plan, quota windows, percentages, and reset countdowns.
- App Server notification updates and 60-second polling.
- Floating window, ChatGPT browser login, Launch at Login, and earned reset redemption.
- Local app packaging with ad-hoc signing.
