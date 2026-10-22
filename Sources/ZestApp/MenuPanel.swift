import AppKit
import SwiftUI
import ZestKit

// MARK: - Panel controller

/// Shows the Citrus menu under the status item. It is a borderless,
/// non-activating panel that behaves like a menu: the status item stays
/// highlighted while it is open, it takes key focus (so Esc, the ⌘ shortcuts
/// and typing in the link field work), and it closes on a click outside, on
/// Esc, when Zest resigns active, and after any action.
///
/// The clipboard is never read on open (macOS would ask the user about it);
/// ⌘V pastes into the link field like any text field, and the controller
/// only moves focus there first if nothing else is being edited.
@MainActor
final class MenuPanelController {
    /// Transparent margin around the card so its SwiftUI shadow isn't
    /// clipped. Deepest at the bottom, where the shadow falls; shallower on
    /// top than the gap below the menu bar, so the panel never overlaps (and
    /// steals clicks from) the status item.
    private static let margin = EdgeInsets(top: 4, leading: 24, bottom: 40, trailing: 24)
    /// Gap between the menu bar and the card's top edge.
    private static let gapBelowMenuBar: CGFloat = 6
    /// Closest the card may come to the edges of the screen's visible area.
    private static let screenInset: CGFloat = 8
    /// How far the card slides down as it appears.
    private static let slideDistance: CGFloat = 6

    private let model: ConversionModel
    private let recents: RecentsStore
    private let actions: MenuActions
    private var panel: FloatingPanel?
    private var content: NSHostingController<MenuPanelContent>?
    private weak var anchor: NSStatusBarButton?
    private var eventMonitors: [Any] = []
    private var appObservers: [NSObjectProtocol] = []
    /// Bumped on every show so the card starts with fresh view state: a row
    /// hovered when the menu last closed never hears the mouse leave.
    private var session = 0
    /// The link field's text, fresh per show; read here for Esc.
    private var linkEntry = LinkEntry()

    init(model: ConversionModel, recents: RecentsStore, actions: MenuActions) {
        self.model = model
        self.recents = recents
        self.actions = actions
    }

    var isShown: Bool { panel?.isVisible ?? false }

    func toggle(relativeTo button: NSStatusBarButton) {
        if isShown { close() } else { show(relativeTo: button) }
    }

    func close() {
        removeMonitors()
        anchor?.highlight(false)
        // End any editing so a half-typed link doesn't keep the field editor
        // attached to a view the next show replaces.
        panel?.makeFirstResponder(nil)
        panel?.orderOut(nil)
    }

    // MARK: Showing

