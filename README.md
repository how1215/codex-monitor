# Codex Usage Monitor for macOS

Codex Usage Monitor is a native macOS menu bar application for people who already use the Codex CLI. It provides an at-a-glance view of your Codex subscription plan, rate-limit windows, current usage, remaining quota, and reset countdowns.

The app reads account and usage data through the local Codex App Server. It does not scrape the screen, read authentication tokens directly, or send your usage data to a third-party service.

> **Platform:** macOS 14 Sonoma or later. Windows and Linux are not supported.
>
> **Distribution:** The project is currently available as source code. A notarized prebuilt release is not available yet.

## Features

- Shows five-hour quota remaining directly in the macOS menu bar, with green (under 50% used), yellow (50–79% used), red (80% or more used), or gray (unavailable/stale) status.
- Displays the subscription plan and every rate-limit window returned by Codex.
- Leads with the most constrained five-hour window's remaining quota and reset countdown, followed by a compact one-week summary when available; other windows are available in an expandable section.
- Shows used and remaining percentages with reset countdowns updated every second while the panel is visible.
- In normal mode, refreshes quota when Codex reports a usage change, when an opened panel has data older than one minute, and through a full account-and-quota synchronization every five minutes.
- Provides a manually refreshable, always-on-top floating window.
- Uses matching macOS-style cards in the menu bar panel and floating window; widening the floating window places the five-hour and one-week cards side by side.
- Supports optional launch at login.
- Offers an Energy Saving Mode that pauses background updates and reads a new snapshot only when you select **Refresh**.
- Detects signed-out, offline, stale-data, and missing-CLI states.
- Allows an available earned reset to be redeemed after confirmation.
- Recovers safely from interrupted reset requests by reusing the original idempotency key.
- Reconnects automatically with bounded exponential backoff after App Server interruptions.
- Offers device-code sign-in if the browser flow cannot be opened.

## Requirements

- macOS 14 Sonoma or later.
- An existing Codex CLI installation.
- A Codex session authenticated with a ChatGPT account.
- Swift 6 toolchain or Xcode for building from source.

Full Xcode is recommended for running tests with the standard `swift test` command. Apple Command Line Tools alone may not expose the `Testing` framework to Swift Package Manager.

API-key authentication does not expose ChatGPT subscription quota information, so the monitor requires a ChatGPT-authenticated Codex session.

## Download and Install

### Build from source

Clone the repository and create the local app bundle:

```sh
git clone https://github.com/how1215/codex-monitor.git
cd codex-monitor
./scripts/build-app.sh
```

The generated application is located at:

```text
.build/Codex Monitor.app
```

Open the build directory in Finder:

```sh
open .build
```

Drag **Codex Monitor.app** into the **Applications** folder, then open it like any other Mac application. You can also run the generated app directly:

```sh
open ".build/Codex Monitor.app"
```

The build script creates an ad-hoc signed app intended for local use and testing. It is not Developer ID signed or notarized. If macOS blocks the app, review the warning in **System Settings → Privacy & Security** and allow it only if you trust the source and the app you built.

### Run without creating an app bundle

For development, run the executable directly with Swift Package Manager:

```sh
swift run CodexMonitor
```

## Usage

1. Start Codex Monitor.
2. Look for the colored dot and five-hour quota remaining percentage in the macOS menu bar.
3. Select the menu bar item to view your five-hour and one-week summaries, plan, other quota windows, and reset countdowns.
4. Use **Refresh** to request the latest account data immediately.
5. Use **Floating Window** to keep the monitor above other windows.
   Resize it for a wider two-card layout, or select **Close Window** in its footer to hide it.
6. Enable **Launch at Login** if you want the monitor to start automatically.
7. Quit the application from the menu bar panel when it is no longer needed.

The application interface is in English.

## Usage Updates

The monitor reads usage with `account/rateLimits/read` and listens for `account/rateLimits/updated` events from the local Codex App Server.

- Server events trigger a refresh after a 250 ms coalescing window.
- A fallback full account-and-quota poll runs every five minutes.
- Opening the menu bar or floating panel refreshes quota in the background if the last successful read is over one minute old.
- Reset countdowns are calculated locally from the official `resetsAt` timestamp and update every second.
- The app displays the values reported by the Codex backend; it does not estimate subscription usage from local token counts.
- Several five-hour windows may be returned; the menu bar and summary use the window with the highest reported usage and show its remaining quota. Ties use the earliest reset time. If none is available, the menu bar displays a neutral status and the panel says the five-hour limit is unavailable.
- The one-week summary uses the same remaining bar, used percentage, and reset countdown as the five-hour summary. If several one-week windows are returned, it uses the most constrained one. If none is returned, the one-week summary is hidden.

