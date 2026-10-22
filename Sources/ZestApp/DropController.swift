import AppKit
import SwiftUI

/// A borderless floating panel that can still take key focus so SwiftUI controls
/// inside it respond to clicks without activating the (accessory) app.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the floating drop panel and the shared conversion model.
@MainActor
final class DropController {
    private var panel: FloatingPanel?
    private let model = ConversionModel()

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        center(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> FloatingPanel {
        let root = DropWheelView(model: model, onClose: { [weak self] in self?.hide() })
        let hosting = NSHostingView(rootView: root)
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 360),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        return panel
    }

    private func center(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                     y: visible.midY - size.height / 2))
    }
}
