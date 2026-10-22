import AppKit
import SwiftUI
import ZestKit

/// What the drop panel's SwiftUI content can ask its controller to do.
struct DropActions {
    var close: @MainActor () -> Void
    var chooseFile: @MainActor () -> Void
    var openSettings: @MainActor () -> Void
}

/// A borderless floating panel that can take key focus (Esc, 1–9) without
/// becoming the app's main window.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Zest has no main menu, so nothing routes ⌘X/⌘C/⌘V/⌘A/⌘Z to a text
    /// field in a panel; send them to the first responder directly.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command {
            // By physical key, so the shortcuts work on non-Latin layouts too.
            let action: Selector?
            switch event.keyCode {
            case 7: action = #selector(NSText.cut(_:))         // X
            case 8: action = #selector(NSText.copy(_:))        // C
            case 9: action = #selector(NSText.paste(_:))       // V
            case 0: action = #selector(NSText.selectAll(_:))   // A
            case 6: action = Selector(("undo:"))               // Z
            default: action = nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Drag destination covering the whole panel. It reads the dragged file URLs
/// the moment a drag enters, so the wheel can bloom *before* the drop, then
/// maps the pointer to a slice with the same `WheelGeometry` the wheel draws
/// with — release over a slice converts straight away.
final class DropTargetView: NSView {
    weak var model: ConversionModel?

    override var isFlipped: Bool { true }   // top-left origin, matching SwiftUI and PanelLayout

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .URL])   // files, and links dragged from a browser
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let model, model.beginDragPreview(Self.droppedURLs(sender)) else { return [] }
        updateHover(sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let model else { return [] }
        switch model.phase {
        case .previewing:
            updateHover(sender)
            return .copy
        case .linkHover:
            return .copy
        case .converting, .fetching, .rejected:
            return []
        default:
            // The drag arrived while Zest was busy and the job has since
            // finished: take it now rather than refusing until it re-enters.
            guard model.beginDragPreview(Self.droppedURLs(sender)) else { return [] }
            updateHover(sender)
            return .copy
        }
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        model?.endDragPreview()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        switch model?.phase {
        case .previewing?, .linkHover?: return true
        default: return false
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        updateHover(sender)
        model?.commitDrop()
        // The drag came from another app (Finder), which is still frontmost.
        // Take key focus — without activating Zest — so the wheel's keys work.
        DispatchQueue.main.async { [weak self] in self?.window?.makeKey() }
        return true
    }

    /// Safety net: a refused drop (unsupported files) may end without an exit.
    override func draggingEnded(_ sender: NSDraggingInfo) {
        guard let model else { return }
        switch model.phase {
        case .previewing, .rejected, .linkHover: model.endDragPreview()
        default: break
        }
    }

    private func updateHover(_ info: NSDraggingInfo) {
        guard let model, case let .previewing(batch) = model.phase else { return }
        let point = convert(info.draggingLocation, from: nil)
        let frame = PanelLayout.wheelFrame
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        model.hover(WheelGeometry(count: batch.targets.count).slice(at: local))
    }

    /// File URLs and web links on a drag pasteboard.
    static func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
        urls(on: info.draggingPasteboard)
    }

    /// File URLs and web links on a pasteboard; a plain-text link counts too.
    static func urls(on pasteboard: NSPasteboard) -> [URL] {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? [])
            .filter { $0.isFileURL || LinkDownloader.isWebLink($0) }
        if !urls.isEmpty { return urls }
        return pasteboard.string(forType: .string).flatMap(LinkDownloader.link(from:)).map { [$0] } ?? []
    }
}

/// Owns the floating drop panel: showing, hiding, keyboard, and file picking.
@MainActor
final class DropController {
    private static let autosaveName = "ZestDropPanel"

    private let model: ConversionModel
    private var panel: FloatingPanel?
    private var keyMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []

    /// Opens Settings (wired by AppDelegate), for the Failed card's sign-in fix.
    var openSettings: (@MainActor () -> Void)?

    init(model: ConversionModel) {
        self.model = model
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Show the panel and give it key focus without activating Zest: the
    /// app you were in stays frontmost (it's a non-activating panel).
    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        panel?.orderOut(nil)
        if !model.isBusy { model.reset() }
    }

    func toggle() { isVisible ? hide() : show() }

    /// "Convert a file…": pick files, then put them on the wheel.
    func chooseFiles() {
        NSApp.activateZest()
        let open = NSOpenPanel()
        open.title = "Choose Files to Squeeze"
        open.prompt = "Squeeze"
        open.allowsMultipleSelection = true
        open.canChooseFiles = true
        open.canChooseDirectories = false
        guard open.runModal() == .OK, !open.urls.isEmpty else { return }
        model.accept(open.urls)
        show()
    }