To keep the menu bar compact, the visible item contains only a colored dot and remaining percentage. Hover help and the accessibility label identify it as Codex five-hour quota remaining. A gray dot means the value is unavailable or may be stale. The panel uses the same 50% and 80% used thresholds for its progress bars.

Backend reporting can be delayed, so values may not change immediately after an individual Codex request.

## Energy Saving Mode

Enable **Energy Saving Mode** under **Settings** to stop the local Codex App Server and pause automatic usage updates. The menu bar keeps the last reported percentage with a gray status dot and an "updates paused" hint. Opening the menu bar or floating window does not fetch data; select **Refresh** to read the current account and quota once. After the read, the App Server stops again. If no snapshot exists yet, the menu bar shows `--%`.

The five-hour and one-week summaries have clock and calendar headings separated by a line. While Energy Saving Mode is on, their reset countdowns update by the minute, then by the second during the final minute. The countdown is calculated from the last snapshot and does not mean that the quota itself has been refreshed.

Sign-in and **Use Reset** remain available. They temporarily start the App Server; an active sign-in keeps it running until completion, cancellation, or a ten-minute timeout. Energy Saving Mode is off each time the app starts. Turning it off restores event updates, the five-minute fallback poll, and automatic reconnection.

## Reset Safety

The **Use Reset** action only calls the official `account/rateLimitResetCredit/consume` method when the account reports an available earned reset. It cannot arbitrarily clear quota and does not purchase a paid instant reset.

Before sending a reset request, the app stores its idempotency key locally. If the result cannot be confirmed because of a timeout or disconnection, the next attempt reuses the same key instead of creating a second reset request. Automated tests never call the live reset endpoint.

## Privacy and Security

- Account communication stays between this app and the local Codex App Server.
- The app does not directly read or store Codex authentication tokens.
- No analytics or telemetry are collected.
- Account and usage data are not forwarded to another service.
- Login URLs are restricted to HTTPS pages on approved OpenAI and ChatGPT domains.
- Requests have bounded timeouts, and interrupted connections are recovered automatically.

See [Architecture and Security](docs/ARCHITECTURE.md) for implementation details.

## Troubleshooting

### The menu bar item does not appear

Confirm that the app is running in Activity Monitor. If the menu bar is crowded, macOS may hide additional menu bar items.

### Codex CLI is not detected

Launch Codex once from Terminal and confirm it works in your current environment, then select **Retry Detection** in the app.

### The app shows that sign-in is required

Use the browser sign-in button or the device-code fallback. An API-key-only Codex session does not expose ChatGPT subscription quota data.

### Usage data is stale or unavailable

Check the network connection and confirm that the Codex CLI is responsive. The app will retry automatically and retain the last known usage snapshot while reconnecting.

### Launch at Login cannot be enabled

Move the application to the **Applications** folder first, reopen it from there, and try enabling the setting again.

## Development

Build and test the Swift package:

```sh
swift build
swift test
```

If you only have Apple Command Line Tools and `swift test` reports `no such module 'Testing'`, install full Xcode or run the tests with the CLT framework paths:

```sh
swift test \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Create a release-mode macOS app bundle:

```sh
./scripts/build-app.sh
```

Project layout:

```text
Sources/CodexMonitor/       Application source code
Tests/CodexMonitorTests/    Unit tests
Support/Info.plist          macOS bundle metadata
scripts/build-app.sh        Local app packaging script
docs/ARCHITECTURE.md        Architecture, reliability, and security notes
CHANGELOG.md                Version history
.github/workflows/ci.yml    macOS build and test checks
```

An optional read-only integration check can be run against your installed Codex CLI by setting `CODEX_MONITOR_REAL_SMOKE=1` when running the tests. It reads account and quota data but never consumes a reset. Leave this variable unset for the regular offline test suite.

## Documentation

- [Architecture and Security](docs/ARCHITECTURE.md)
- [Changelog](CHANGELOG.md)
- [Codex App Server documentation](https://developers.openai.com/codex/app-server)

## Contributing

Bug reports and focused pull requests are welcome. For behavior changes, include or update tests and document user-visible changes in `CHANGELOG.md`.

## Project Status

Codex Usage Monitor is an independent utility and is not an official OpenAI product. The repository does not currently include an open-source license or a notarized binary release.
