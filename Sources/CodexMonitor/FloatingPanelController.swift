import AppKit
import SwiftUI

@MainActor
final class FloatingPanelController: NSObject, ObservableObject, NSWindowDelegate {
    private var panel: NSPanel?

    func toggle<Content: View>(@ViewBuilder content: () -> Content) {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            panel.contentView = NSView()
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
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.minSize = NSSize(width: 360, height: 340)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: content())
            panel.center()
            panel.setFrameAutosaveName("CodexMonitorFloatingPanel")
            self.panel = panel
        } else {
            panel?.contentView = NSHostingView(rootView: content())
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        panel?.contentView = NSView()
    }
}