    /// Files handed over from elsewhere (menu-bar icon drop, Open With, `zest://open`).
    func open(_ urls: [URL]) {
        model.accept(urls)
        show()
    }

    /// A web link to download (menu field, menu-bar icon drop, ⌘V).
    func openLink(_ link: URL) {
        show()
        model.openLink(link)
    }

    /// Entry point for `zest://download`.
    func runDownloadCommand(_ command: ZestDownloadCommand) {
        show()
        model.run(command)
    }

    /// ⌘V in the panel: files go on the wheel, a link is read for downloading.
    private func paste() {
        let urls = Self.pasteboardURLs()
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty {
            model.accept(files)
        } else if let link = urls.first {
            model.openLink(link)
        } else {
            NSSound.beep()
        }
    }

    private static func pasteboardURLs() -> [URL] {
        DropTargetView.urls(on: .general)
    }

    /// Entry point for `zest://convert`: show the panel and run the command.
    func runURLCommand(_ command: ZestURLCommand) {
        show()
        model.run(command)
    }

    private func makePanel() -> FloatingPanel {
        let size = PanelLayout.size
        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false        // stay up while the user drags from Finder
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false                // SwiftUI draws the shadows; a window shadow would trace the margin
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setAccessibilityLabel("Zest drop zone")

        let dropView = DropTargetView(frame: NSRect(origin: .zero, size: size))
        dropView.model = model
        let actions = DropActions(close: { [weak self] in self?.hide() },
                                  chooseFile: { [weak self] in self?.chooseFiles() },
                                  openSettings: { [weak self] in self?.openSettings?() })
        let hosting = NSHostingView(rootView: DropWheelView(model: model, actions: actions))
        hosting.sizingOptions = []             // the panel's size is fixed; don't let content resize it
        hosting.frame = dropView.bounds
        hosting.autoresizingMask = [.width, .height]
        dropView.addSubview(hosting)
        panel.contentView = dropView

        if !panel.setFrameUsingName(Self.autosaveName) { center(panel) }
        panel.setFrameAutosaveName(Self.autosaveName)
        installKeyMonitor(for: panel)
        stayBehindZestWindows(panel)
        return panel
    }

    /// The panel floats so it stays a drop target above Finder — but not
    /// above Zest's own Settings window. While a titled Zest window is key the
    /// panel drops to normal level behind it; it floats again afterwards.
    private func stayBehindZestWindows(_ panel: FloatingPanel) {
        let center = NotificationCenter.default
        // Delivered on the main queue; the window is only touched there.
        windowObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak panel] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window, window !== panel, window.styleMask.contains(.titled) else { return }
                panel?.level = .normal
                if let panel, panel.isVisible { panel.order(.below, relativeTo: window.windowNumber) }
            }
        })
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            windowObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak panel] note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let window, window !== panel, window.styleMask.contains(.titled) else { return }
                    panel?.level = .floating
                }
            })
        }
    }

    /// Esc backs out one level (wheel → drop card → hidden); 1–9 and 0 pick a
    /// slice; Return picks the highlighted one; ⌘V pastes files or a link.
    private func installKeyMonitor(for panel: FloatingPanel) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard let panel, event.window === panel else { return event }
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.intersection([.command, .shift, .option, .control]) == .command, event.keyCode == 9 {   // ⌘V
            paste()   // while busy, the model queues what was pasted
            return true
        }
        // Only real chords disable the keys; Caps Lock, Shift and the keypad don't.
        guard flags.isDisjoint(with: [.command, .control, .option]) else { return false }
        switch event.keyCode {
        case 53:   // Esc
            if !model.cancel() { hide() }
            return true
        case 36, 76:   // Return, Enter
            if let index = model.hoveredSlice { model.pick(index: index); return true }
            return false
        default:
            // By physical key, so the digit row works on AZERTY and other layouts.
            guard let digit = Self.digitKeys[event.keyCode] else { return false }
            model.pick(index: digit == 0 ? 9 : digit - 1)
            return true
        }
    }

    /// Key codes of the digit row and keypad → the digit they carry on ANSI.
    private static let digitKeys: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 0,
        83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9, 82: 0,
    ]

    private func center(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
    }
}

extension NSApplication {
    /// Bring Zest forward (an accessory app must, before showing panels).
    func activateZest() {
        if #available(macOS 14, *) { activate() } else { activate(ignoringOtherApps: true) }
    }
}
