import AppKit
import SwiftUI

private struct CountdownTaskID: Equatable {
    let fetchedAt: Date?
    let showsOtherLimits: Bool
}

struct MonitorView: View {
    @ObservedObject var monitor: UsageMonitor
    let showFloatingWindow: () -> Void
    var isFloatingWindow = false
    @State private var confirmsReset = false
    @State private var confirmsDiscard = false
    @State private var isVisible = false
    @State private var saverNow = Date()
    @State private var showsOtherLimits = false
    @State private var showsSettings = false

    private var countdownTaskID: CountdownTaskID {
        CountdownTaskID(fetchedAt: monitor.usage?.fetchedAt, showsOtherLimits: showsOtherLimits)
    }

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
            if monitor.energySavingMode {
                Label("Updates paused · Select Refresh for current usage", systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            Text(monitor.energySavingMode ? "Manual mode" : monitor.phase.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch monitor.phase {
        case .loading where monitor.energySavingMode:
            EmptyStateView(icon: "pause.circle", title: "No saved usage",
                           detail: "Select Refresh to load current quota.")
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
                .disabled(monitor.isSigningIn)
            Button("Use device code instead") { Task { await monitor.signInWithDeviceCode() } }
                .disabled(monitor.isSigningIn)
            if monitor.isSigningIn {
                Button("Cancel sign-in") { Task { await monitor.cancelLogin() } }
            }
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
            if isVisible && monitor.energySavingMode && monitor.usage?.windows.isEmpty == false {
                usageWindows(now: saverNow)
                    .task(id: countdownTaskID) {
                        saverNow = Date()
                        while !Task.isCancelled {
                            guard let delay = nextCountdownDelay(windows: visibleCountdownWindows, now: saverNow) else { return }
                            do { try await Task.sleep(for: .seconds(delay)) }
                            catch { return }
                            saverNow = Date()
                        }
                    }
            } else if isVisible && monitor.usage?.windows.isEmpty == false {
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
                    if usage.fiveHourWindow != nil { Divider() }
                    quotaSummary(window: window, now: now, compact: true)
                }
                let otherWindows = usage.windows.filter {
                    $0.id != usage.fiveHourWindow?.id && $0.id != usage.oneWeekWindow?.id
                }
                if !otherWindows.isEmpty {
                    DisclosureGroup("Other limits", isExpanded: $showsOtherLimits) {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(otherWindows) { window in
                                UsageWindowView(window: window, now: now, isCurrent: monitor.phase == .ready,
                                                energySavingMode: monitor.energySavingMode)
                            }
                        }
                        .padding(.top, 8)
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    private var visibleCountdownWindows: [RateLimitWindow] {
        guard let usage = monitor.usage else { return [] }
        var windows = [usage.fiveHourWindow, usage.oneWeekWindow].compactMap { $0 }
        if showsOtherLimits {
            windows += usage.windows.filter {
                $0.id != usage.fiveHourWindow?.id && $0.id != usage.oneWeekWindow?.id
            }
        }
        return windows
    }

    @ViewBuilder
    private var usageMetadata: some View {
        if let usage = monitor.usage {
            Divider()
            VStack(spacing: 10) {
                HStack {
                    Label("Available resets", systemImage: "arrow.counterclockwise.circle")
                    Spacer()
                    Text("\(usage.availableResetCount)")
                        .monospacedDigit()
                }
                if let balance = usage.credits?.balance {
                    HStack {
                        Label("Credits", systemImage: "creditcard")
                        Spacer()
                        Text(balance).monospacedDigit()
                    }
                }
            }
            .font(.subheadline)
            Divider()

            if monitor.energySavingMode {
                Text("Updated \(usage.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Updated \(usage.fetchedAt, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if monitor.phase == .stale {
                Label("Showing last known data", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func quotaSummary(window: RateLimitWindow, now: Date, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            Label(compact ? "1-week remaining" : "5-hour remaining",
                  systemImage: compact ? "calendar" : "clock")
                .font(compact ? .caption : .subheadline)
                .foregroundStyle(.secondary)
            Text("\(Int(window.remainingPercent.rounded()))%")
                .font(.system(size: compact ? 22 : 32, weight: .semibold).monospacedDigit())
                .accessibilityLabel("\(window.durationLabel) quota \(Int(window.remainingPercent.rounded())) percent remaining")
            ProgressView(value: window.remainingPercent, total: 100)
                .tint(monitor.phase == .ready && !monitor.energySavingMode
                    ? MenuBarUsageLevel(usedPercent: window.usedPercent).usageColor : .gray)
                .accessibilityLabel("\(window.durationLabel) quota remaining")
                .accessibilityValue("\(Int(window.remainingPercent.rounded())) percent remaining")
            Text("\(Int(window.usedPercent.rounded()))% used")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Resets in \(countdown(to: window.resetsAt, now: now, energySaving: monitor.energySavingMode))")
                .font(compact ? .caption.monospacedDigit() : .subheadline.monospacedDigit())
            if compact && window.title != window.durationLabel {
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
                .disabled(monitor.isRefreshing || monitor.isManualOperationInProgress || monitor.isSwitchingMode
                          || (monitor.phase == .loading && !monitor.energySavingMode))

                Button("Floating Window", systemImage: "macwindow.on.rectangle") {
                    showFloatingWindow()
                }

                Spacer()

                Button("Use Reset") { confirmsReset = true }
                    .disabled(!canReset)
            }

            DisclosureGroup(isExpanded: $showsSettings) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: "leaf")
                            .frame(width: 20)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Energy Saving Mode")
                            Text("Update usage only when you select Refresh")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Toggle("Energy Saving Mode", isOn: Binding(
                            get: { monitor.energySavingMode },
                            set: { enabled in Task { await monitor.setEnergySavingMode(enabled) } }
                        ))
                        .labelsHidden()
                        .disabled(monitor.isSwitchingMode || monitor.isRefreshing || monitor.isResetting
                                  || monitor.isSigningIn || monitor.isManualOperationInProgress)
                    }
                    .padding(12)
                    Divider().padding(.leading, 44)
                    HStack(spacing: 12) {
                        Image(systemName: "power")
                            .frame(width: 20)
                            .foregroundStyle(.secondary)
                        Text("Launch at Login")
                        Spacer(minLength: 8)
                        Toggle("Launch at Login", isOn: Binding(
                            get: { monitor.launchAtLogin },
                            set: { monitor.setLaunchAtLogin($0) }
                        ))
                        .labelsHidden()
                    }
                    .padding(12)
                }
                .font(.subheadline)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                if let path = monitor.codexPath {
                    Text("Codex CLI: \(path)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            } label: {
                Label("Settings", systemImage: "gearshape")
            }

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
            && !monitor.isResetting && !monitor.isManualOperationInProgress
            && !monitor.isSigningIn && !monitor.isSwitchingMode && !monitor.resetRecoveryBlocked
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
        if monitor.energySavingMode { return .gray }
        return switch monitor.phase {
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
    let energySavingMode: Bool

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
                    Text("Resets in \(countdown(to: window.resetsAt, now: now, energySaving: energySavingMode))")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
    }

    private var progressColor: Color {
        isCurrent && !energySavingMode ? MenuBarUsageLevel(usedPercent: window.usedPercent).usageColor : .gray
    }
}

func countdown(to date: Date, now: Date, energySaving: Bool) -> String {
    if energySaving {
        let remaining = max(0, date.timeIntervalSince(now))
        if remaining < 60 { return "\(Int(ceil(remaining)))s" }
        let totalMinutes = Int(ceil(remaining / 60))
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
    let seconds = max(0, Int(date.timeIntervalSince(now)))
    let days = seconds / 86_400
    let hours = (seconds % 86_400) / 3_600
    let minutes = (seconds % 3_600) / 60
    let remainingSeconds = seconds % 60
    if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
    if hours > 0 { return "\(hours)h \(minutes)m \(remainingSeconds)s" }
    return "\(minutes)m \(remainingSeconds)s"
}

func nextCountdownDelay(windows: [RateLimitWindow], now: Date) -> TimeInterval? {
    windows.compactMap { window -> TimeInterval? in
        let remaining = window.resetsAt.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        let interval = remaining > 60 ? 60.0 : 1.0
        let nextRemaining = floor((remaining - 0.001) / interval) * interval
        return max(0.05, remaining - nextRemaining)
    }.min()
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
