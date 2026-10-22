import AppKit
import ZestKit

/// What the menu-bar panel can ask the app to do.
struct MenuActions {
    var convertFile: @MainActor () -> Void
    /// A link typed or pasted into the menu: read it and show the download choices.
    var downloadLink: @MainActor (URL) -> Void
    var showDropZone: @MainActor () -> Void
    var openSettings: @MainActor () -> Void
    var quit: @MainActor () -> Void
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = ZestSettings()
    let recents = RecentsStore()
    private(set) lazy var model: ConversionModel = ConversionModel(settings: settings, recents: recents)

    private var statusItem: NSStatusItem?
    private var statusDropTarget: StatusDropTarget?
    private lazy var dropController: DropController = DropController(model: model)
    private lazy var settingsController: SettingsWindowController = SettingsWindowController(settings: settings)
    private lazy var menuController: MenuPanelController = MenuPanelController(
        model: model, recents: recents,
        actions: MenuActions(
            convertFile: { [weak self] in self?.menuController.close(); self?.dropController.chooseFiles() },
            downloadLink: { [weak self] link in self?.menuController.close(); self?.dropController.openLink(link) },
            showDropZone: { [weak self] in self?.menuController.close(); self?.dropController.show() },
            openSettings: { [weak self] in self?.menuController.close(); self?.settingsController.show() },
            quit: { NSApp.terminate(nil) }
        )
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Citrus.statusImage()
            button.toolTip = "Zest — drop a file to squeeze"
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // Dragging a file onto the icon opens the drop zone; dropping on it
            // puts the file on the wheel.
            if let window = button.window {
                let target = StatusDropTarget(
                    onEnter: { [weak self] in self?.dropController.show() },
                    onDrop: { [weak self] urls in
                        let files = urls.filter(\.isFileURL)
                        if !files.isEmpty { self?.dropController.open(files) }
                        else if let link = urls.first { self?.dropController.openLink(link) }
                    })
                window.registerForDraggedTypes([.fileURL, .URL])
                window.delegate = target
                statusDropTarget = target
            }
        }
        statusItem = item
        dropController.openSettings = { [weak self] in self?.settingsController.show(tab: .output) }
        DispatchQueue.global(qos: .utility).async { LinkDownloader.sweepStaleTemporaryFolders() }
        if settings.showDropZoneOnLaunch { dropController.show() }
    }

    /// Launching Zest again (Finder, Spotlight) while it runs shows the drop zone.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { dropController.show() }
        return false
    }

    /// Quitting mid-job: stop the run and every tool it started, so no ffmpeg
    /// or LibreOffice is left working on its own.
    func applicationWillTerminate(_ notification: Notification) {
        model.cancel()
        terminateRunningTools()
        model.abandonInFlightOutputs()
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if wantsMenu {
            menuController.close()
            fallbackMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        } else {
            menuController.toggle(relativeTo: sender)
        }
    }

    /// Right-click: a plain menu, for people who expect one.
    private func fallbackMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ key: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
        }
        add("Convert a File…", "o", #selector(convertFileItem))
        add("Download Link from Clipboard", "", #selector(downloadClipboardLinkItem))
        add("Show Drop Zone", "d", #selector(showDropZoneItem))
        menu.addItem(.separator())
        add("Settings…", ",", #selector(openSettingsItem))
        add("Quit Zest", "q", #selector(quitItem))
        return menu
    }

    @objc private func convertFileItem() { dropController.chooseFiles() }

    /// Reads the clipboard only because the user chose this item.
    @objc private func downloadClipboardLinkItem() {
        if let link = DropTargetView.urls(on: .general).first(where: LinkDownloader.isWebLink) {
            dropController.openLink(link)
        } else {
            NSSound.beep()
        }
    }
    @objc private func showDropZoneItem() { dropController.show() }
    @objc private func openSettingsItem() { settingsController.show() }
    @objc private func quitItem() { NSApp.terminate(nil) }

    // MARK: - Opening things

    /// URL scheme and Open With:
    /// - `zest://convert?input=…&to=…`  convert now (see ZestURL)
    /// - `zest://download?url=…[&as=best|compatible|m4a|mp3|wav|image]`  download a link
    /// - `zest://open?input=…[&input=…]`  put files on the wheel
    /// - `zest://settings`, `zest://dropzone`
    /// - file URLs (Finder ▸ Open With ▸ Zest)  put files on the wheel
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { dropController.open(files) }
        for url in urls where !url.isFileURL {
            if let command = ZestURL.parse(url) {
                dropController.runURLCommand(command)
                continue
            }
            if let command = ZestURL.parseDownload(url) {
                dropController.runDownloadCommand(command)
                continue
            }
            guard url.scheme?.lowercased() == ZestURL.scheme else { continue }
            switch url.host?.lowercased() {
            case "open":
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let inputs = items.filter { $0.name.lowercased() == "input" }
                    .compactMap(\.value).filter { !$0.isEmpty }
                    .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                if !inputs.isEmpty { dropController.open(inputs) }
            case "settings":
                settingsController.show()
            case "dropzone":
                dropController.show()
            default:
                break
            }
        }
    }
}

/// Receives drags over the menu-bar icon. NSWindow forwards dragging-
/// destination messages to its delegate, so this sits as the status button
/// window's delegate.
final class StatusDropTarget: NSObject, NSWindowDelegate, NSDraggingDestination {
    private let onEnter: @MainActor () -> Void
    private let onDrop: @MainActor ([URL]) -> Void

    init(onEnter: @escaping @MainActor () -> Void, onDrop: @escaping @MainActor ([URL]) -> Void) {
        self.onEnter = onEnter
        self.onDrop = onDrop
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !DropTargetView.droppedURLs(sender).isEmpty else { return [] }
        MainActor.assumeIsolated { onEnter() }
        return .copy
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = DropTargetView.droppedURLs(sender)
        guard !urls.isEmpty else { return false }
        MainActor.assumeIsolated { onDrop(urls) }
        return true
    }
}
