import AppKit
import SwiftUI

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    static weak var monitor: UsageMonitor?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await Self.monitor?.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct CodexMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @StateObject private var monitor: UsageMonitor
    @StateObject private var floatingPanel = FloatingPanelController()

    init() {
        let monitor = UsageMonitor()
        _monitor = StateObject(wrappedValue: monitor)
        AppLifecycle.monitor = monitor
    }

    var body: some Scene {
        MenuBarExtra {
            MonitorView(monitor: monitor) {
                floatingPanel.toggle {
                    MonitorView(monitor: monitor, showFloatingWindow: {}, isFloatingWindow: true)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(nsImage: menuStatusImage)
                Text(menuTitle)
                    .font(.system(size: 12, weight: .medium))
            }
            .accessibilityLabel(menuAccessibilityLabel)
            .help(menuAccessibilityLabel)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuTitle: String {
        guard let remaining = monitor.usage?.fiveHourRemainingPercent else { return "--%" }
        return "\(Int(remaining.rounded()))%"
    }

    private var menuAccessibilityLabel: String {
        guard let remaining = monitor.usage?.fiveHourRemainingPercent else {
            return monitor.energySavingMode
                ? "Codex usage updates paused. Open the panel and select Refresh."
                : "Codex 5-hour remaining quota unavailable"
        }
        let status = monitor.energySavingMode ? "updates paused" :
            (monitor.phase == .ready ? "current" : "may be stale")
        return "Codex 5-hour quota \(Int(remaining.rounded())) percent remaining, \(status)"
    }

    private var menuStatusImage: NSImage {
        let level = monitor.phase == .ready && !monitor.energySavingMode
            ? MenuBarUsageLevel(usedPercent: monitor.usage?.fiveHourWindow?.usedPercent)
            : .unavailable
        let color: NSColor
        switch level {
        case .normal: color = .systemGreen
        case .warning: color = .systemYellow
        case .critical: color = .systemRed
        case .unavailable: color = .systemGray
        }
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
