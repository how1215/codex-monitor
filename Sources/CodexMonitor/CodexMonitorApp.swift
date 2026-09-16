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
                    MonitorView(monitor: monitor, showFloatingWindow: {})
                }
            }
        } label: {
            Label(menuTitle, systemImage: "gauge.with.dots.needle.33percent")
        }
        .menuBarExtraStyle(.window)
    }

    private var menuTitle: String {
        guard let used = monitor.usage?.primaryUsedPercent else { return "Codex" }
        return "\(Int(used.rounded()))%"
    }
}
