import AppKit
import SwiftUI

struct MonitorView: View {
    @ObservedObject var monitor: UsageMonitor
    let showFloatingWindow: () -> Void
    @State private var confirmsReset = false

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
            "確定要使用一個 Reset？",
            isPresented: $confirmsReset,
            titleVisibility: .visible
        ) {
            Button("立即重置用量", role: .destructive) {
                Task { await monitor.consumeReset() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(resetConfirmationMessage)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex 用量")
                    .font(.headline)
                Text(monitor.account?.planLabel ?? monitor.phase.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
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
                title: "找不到 Codex CLI",
                detail: "請先安裝 Codex CLI，再按下重新偵測。"
            )
        case .signedOut:
            EmptyStateView(
                icon: "person.crop.circle.badge.exclamationmark",
                title: "需要登入 ChatGPT",
                detail: "登入後才能讀取 Codex 訂閱用量。"
            )
            Button("登入 ChatGPT") { Task { await monitor.signIn() } }
                .buttonStyle(.borderedProminent)
        case .offline where monitor.usage == nil:
            EmptyStateView(
                icon: "wifi.exclamationmark",
                title: "目前無法連線",
                detail: "請確認網路與 Codex CLI 狀態。"
            )
        default:
            usageContent
        }
    }

    private var usageContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let windows = monitor.usage?.windows, !windows.isEmpty {
                ForEach(windows) { window in
                    UsageWindowView(window: window)
                }
            } else {
                Text("官方目前沒有回傳用量視窗。")
                    .foregroundStyle(.secondary)
            }

            if let usage = monitor.usage {
                HStack {
                    Label("可用 Reset", systemImage: "arrow.counterclockwise.circle")
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

                Text("最後更新：\(usage.fetchedAt.formatted(date: .omitted, time: .standard))")
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
                    Label(monitor.isRefreshing ? "更新中" : "重新整理", systemImage: "arrow.clockwise")
                }
                .disabled(monitor.isRefreshing || monitor.phase == .loading)

                Button("浮動視窗", systemImage: "macwindow.on.rectangle") {
                    showFloatingWindow()
                }

                Spacer()

                Button("使用 Reset") { confirmsReset = true }
                    .disabled(!canReset)
            }

            Toggle("登入後自動啟動", isOn: Binding(
                get: { monitor.launchAtLogin },
                set: { monitor.setLaunchAtLogin($0) }
            ))
            .font(.caption)

            HStack {
                if monitor.phase == .cliMissing || monitor.phase == .offline {
                    Button("重新偵測") { monitor.connect() }
                }
                Spacer()
                Button("結束程式") { NSApplication.shared.terminate(nil) }
            }
            .font(.caption)
        }
    }

    private var canReset: Bool {
        ((monitor.usage?.availableResetCount ?? 0) > 0 || monitor.hasPendingResetAttempt)
            && !monitor.isResetting
    }

    private var resetConfirmationMessage: String {
        if monitor.hasPendingResetAttempt {
            return "將重試上次結果未確認的 Reset，並安全重用相同識別碼，不會建立新的重置嘗試。"
        }
        guard let usage = monitor.usage else { return "" }
        if let credit = usage.resetCredits.first(where: { $0.status == "available" }) {
            let expiry = credit.expiresAt?.formatted(date: .abbreviated, time: .shortened) ?? "未提供"
            return "\(credit.title ?? "Codex Reset")\n到期時間：\(expiry)\n此操作無法復原。"
        }
        return "將使用帳號的一個可用 reset。此操作無法復原。"
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(window.title)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(window.usedPercent, specifier: "%.0f")% 已用")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: window.usedPercent, total: 100)
                    .tint(progressColor)
                HStack {
                    Text("剩餘 \(window.remainingPercent, specifier: "%.0f")%")
                    Spacer()
                    Text("重置於 \(countdown(to: window.resetsAt, now: context.date))")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
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
        if days > 0 { return "\(days)天 \(hours)時 \(minutes)分" }
        if hours > 0 { return "\(hours)時 \(minutes)分 \(remainingSeconds)秒" }
        return "\(minutes)分 \(remainingSeconds)秒"
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
