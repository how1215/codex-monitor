# Changelog

User-visible changes follow the Keep a Changelog format. Versions use Semantic Versioning.

## [Unreleased]

No changes yet.

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
