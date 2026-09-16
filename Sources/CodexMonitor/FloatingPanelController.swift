import AppKit
import SwiftUI

@MainActor
final class FloatingPanelController: ObservableObject {
    private var panel: NSPanel?

    func toggle<Content: View>(@ViewBuilder content: () -> Content) {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            return
        }

        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
                styleMask: [.titled, .closable, .resizable, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.title = "Codex Usage"
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: content())
            panel.center()
            self.panel = panel
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