    private func show(relativeTo button: NSStatusBarButton) {
        recents.pruneMissing()
        if panel == nil { makePanel() }
        guard let panel, let content else { return }
        anchor = button
        session += 1
        linkEntry = LinkEntry()
        content.rootView = rootView()

        // Proposing zero gets the content's natural size: card plus margin.
        let frame = frame(forPanel: content.sizeThatFits(in: .zero), under: button)
        // No activation: a non-activating panel takes key focus (typing, Esc,
        // ⌘ shortcuts) while the app you were in stays frontmost, like a menu.
        installMonitors()
        button.highlight(true)

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
            panel.setFrame(frame, display: false)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.alphaValue = 0
            panel.setFrame(frame.offsetBy(dx: 0, dy: Self.slideDistance), display: false)
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
        }
        // Open with nothing focused (AppKit would otherwise focus the link
        // field on the panel's first show only): the card opens calm, and
        // VoiceOver starts on the menu. A click, Tab or ⌘V reaches the field.
        panel.makeFirstResponder(nil)
    }

    private func makePanel() {
        let panel = FloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false                // SwiftUI draws the card's shadow
        panel.hidesOnDeactivate = false        // closed explicitly, so the monitors go with it
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none        // the slide-in is ours
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.setAccessibilityLabel("Zest menu")

        let content = NSHostingController(rootView: rootView())
        content.sizingOptions = []             // the panel's size is set here, not by SwiftUI
        panel.contentViewController = content
        self.panel = panel
        self.content = content
    }

    private func rootView() -> MenuPanelContent {
        // Every action closes the menu first, whatever the caller wires up.
        let actions = self.actions
        let closing = MenuActions(
            convertFile: { [weak self] in self?.close(); actions.convertFile() },
            downloadLink: { [weak self] link in self?.close(); actions.downloadLink(link) },
            showDropZone: { [weak self] in self?.close(); actions.showDropZone() },
            openSettings: { [weak self] in self?.close(); actions.openSettings() },
            quit: { [weak self] in self?.close(); actions.quit() })
        let menu = CitrusMenuView(model: model, recents: recents, actions: closing,
                                  linkEntry: linkEntry,
                                  dismiss: { [weak self] in self?.close() })
        return MenuPanelContent(menu: menu, session: session, margin: Self.margin,
                                onCardSize: { [weak self] size in self?.cardSizeChanged(size) })
    }

    /// The card grew or shrank while open (a recent added or cleared, the
    /// progress bar shown): refit the panel, keeping its top edge in place.
    private func cardSizeChanged(_ card: CGSize) {
        // Deferred: resizing the window mid-layout would re-enter SwiftUI's layout pass.
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible, let anchor = self.anchor else { return }
            let m = Self.margin
            let size = CGSize(width: card.width + m.leading + m.trailing, height: card.height + m.top + m.bottom)
            guard size != panel.frame.size else { return }
            panel.setFrame(self.frame(forPanel: size, under: anchor), display: true)
        }
    }

    /// Screen frame for a panel of `size` (card plus margin): the card's top
    /// sits just under the menu bar and its right edge lines up with the
    /// status item's, clamped inside the screen's visible area.
    private func frame(forPanel size: CGSize, under button: NSStatusBarButton) -> NSRect {
        let m = Self.margin
        let card = CGSize(width: size.width - m.leading - m.trailing, height: size.height - m.top - m.bottom)
        guard let buttonWindow = button.window else { return NSRect(origin: .zero, size: size) }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))

        var origin = CGPoint(x: buttonFrame.maxX - card.width,
                             y: buttonWindow.frame.minY - Self.gapBelowMenuBar - card.height)
        if let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame {
            let bounds = visible.insetBy(dx: Self.screenInset, dy: Self.screenInset)
            origin.x = min(max(origin.x, bounds.minX), bounds.maxX - card.width)
            origin.y = max(origin.y, bounds.minY)
        }
        return NSRect(x: origin.x - m.leading, y: origin.y - m.bottom, width: size.width, height: size.height)
    }

    // MARK: Dismissal

    private func installMonitors() {
        removeMonitors()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks in other apps.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            eventMonitors.append(monitor)
        }
        // Clicks in Zest's other windows, and Esc.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown), handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleLocalEvent(event) ?? false }
            return consumed ? nil : event
        }) {
            eventMonitors.append(monitor)
        }
        let center = NotificationCenter.default
        appObservers = [
            // Zest was active (Settings open) and the user switched apps.
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            },
        ]
    }

    private func removeMonitors() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
        appObservers.forEach(NotificationCenter.default.removeObserver)
        appObservers.removeAll()
    }

    /// Returns true when the event was handled and should go no further.
    private func handleLocalEvent(_ event: NSEvent) -> Bool {
        if event.type == .keyDown {
            guard let panel, event.window === panel else { return false }
            if event.keyCode == 53 { return escape(in: panel) }   // Esc
            if Self.isPaste(event) { focusLinkFieldForPaste(in: panel) }
            return false
        }
        if let panel, event.window === panel {
            // The shadow margin is part of the window but not of the menu.
            if !cardRect(in: panel).contains(event.locationInWindow) { close() }
            return false
        }
        // A click on the status item passes untouched: its own action toggles
        // the menu, and closing here as well would race it into reopening.
        if event.window !== anchor?.window { close() }
        return false
    }

    /// The card's rect in the panel's window coordinates (bottom-left origin).
    private func cardRect(in panel: NSPanel) -> NSRect {
        let m = Self.margin
        let size = panel.frame.size
        return NSRect(x: m.leading, y: m.bottom,
                      width: size.width - m.leading - m.trailing, height: size.height - m.top - m.bottom)
    }

    // MARK: Link field keys

    /// Esc in the link field clears what's typed first; otherwise it closes
    /// the menu. An input method mid-composition keeps Esc for itself.
    private func escape(in panel: NSPanel) -> Bool {
        if let editor = Self.fieldEditor(in: panel) {
            if editor.hasMarkedText() { return false }
            if !linkEntry.text.isEmpty {
                linkEntry.text = ""
                return true
            }
        }
        close()
        return true
    }

    /// ⌘V with nothing being edited: put the link field in focus first, so
    /// the paste the panel forwards to the first responder lands there. The
    /// paste itself is the user's — the clipboard is read only by it.
    private func focusLinkFieldForPaste(in panel: NSPanel) {
        guard Self.fieldEditor(in: panel) == nil,
              let field = Self.editableTextField(in: panel.contentView), field.isEnabled else { return }
        panel.makeFirstResponder(field)
    }

    private static func isPaste(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
            && event.keyCode == 9   // V, by physical key so non-Latin layouts work
    }

    /// The text being edited in the panel, if a field has focus.
    private static func fieldEditor(in panel: NSPanel) -> NSTextView? {
        guard let editor = panel.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
        return editor
    }

    /// The menu's one editable text field (the link field's AppKit backing).
    private static func editableTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = editableTextField(in: subview) { return field }
        }
        return nil
    }
}

