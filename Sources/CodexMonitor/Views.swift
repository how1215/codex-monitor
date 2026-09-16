import AppKit
import SwiftUI

struct MonitorView: View {
    @ObservedObject var monitor: UsageMonitor
    let showFloatingWindow: () -> Void
    @State private var confirmsReset = false
    @State private var confirmsDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            content
            if let message = monitor.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            actions
        }
        .padding(18)
        .frame(width: 360)
        .confirmationDialog(
            "Use an earned reset?",
            isPresented: $confirmsReset,
            titleVisibility: .visible
        ) {
            Button("Reset usage", role: .destructive) {
                Task { await monitor.consumeReset() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(resetConfirmationMessage)
        }
        .confirmationDialog("Discard reset recovery?", isPresented: $confirmsDiscard) {
            Button("Discard Recovery Record", role: .destructive) { monitor.discardResetRecovery() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The previous reset outcome may be unknown. Verify your account before attempting another reset.")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex Usage")
                    .font(.headline)
                Text(monitor.account?.planLabel ?? monitor.phase.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(monitor.phase.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch monitor.phase {
        case .loading:
            HStack { Spacer(); ProgressView(); Spacer() }
                .padding(.vertical, 30)
        case .cliMissing:
            EmptyStateView(
                icon: "terminal",
                title: "Codex CLI not found",
                detail: "Check your Codex CLI path, then select Retry Detection."
            )
        case .signedOut:
            EmptyStateView(
                icon: "person.crop.circle.badge.exclamationmark",
                title: "ChatGPT sign-in required",
                detail: "Sign in to view Codex subscription limits."
            )
            signInActions
        case .unsupportedAuth:
            EmptyStateView(icon: "person.crop.circle.badge.exclamationmark", title: "Unsupported account", detail: "Codex is not signed in with ChatGPT. Switch the Codex CLI account and refresh.")
            signInActions
        case .incompatibleResponse where monitor.usage == nil:
            EmptyStateView(icon: "exclamationmark.triangle", title: "Incompatible response", detail: "Update Codex CLI and try again.")
        case .offline where monitor.usage == nil:
            EmptyStateView(
                icon: "wifi.exclamationmark",
                title: "Currently offline",
                detail: "Check your network connection and Codex CLI."
            )
        default:
            usageContent
        }
    }

    private var signInActions: some View {
        VStack(alignment: .leading) {
            Button("Sign in with browser") { Task { await monitor.signIn() } }
                .buttonStyle(.borderedProminent)
            Button("Use device code instead") { Task { await monitor.signInWithDeviceCode() } }
            if let login = monitor.deviceCodeLogin {
                Text("Code: \(login.userCode)").textSelection(.enabled)
                Button("Copy code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(login.userCode, forType: .string)
                }
                Text(login.verificationURL.absoluteString)
                    .font(.caption)
                    .textSelection(.enabled)
                Link("Open verification page", destination: login.verificationURL)
            }
        }
    }

    private var usageContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let windows = monitor.usage?.windows, !windows.isEmpty {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ForEach(windows) { window in
                        UsageWindowView(window: window, now: context.date)
                    }
                }
            } else {
                Text("No usage windows were returned.")
                    .foregroundStyle(.secondary)
            }

            if let usage = monitor.usage {
                HStack {
                    Label("Available resets", systemImage: "arrow.counterclockwise.circle")
                    Spacer()
                    Text("\(usage.availableResetCount)")
                        .monospacedDigit()
                }
                .font(.subheadline)

                if let balance = usage.credits?.balance {
                    HStack {
                        Text("Credits")
                        Spacer()
                        Text(balance).monospacedDigit()
                    }
                    .font(.subheadline)
                }

                Text("Last updated: \(usage.fetchedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if monitor.phase == .stale { Text("Showing last known data").font(.caption).foregroundStyle(.orange) }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    Task { await monitor.refresh() }
                } label: {
                    Label(monitor.isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(monitor.isRefreshing || monitor.phase == .loading)

                Button("Floating Window", systemImage: "macwindow.on.rectangle") {
                    showFloatingWindow()
                }

                Spacer()

                Button("Use Reset") { confirmsReset = true }
                    .disabled(!canReset)
            }

            Toggle("Launch at Login", isOn: Binding(
                get: { monitor.launchAtLogin },
                set: { monitor.setLaunchAtLogin($0) }
            ))
            .font(.caption)

            HStack {
                if monitor.phase == .cliMissing || monitor.phase == .offline {
                    Button("Retry Detection") { monitor.connect() }
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .font(.caption)
            if monitor.resetRecoveryBlocked {
                Text("Reset recovery record is unreadable. New resets are blocked.")
                    .font(.caption)
                Button("Discard Recovery Record") { confirmsDiscard = true }
            }
            if let path = monitor.codexPath {
                Text("Codex CLI: \(path)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
        }
    }

    private var canReset: Bool {
        ((monitor.usage?.availableResetCount ?? 0) > 0 || monitor.hasPendingResetAttempt)
            && !monitor.isResetting && !monitor.resetRecoveryBlocked
    }

    private var resetConfirmationMessage: String {
        if monitor.hasPendingResetAttempt {
            return "Retry the unconfirmed reset using the same identifier. No new reset attempt will be created."
        }
        guard let usage = monitor.usage else { return "" }
        if let credit = usage.resetCredits.first(where: { $0.status == "available" }) {
            let expiry = credit.expiresAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not provided"
            return "\(credit.title ?? "Codex Reset")\nExpires: \(expiry)\nThis cannot be undone."
        }
        return "This will use one available earned reset. This cannot be undone."
    }

    private var statusColor: Color {
        switch monitor.phase {
        case .ready: .green
        case .loading: .blue
        case .stale: .orange
        default: .red
        }
    }
}

private struct UsageWindowView: View {
    let window: RateLimitWindow
    let now: Date

    var body: some View {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(window.title)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(window.usedPercent, specifier: "%.0f")% used")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: window.usedPercent, total: 100)
                    .tint(progressColor)
                    .accessibilityLabel("\(window.title) usage")
                    .accessibilityValue("\(Int(window.usedPercent.rounded())) percent used")
                HStack {
                    Text("\(window.remainingPercent, specifier: "%.0f")% remaining")
                    Spacer()
                    Text("Resets in \(countdown(to: window.resetsAt, now: now))")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
    }

    private var progressColor: Color {
        switch window.usedPercent {
        case 90...: .red
        case 70...: .orange
        default: .accentColor
        }
    }

    private func countdown(to date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m \(remainingSeconds)s" }
        return "\(minutes)m \(remainingSeconds)s"
    }
}

private struct EmptyStateView: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}
