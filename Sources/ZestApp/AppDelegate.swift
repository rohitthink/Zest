import AppKit
import ZestKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let dropController = DropController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "drop.fill", accessibilityDescription: "Zest")
            button.image?.isTemplate = true
            button.toolTip = "Zest — drop a file to convert"
        }
        item.menu = makeMenu()
        statusItem = item
        dropController.show()          // greet with the drop zone on launch
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let show = menu.addItem(withTitle: "Show Drop Zone", action: #selector(showDropZone), keyEquivalent: "d")
        show.target = self
        menu.addItem(.separator())
        let about = menu.addItem(withTitle: "About Zest", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        let quit = menu.addItem(withTitle: "Quit Zest", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        return menu
    }

    @objc private func showDropZone() { dropController.show() }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Zest"
        alert.informativeText = "A clean-room, local file converter.\nDrop a file to pick a format. Powered by ZestKit."
        alert.addButton(withTitle: "OK")
        dropController.hide()
        alert.runModal()
    }

    // MARK: - URL scheme (zest://convert?input=…&to=…)

    // Delivered by AppKit for registered schemes. Scheme registration itself
    // needs an Info.plist CFBundleURLTypes entry in a packaged .app (see README).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let command = ZestURL.parse(url) { dropController.runURLCommand(command) }
        }
    }
}