/// What's typed in the menu's link field, and whether the "not a link" hint
/// shows. Shared between the card and its controller (which handles Esc).
@MainActor
final class LinkEntry: ObservableObject {
    @Published var text = "" {
        didSet { if text != oldValue { showsHint = false } }   // typing clears the hint
    }
    @Published var showsHint = false
    /// Tools a link download needs but Zest can't find, checked once per
    /// menu: yt-dlp reads and fetches the link, ffmpeg merges and converts.
    let missingTools: [String] = {
        let tools = LinkDownloader()
        return [tools.ytdlp == nil ? "yt-dlp" : nil, tools.ffmpeg == nil ? "ffmpeg" : nil].compactMap { $0 }
    }()

    /// The typed text as a downloadable link, if it is one.
    var link: URL? { LinkDownloader.link(from: text) }
}

/// The panel's content: the card at its natural size inside the transparent
/// shadow margin, reporting size changes so the controller can refit.
private struct MenuPanelContent: View {
    let menu: CitrusMenuView
    /// A new value rebuilds the card, resetting hover and other view state.
    let session: Int
    let margin: EdgeInsets
    let onCardSize: @MainActor (CGSize) -> Void

    var body: some View {
        menu
            .id(session)
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in onCardSize(size) }
            .padding(margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Menu card

/// The Citrus menu card: the Zest header with live status, "Convert a file…",
/// a field to paste a link to download, the last few squeezed files, and
/// footer links. 300pt wide, as tall as its content.
struct CitrusMenuView: View {
    @ObservedObject var model: ConversionModel
    @ObservedObject var recents: RecentsStore
    let actions: MenuActions
    /// Called after a recent file is revealed, so the host can close.
    let dismiss: @MainActor () -> Void
    @StateObject private var linkEntry: LinkEntry

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `linkEntry` lets the host see the link field's text (for Esc); without
    /// one the card keeps its own.
    init(model: ConversionModel, recents: RecentsStore, actions: MenuActions,
         linkEntry: LinkEntry? = nil, dismiss: @escaping @MainActor () -> Void = {}) {
        _model = ObservedObject(wrappedValue: model)
        _recents = ObservedObject(wrappedValue: recents)
        _linkEntry = StateObject(wrappedValue: linkEntry ?? LinkEntry())
        self.actions = actions
        self.dismiss = dismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            convertButton
            LinkField(entry: linkEntry, isBusy: model.isBusy, busyReason: busyReason,
                      download: actions.downloadLink)
            recentsSection
            footer
        }
        .padding(14)
        .frame(width: 300)
        .background(card)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Zest menu")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            CitrusLogo(size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Zest")
                    .font(Citrus.display(18))
                    .foregroundStyle(Citrus.ink)
                Text(model.statusLine)
                    .font(Citrus.text(12))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                if let fraction = progress {
                    ProgressView(value: fraction)
                        .progressViewStyle(SqueezeBarStyle())
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: fraction)
                        .padding(.top, 5)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 2, leading: 4, bottom: 6, trailing: 4))
        .accessibilityElement(children: .combine)
    }

    /// Overall progress while a squeeze or download runs.
    private var progress: Double? {
        if case let .converting(_, _, _, fraction) = model.phase { return fraction }
        return nil
    }

    private var statusColor: Color {
        if case .failed = model.phase { return Citrus.danger }
        return Citrus.inkSoft
    }

    /// Why new work has to wait, for tooltips.
    private var busyReason: String {
        switch model.phase {
        case .fetching: return "Wait while Zest reads the link"
        case let .converting(batch, _, _, _) where batch.isLink: return "Wait for this download to finish"
        default: return "Wait for this squeeze to finish"
        }
    }

    // MARK: Convert

    private var convertButton: some View {
        Button(action: actions.convertFile) {
            Text("Convert a file…")
        }
        .buttonStyle(CitrusPrimaryButtonStyle())
        .keyboardShortcut("o", modifiers: .command)
        .disabled(model.isBusy)
        .opacity(model.isBusy ? 0.5 : 1)
        .help(model.isBusy ? busyReason : "Choose files to squeeze (⌘O)")
    }

    // MARK: Recents

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recently squeezed")
                    .font(Citrus.text(12, .bold))
                    .foregroundStyle(Citrus.inkSoft)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if !recents.items.isEmpty {
                    MenuTextButton(title: "Clear", font: Citrus.text(12, .medium), horizontalPadding: 6,
                                   action: recents.clear)
                        .padding(.vertical, -6)   // keep the header row as tall as its text
                        .accessibilityLabel("Clear recent files")
                        .help("Clear the list (the files stay where they are)")
                }
            }
            .padding(EdgeInsets(top: 8, leading: 4, bottom: 0, trailing: 0))

            if recents.items.isEmpty {
                emptyRecents
            } else {
                ForEach(recents.items.prefix(RecentsStore.limit)) { item in
                    RecentRow(item: item) {
                        recents.reveal(item)
                        dismiss()
                    }
                }
            }
        }
    }

    private var emptyRecents: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return VStack(spacing: 3) {
            Text("Nothing squeezed yet")
                .font(Citrus.display(14))
                .foregroundStyle(Citrus.ink)
            Text("Files you squeeze or download land here.")
                .font(Citrus.text(12))
                .foregroundStyle(Citrus.inkSoft)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(shape.fill(Citrus.wash))
        // Dashed edge echoes the drop zone's ring.
        .overlay(shape.strokeBorder(Citrus.dashedRing.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        .accessibilityElement(children: .combine)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Citrus.line)
                .frame(height: 1)
                .accessibilityHidden(true)
            HStack(spacing: 0) {
                MenuTextButton(title: "Drop zone", action: actions.showDropZone)
                    .keyboardShortcut("d", modifiers: .command)
                    .accessibilityLabel("Show drop zone")
                    .help("Show the drop zone (⌘D)")
                Spacer(minLength: 0)
                MenuTextButton(title: "Settings", action: actions.openSettings)
                    .keyboardShortcut(",", modifiers: .command)
                    .help("Open Settings (⌘,)")
                Spacer(minLength: 0)
                MenuTextButton(title: "Quit", action: actions.quit)
                    .keyboardShortcut("q", modifiers: .command)
                    .accessibilityLabel("Quit Zest")
                    .help("Quit Zest (⌘Q)")
            }
            .padding(.top, 8)
        }
    }

    // MARK: Card

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: Citrus.Radius.menu, style: .continuous)
        return shape
            .fill(Citrus.surface)
            // In dark mode a hairline keeps the card's edge from melting into
            // a dark desktop; in light mode the warm shadow does that job.
            .overlay(shape.strokeBorder(Citrus.line.opacity(colorScheme == .dark ? 1 : 0), lineWidth: 1))
            .shadow(color: Citrus.shadow, radius: 16, y: 12)
    }
}

