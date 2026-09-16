# Codex Usage Monitor for macOS

Codex Usage Monitor is a native macOS menu bar application for people who already use the Codex CLI. It provides an at-a-glance view of your Codex subscription plan, rate-limit windows, current usage, remaining quota, and reset countdowns.

The app reads account and usage data through the local Codex App Server. It does not scrape the screen, read authentication tokens directly, or send your usage data to a third-party service.

> **Platform:** macOS 14 Sonoma or later. Windows and Linux are not supported.
>
> **Distribution:** The project is currently available as source code. A notarized prebuilt release is not available yet.

## Features

- Shows the primary usage percentage directly in the macOS menu bar.
- Displays the subscription plan and every rate-limit window returned by Codex.
- Shows used and remaining percentages with reset countdowns updated every second.
- Refreshes when Codex reports a usage change and performs a full synchronization every 60 seconds.
- Provides a manually refreshable, always-on-top floating window.
- Supports optional launch at login.
- Detects signed-out, offline, stale-data, and missing-CLI states.
- Allows an available earned reset to be redeemed after confirmation.
- Recovers safely from interrupted reset requests by reusing the original idempotency key.
- Reconnects automatically with bounded exponential backoff after App Server interruptions.

## Requirements

- macOS 14 Sonoma or later.
- An existing Codex CLI installation.
- A Codex session authenticated with a ChatGPT account.
- Swift 6 toolchain or Xcode for building from source.

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
2. Look for the gauge icon and usage percentage in the macOS menu bar.
3. Select the menu bar item to view your plan, quota windows, remaining usage, and reset countdowns.
4. Use **Refresh** to request the latest account data immediately.
5. Use **Floating Window** to keep the monitor above other windows.
6. Enable **Launch at Login** if you want the monitor to start automatically.
7. Quit the application from the menu bar panel when it is no longer needed.

The current application interface is displayed in Traditional Chinese.

## Usage Updates

The monitor reads usage with `account/rateLimits/read` and listens for `account/rateLimits/updated` events from the local Codex App Server.

- Server events trigger an immediate refresh.
- A fallback poll runs every 60 seconds.
- Reset countdowns are calculated locally from the official `resetsAt` timestamp and update every second.
- The app displays the values reported by the Codex backend; it does not estimate subscription usage from local token counts.

Backend reporting can be delayed, so values may not change immediately after an individual Codex request.

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

Authenticate the existing Codex CLI session with your ChatGPT account, then refresh or restart the monitor.

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
```

## Documentation

- [Architecture and Security](docs/ARCHITECTURE.md)
- [Changelog](CHANGELOG.md)
- [Codex App Server documentation](https://developers.openai.com/codex/app-server)

## Contributing

Bug reports and focused pull requests are welcome. For behavior changes, include or update tests and document user-visible changes in `CHANGELOG.md`.

## Project Status

Codex Usage Monitor is an independent utility and is not an official OpenAI product. The repository does not currently include an open-source license or a notarized binary release.
