import AppKit
import SwiftUI

struct MonitorView: View {
    @ObservedObject var monitor: UsageMonitor
    let showFloatingWindow: () -> Void
    var isFloatingWindow = false
    @State private var confirmsReset = false
    @State private var confirmsDiscard = false
    @State private var isVisible = false
    @State private var showsOtherLimits = false
    @State private var showsSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            if isFloatingWindow {
                ScrollView { details }
                    .frame(minHeight: 120)
            } else {
                details
            }
            Divider()
            actions
        }
        .padding(18)
        .frame(minWidth: 340, idealWidth: 360, maxWidth: .infinity)
        .onAppear {
            isVisible = true
            Task { await monitor.refreshIfNeededOnOpen() }
        }
        .onDisappear { isVisible = false }
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

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
            if let message = monitor.message {
                Label(message, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            if isVisible && monitor.usage?.windows.isEmpty == false {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    usageWindows(now: context.date)
                }
            } else {
                usageWindows(now: .now)
            }
            usageMetadata
        }
    }

    private func usageWindows(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let window = monitor.usage?.fiveHourWindow {
                quotaSummary(window: window, now: now, compact: false)
            } else {
                Text("5-hour limit unavailable")
                    .foregroundStyle(.secondary)
            }

            if let usage = monitor.usage {
                if let window = usage.oneWeekWindow {
                    quotaSummary(window: window, now: now, compact: true)
                }
                let otherWindows = usage.windows.filter {
                    $0.id != usage.fiveHourWindow?.id && $0.id != usage.oneWeekWindow?.id
                }
                if !otherWindows.isEmpty {
                    DisclosureGroup("Other limits", isExpanded: $showsOtherLimits) {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(otherWindows) { window in
                                UsageWindowView(window: window, now: now, isCurrent: monitor.phase == .ready)
                            }
                        }
                        .padding(.top, 8)
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    @ViewBuilder
    private var usageMetadata: some View {
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

            Text("Updated \(usage.fetchedAt, style: .relative)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if monitor.phase == .stale {
                Label("Showing last known data", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func quotaSummary(window: RateLimitWindow, now: Date, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            Text(compact ? "1-week remaining" : "5-hour remaining")
                .font(compact ? .caption : .subheadline)
                .foregroundStyle(.secondary)
            Text("\(Int(window.remainingPercent.rounded()))%")
                .font(.system(size: compact ? 22 : 32, weight: .semibold).monospacedDigit())
                .accessibilityLabel("\(window.durationLabel) quota \(Int(window.remainingPercent.rounded())) percent remaining")
            ProgressView(value: window.remainingPercent, total: 100)
                .tint(monitor.phase == .ready
                    ? MenuBarUsageLevel(usedPercent: window.usedPercent).usageColor : .gray)
                .accessibilityLabel("\(window.durationLabel) quota remaining")
                .accessibilityValue("\(Int(window.remainingPercent.rounded())) percent remaining")
            Text("\(Int(window.usedPercent.rounded()))% used")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Resets in \(countdown(to: window.resetsAt, now: now))")
                .font(compact ? .caption.monospacedDigit() : .subheadline.monospacedDigit())
            if !compact || window.title != window.durationLabel {
                Text(window.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            DisclosureGroup("Settings & diagnostics", isExpanded: $showsSettings) {
                Toggle("Launch at Login", isOn: Binding(
                    get: { monitor.launchAtLogin },
                    set: { monitor.setLaunchAtLogin($0) }
                ))
                if let path = monitor.codexPath {
                    Text("Codex CLI: \(path)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
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
    let isCurrent: Bool

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
        isCurrent ? MenuBarUsageLevel(usedPercent: window.usedPercent).usageColor : .gray
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

private extension MenuBarUsageLevel {
    var usageColor: Color {
        switch self {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        case .unavailable: .gray
        }
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
