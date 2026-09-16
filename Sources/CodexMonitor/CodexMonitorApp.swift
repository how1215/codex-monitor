import SwiftUI

@main
struct CodexMonitorApp: App {
    @StateObject private var monitor = UsageMonitor()
    @StateObject private var floatingPanel = FloatingPanelController()

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