// MARK: - Pieces

/// "Paste a link to download…": a rounded field with a link glyph and a round
/// arrow that lights up once the text is a link. Return or the arrow hands
/// the link over (the menu closes and the drop zone reads it); anything else
/// gets a gentle inline hint.
private struct LinkField: View {
    @ObservedObject var entry: LinkEntry
    let isBusy: Bool
    let busyReason: String
    let download: @MainActor (URL) -> Void
    @FocusState private var focused: Bool

    /// `--snapshot` draws the menu with ImageRenderer, which can't draw
    /// AppKit-backed controls (a TextField comes out as a yellow "unsupported"
    /// box). Everything visible in the empty field is SwiftUI, so snapshots
    /// leave the empty NSTextField out and show the same resting look.
    private static let drawsStaticField = CommandLine.arguments.contains("--snapshot")
    private static let placeholder = "Paste a link to download…"
    private static let notALink = "That doesn't look like a link"
    private static let sites = "Paste a link from YouTube, Instagram, Facebook, Pinterest and more"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            field
            if entry.showsHint {
                note(Text(Self.notALink), symbol: "exclamationmark.circle.fill", color: Citrus.danger)
            } else if !entry.missingTools.isEmpty {
                setupNote(entry.missingTools)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var field: some View {
        let shape = RoundedRectangle(cornerRadius: Citrus.Radius.control, style: .continuous)
        let lit = focused && !isBusy
        return HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(lit ? Citrus.accent : Citrus.inkSoft)
                .accessibilityHidden(true)
            ZStack(alignment: .leading) {
                if entry.text.isEmpty {
                    Text(Self.placeholder)
                        .font(Citrus.text(14))
                        .foregroundStyle(Citrus.inkSoft)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                if !Self.drawsStaticField {
                    TextField("", text: $entry.text)
                        .textFieldStyle(.plain)
                        .font(Citrus.text(14))
                        .foregroundStyle(Citrus.ink)
                        .tint(Citrus.accent)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .onSubmit(submit)
                        .accessibilityLabel("Link to download")
                        .accessibilityHint(Self.sites + ", then press Return")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: submit) {
                Image(systemName: "arrow.down")
            }
            .buttonStyle(RoundArrowButtonStyle())
            .disabled(entry.link == nil)
            .accessibilityLabel("Download link")
            .help(entry.link == nil ? "Paste a link first" : "Download this link (Return)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 40)
        .background(shape.fill(Citrus.wash))
        .overlay(shape.strokeBorder(lit ? Citrus.accent : Citrus.line, lineWidth: lit ? 1.5 : 1))
        // A click on the glyph or the padding focuses the field too.
        .contentShape(shape)
        .onTapGesture { focused = true }
        .disabled(isBusy)
        .opacity(isBusy ? 0.5 : 1)
        .help(isBusy ? busyReason : Self.sites + " (⌘V), then press Return")
    }

    /// "Links need yt-dlp: brew install yt-dlp" — the command is selectable so
    /// it can be copied into Terminal. Two missing tools put it on its own line.
    private func setupNote(_ tools: [String]) -> some View {
        let lead = "Links need " + tools.joined(separator: " and ") + (tools.count > 1 ? ":\n" : ": ")
        let command = "brew install " + tools.joined(separator: " ")
        return note(Text(verbatim: lead) + Text(verbatim: command).font(Citrus.mono(11, .medium)),
                    symbol: "info.circle", color: Citrus.inkSoft)
            .textSelection(.enabled)
    }

    private func note(_ text: Text, symbol: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)
            text
                .font(Citrus.text(12, .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
        .padding(.leading, 6)
        .accessibilityElement(children: .combine)
    }

    private func submit() {
        guard !isBusy else { return }
        if let link = entry.link {
            entry.text = ""
            download(link)
        } else if !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entry.showsHint = true
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: Self.notALink,
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
}

/// The link field's round accent arrow; a quiet disc until there's a link.
private struct RoundArrowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundArrow(label: configuration.label, isPressed: configuration.isPressed)
    }

    private struct RoundArrow<Label: View>: View {
        let label: Label
        let isPressed: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            label
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isEnabled ? Citrus.onAccent : Citrus.inkSoft.opacity(0.6))
                .frame(width: 28, height: 28)
                .background(Circle().fill(isEnabled ? (isPressed ? Citrus.accentPressed : Citrus.accent) : Citrus.line))
                .contentShape(Circle())
        }
    }
}

/// One "Recently squeezed" row: file name and target chip. Clicking reveals
/// the file in Finder.
private struct RecentRow: View {
    let item: RecentItem
    let reveal: @MainActor () -> Void
    @StateObject private var hovering = ViewState(false)

    var body: some View {
        let format = item.targetID.uppercased()
        Button(action: reveal) {
            HStack(spacing: 8) {
                Text(item.fileName)
                    .font(Citrus.text(14))
                    .foregroundStyle(Citrus.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                FormatChip(label: format, category: item.format?.category ?? .document)
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
        }
        .buttonStyle(HighlightButtonStyle(isHovered: hovering.value, radius: 10))
        .onHover { hovering.value = $0 }
        .help("Show in Finder: \((item.outputPath as NSString).abbreviatingWithTildeInPath)")
        .accessibilityLabel("\(item.fileName), \(format)")
        .accessibilityHint("Shows the file in Finder")
    }
}

/// Text button for the footer links and "Clear".
private struct MenuTextButton: View {
    let title: String
    var font: Font = Citrus.text(13, .bold)
    var horizontalPadding: CGFloat = 8
    let action: @MainActor () -> Void
    @StateObject private var hovering = ViewState(false)

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(font)
                .foregroundStyle(Citrus.inkSoft)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 6)
        }
        .buttonStyle(HighlightButtonStyle(isHovered: hovering.value, radius: 8))
        .onHover { hovering.value = $0 }
    }
}

/// Plain button whose background warms on hover and deepens while pressed.
private struct HighlightButtonStyle: ButtonStyle {
    var isHovered: Bool
    var radius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let fill = configuration.isPressed ? Citrus.line : isHovered ? Citrus.soft : Color.clear
        return configuration.label
            .background(shape.fill(fill))
            .contentShape(shape)
    }
}

/// Slim accent bar for the header while a squeeze runs.
private struct SqueezeBarStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        let fraction = min(max(configuration.fractionCompleted ?? 0, 0), 1)
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Citrus.line)
                Capsule().fill(Citrus.progress)
                    .frame(width: max(proxy.size.height, proxy.size.width * fraction))
            }
        }
        .frame(height: 4)
    }
}
