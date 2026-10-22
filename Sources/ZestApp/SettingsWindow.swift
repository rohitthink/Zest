import AppKit
import SwiftUI
import ZestKit

/// The panes of the Settings window, in tab-bar order.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, output, shortcuts, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .output: return "Output"
        case .shortcuts: return "Shortcuts"
        case .advanced: return "Advanced"
        }
    }
}

// MARK: - Window

/// Owns the Settings window. It is built on first `show()` and reused after,
/// so the chosen tab and frame survive closing it.
@MainActor
final class SettingsWindowController {
    private static let autosaveName = "ZestSettings"
    private static let contentSize = NSSize(width: 600, height: 560)

    private let settings: ZestSettings
    private var window: NSWindow?
    /// The pane on show, owned here so a caller can open a specific one.
    private let tab = ViewState(SettingsTab.general)

    init(settings: ZestSettings) {
        self.settings = settings
    }

    /// Show Settings, optionally on a given pane (the drop panel's sign-in
    /// failure opens Output).
    func show(tab requested: SettingsTab? = nil) {
        if let requested { tab.value = requested }
        let window = window ?? makeWindow()
        self.window = window
        settings.refreshLaunchAtLogin()
        NSApp.activateZest()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = SettingsWindow(contentRect: NSRect(origin: .zero, size: Self.contentSize),
                                    styleMask: [.titled, .closable, .fullSizeContentView],
                                    backing: .buffered, defer: false)
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        // Bridging keeps the token's light/dark provider, so the titlebar
        // band matches the content under it in either appearance.
        window.backgroundColor = NSColor(Citrus.surface)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed                  // never merged into a tab group
        window.collectionBehavior.insert(.moveToActiveSpace)   // open on the current Space, not where it was left

        let hosting = NSHostingView(rootView: CitrusSettingsView(settings: settings, tab: tab))
        hosting.sizingOptions = []             // fixed-size window; content never resizes it
        window.contentView = hosting

        if !window.setFrameUsingName(Self.autosaveName) { window.center() }
        window.setFrameAutosaveName(Self.autosaveName)
        return window
    }
}

/// Zest is an accessory app with no main menu, so the window answers the
/// standard key equivalents itself: ⌘W closes, ⌘C copies selected text.
private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Compare only the chord modifiers, so Caps Lock doesn't break ⌘W.
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command {
            switch event.keyCode {   // physical keys, so non-Latin layouts work too
            case 13:   // W
                performClose(nil)
                return true
            case 8:    // C
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Content

/// Settings in the Citrus language: a pill tab bar over grouped wash
/// sections. The top 44pt is left clear for the transparent titlebar.
struct CitrusSettingsView: View {
    @ObservedObject var settings: ZestSettings
    @ObservedObject private var tab: ViewState<SettingsTab>

    init(settings: ZestSettings, initialTab: SettingsTab = .general) {
        self.init(settings: settings, tab: ViewState(initialTab))
    }

    /// With the controller's tab state, so it can open a given pane.
    init(settings: ZestSettings, tab: ViewState<SettingsTab>) {
        self.settings = settings
        self.tab = tab
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsTabBar(selection: $tab.value)
                .padding(.top, 46)
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { pane }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
            .modifier(BounceOnlyWhenScrollable())
            // Taller panes scroll; a soft fade at the edge says "more below"
            // instead of a hard cut. It sits over the bottom padding, so a
            // pane that fits (or is scrolled to the end) shows nothing under it.
            // Kept inside the 24pt gutters so it never washes out the scroller.
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [Citrus.surface.opacity(0), Citrus.surface],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 22)
                    .padding(.horizontal, 24)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Citrus.surface)
        .ignoresSafeArea()
    }

    @ViewBuilder private var pane: some View {
        switch tab.value {
        case .general: GeneralPane(settings: settings)
        case .output: OutputPane(settings: settings)
        case .shortcuts: ShortcutsPane()
        case .advanced: AdvancedPane(settings: settings)
        }
    }
}

/// Capsule tabs; ⌘1–⌘4 jump straight to a pane.
private struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(SettingsTab.allCases.enumerated()), id: \.element) { index, tab in
                let isSelected = tab == selection
                Button(tab.title) { selection = tab }
                    .buttonStyle(PillButtonStyle(isSelected: isSelected, height: 36, font: Citrus.display(14)))
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .help("\(tab.title) (⌘\(index + 1))")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var settings: ZestSettings

    var body: some View {
        SettingsSection {
            SectionTitle("Where should squeezed files go?")
            DestinationPicker(selection: $settings.destination)
        }

        SettingsSection {
            HStack {
                SectionTitle("Quality")
                Spacer()
                ValueChip(text: "\(percent)%")
                    .accessibilityHidden(true)
            }
            Slider(value: $settings.quality, in: 0.1...1) { Text("Quality") }
                .labelsHidden()
                .tint(Citrus.accent)
                .accessibilityValue("\(percent) percent")
            HStack {
                Text("Smaller files")
                Spacer()
                Text("Sharper results")
            }
            .font(Citrus.text(12, .semibold))
            .foregroundStyle(Citrus.inkSoft)
        }

        SettingsSection(rows: true) {
            Toggle("Remove location & camera info", isOn: $settings.stripMetadata)
                .citrusRow()
                .help("Strips GPS position, camera model and other EXIF details from images")
            Hairline()
            LaunchAtLoginRow(settings: settings)
            Hairline()
            Toggle("Show the drop zone when Zest opens", isOn: $settings.showDropZoneOnLaunch)
                .citrusRow()
        }
    }

    private var percent: Int { Int((settings.quality * 100).rounded()) }
}

/// Three option cards for `OutputDestination`; VoiceOver sees a radio group.
private struct DestinationPicker: View {
    @Binding var selection: OutputDestination

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(OutputDestination.allCases) { destination in
                Button { selection = destination } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(destination.title)
                            .font(Citrus.text(14, .bold))
                            .foregroundStyle(Citrus.ink)
                        Text(destination.subtitle)
                            .font(Citrus.text(12))
                            .foregroundStyle(Citrus.inkSoft)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 18)   // room for the check badge, on every card so wrapping never shifts
                }
                .buttonStyle(OptionCardStyle(isSelected: destination == selection))
            }
        }
        .fixedSize(horizontal: false, vertical: true)   // equal-height cards
        .radioGroupAccessibility("Where should squeezed files go?", selection: $selection,
                                 options: OutputDestination.allCases.map { ($0, $0.title) })
    }
}

/// "Launch Zest at login": mirrors SMAppService, explains when it can't apply.
private struct LaunchAtLoginRow: View {
    @ObservedObject var settings: ZestSettings
    @StateObject private var failure = ViewState<String?>(nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle("Launch Zest at login", isOn: isOn)
                .citrusRow()
                .disabled(!settings.launchAtLoginAvailable)
                .accessibilityHint(settings.launchAtLoginAvailable ? "" : "Available in the installed app")
            if hasFootnote {
                VStack(alignment: .leading, spacing: 4) {
                    if !settings.launchAtLoginAvailable {
                        Footnote("Available in the installed app")
                    }
                    if let message = failure.value {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(Citrus.text(12))
                            .foregroundStyle(Citrus.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if settings.launchAtLoginNeedsApproval {
                        Button("Approve in System Settings…") { settings.openLoginItemsSettings() }
                            .buttonStyle(InlineLinkStyle())
                            .help("Opens Login Items in System Settings")
                    }
                }
                .padding(.top, -8)     // tuck under the row's label
                .padding(.bottom, 12)
            }
        }
    }

    private var hasFootnote: Bool {
        !settings.launchAtLoginAvailable || failure.value != nil || settings.launchAtLoginNeedsApproval
    }

    private var isOn: Binding<Bool> {
        Binding(
            get: { settings.launchAtLogin },
            set: { enabled in
                do {
                    try settings.setLaunchAtLogin(enabled)
                    failure.value = nil
                } catch {
                    failure.value = "Couldn’t change this: \(error.localizedDescription)"
                }
            })
    }
}

// MARK: - Output

private struct OutputPane: View {
    @ObservedObject var settings: ZestSettings

    var body: some View {
        SettingsSection {
            SectionTitle("Longest side")
            Text("Big photos and videos are scaled down to fit. Smaller ones are left as they are.")
                .font(Citrus.text(12))
                .foregroundStyle(Citrus.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(ZestSettings.maxDimensionChoices, id: \.self) { value in
                    Button(Self.label(for: value)) { settings.maxDimension = value }
                        .buttonStyle(PillButtonStyle(isSelected: settings.maxDimension == value,
                                                     height: 32, font: Citrus.display(13), outlined: true))
                }
            }
            .padding(.top, 2)
            .radioGroupAccessibility("Longest side", selection: $settings.maxDimension,
                                     options: ZestSettings.maxDimensionChoices.map {
                                         ($0, $0 == 0 ? "Original size" : "\($0) pixels")
                                     })
        }

        SettingsSection(rows: true) {
            Toggle("Show in Finder when done", isOn: $settings.revealWhenDone)
                .citrusRow()
            Hairline()
            Toggle("Play a sound when done", isOn: $settings.playSound)
                .citrusRow()
        }

        LinkDownloadsSection(settings: settings)

        SettingsSection {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .font(Citrus.text(13))
                    .foregroundStyle(Citrus.peel)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("When Zest names the file, it never overwrites one: if the name is taken, you get photo (2).jpg.")
                    Text("Strip keeps the format and saves a clean copy as photo-clean.jpg.")
                }
                .font(Citrus.text(12))
                .foregroundStyle(Citrus.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private static func label(for maxDimension: Int) -> String {
        maxDimension == 0 ? "Original" : "\(maxDimension) px"
    }
}

/// Output › Downloading links: where links land, whose browser sign-in
/// yt-dlp may borrow, and a straight answer about audio quality.
private struct LinkDownloadsSection: View {
    @ObservedObject var settings: ZestSettings

    private typealias Source = LinkDownloader.CookieSource

    var body: some View {
        SettingsSection {
            HStack(alignment: .center, spacing: 8) {
                SectionTitle("Downloading links")
                Spacer(minLength: 8)
                LinkDestinationChip(destination: settings.destination)
            }
            Footnote("Links follow “Where should squeezed files go?” in General. A link has no original folder, so “Next to the original” means ~/Downloads.")

            Hairline().padding(.vertical, 4)

            Text("Use sign-in from")
                .font(Citrus.display(14))
                .foregroundStyle(Citrus.ink)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                ForEach(Source.allCases, id: \.self) { source in
                    Button(source.displayName) { settings.linkCookies = source }
                        .buttonStyle(PillButtonStyle(isSelected: settings.linkCookies == source,
                                                     height: 32, font: Citrus.display(13), outlined: true))
                        .help(Self.help(for: source))
                }
            }
            .radioGroupAccessibility("Use sign-in from", selection: $settings.linkCookies,
                                     options: Source.allCases.map { ($0, $0.displayName) })
            Footnote("When on, yt-dlp reads that browser’s sign-in to download private or sign-in-only posts — Instagram stories, some reels, members-only videos. Leave it Off unless you need it.")
            requirement
            AudioHonestyNote()
                .padding(.top, 4)
        }
    }

    /// The chosen browser isn't on this Mac, so there's no sign-in to borrow.
    private var chosenBrowserMissing: Bool {
        settings.linkCookies != .none && !Self.isInstalled(settings.linkCookies)
    }

    /// What the chosen browser needs from macOS (both needs while Off).
    private var requirement: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: chosenBrowserMissing ? "exclamationmark.circle.fill" : "key.fill")
                .font(Citrus.text(11))
                .foregroundStyle(Citrus.peel)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(requirementText)
                    .font(Citrus.text(12, .medium))
                    .foregroundStyle(Citrus.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                if settings.linkCookies == .safari, let url = Self.fullDiskAccessURL {
                    Button("Open Full Disk Access settings…") { NSWorkspace.shared.open(url) }
                        .buttonStyle(InlineLinkStyle())
                        .help("Opens Privacy & Security › Full Disk Access in System Settings")
                }
            }
        }
    }

    private var requirementText: String {
        let source = settings.linkCookies
        if chosenBrowserMissing {
            return "\(source.displayName) doesn’t seem to be installed on this Mac, so there’s no sign-in to read. Pick the browser you sign in with, or Off."
        }
        switch source {
        case .none:
            return "Safari needs Full Disk Access for Zest. Chrome, Brave and Edge ask for Keychain access."
        case .safari:
            return "Safari keeps its sign-in in a protected folder, so Zest needs Full Disk Access."
        case .chrome, .brave, .edge:
            return "macOS asks for access to “\(Self.keychainItem(for: source))” in your keychain — choose Always Allow so it asks once."
        case .firefox:
            return "Nothing to allow — yt-dlp reads the sign-in straight from your Firefox profile."
        }
    }

    private static func help(for source: Source) -> String {
        switch source {
        case .none: return "Download public posts only, without any browser sign-in"
        case .safari: return "Use Safari’s sign-in (needs Full Disk Access for Zest)"
        case .chrome, .brave, .edge: return "Use \(source.displayName)’s sign-in (macOS asks for Keychain access)"
        case .firefox: return "Use Firefox’s sign-in"
        }
    }

    /// The keychain item a Chromium browser locks its cookies with.
    private static func keychainItem(for source: Source) -> String {
        switch source {
        case .brave: return "Brave Safe Storage"
        case .edge: return "Microsoft Edge Safe Storage"
        default: return "Chrome Safe Storage"
        }
    }

    private static func isInstalled(_ source: Source) -> Bool {
        let bundleID: String
        switch source {
        case .none: return true
        case .safari: return true                     // part of macOS
        case .chrome: bundleID = "com.google.Chrome"
        case .brave: bundleID = "com.brave.Browser"
        case .firefox: bundleID = "org.mozilla.firefox"
        case .edge: bundleID = "com.microsoft.edgemac"
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    private static let fullDiskAccessURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
}

/// Where a downloaded link will land, resolved from the destination setting.
private struct LinkDestinationChip: View {
    var destination: OutputDestination

    var body: some View {
        let colors = Citrus.chipColors(for: .image)
        HStack(spacing: 5) {
            Image(systemName: destination == .ask ? "questionmark.folder.fill" : "folder.fill")
                .font(Citrus.text(11, .bold))
            Text(destination == .ask ? "Asks every time" : "~/Downloads")
                .font(Citrus.text(12, .bold))
        }
        .foregroundStyle(colors.foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(colors.background))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(destination == .ask ? "Zest asks where to save each link" : "Links save to Downloads")
        .help("Change this with “Where should squeezed files go?” in General")
    }
}

/// The honest word on audio from links, as a small inset note.
private struct AudioHonestyNote: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "waveform")
                .font(Citrus.text(12, .semibold))
                .foregroundStyle(Citrus.peel)
                .accessibilityHidden(true)
            // "Usually": M4A is the site's own AAC stream untouched, converted only
            // on the rare site without one (the wheel's slice help says which).
            Text("Sites only keep compressed audio. M4A is usually the original stream; MP3 320 and WAV are conversions for compatibility and editing — they can’t add quality back.")
                .font(Citrus.text(12))
                .foregroundStyle(Citrus.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Citrus.Radius.control, style: .continuous).fill(Citrus.surface))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    /// A sample `zest://` URL (named so it doesn't shadow SwiftUI's `Link`).
    private struct URLExample {
        var name: String
        var url: String
    }

    private static let links = [
        URLExample(name: "convert", url: "zest://convert?input=~/Desktop/photo.heic&to=jpg"),
        URLExample(name: "open", url: "zest://open?input=~/Desktop/a.png&input=~/Desktop/b.png"),
        URLExample(name: "download", url: "zest://download?url=https://youtu.be/aqz-KE-bpKQ&as=mp3"),
        URLExample(name: "settings", url: "zest://settings"),
    ]

    private static let downloadCommand = "zest download https://youtu.be/aqz-KE-bpKQ --as best"

    /// Symlink the CLI bundled at Contents/Helpers/zest (see Scripts/package-app.sh).
    private static var helperPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/zest").path }

    /// /usr/local/bin doesn't exist on a fresh Apple-silicon Mac, hence mkdir.
    private static var linkCommand: String {
        "sudo mkdir -p /usr/local/bin && sudo ln -sf \"\(helperPath)\" /usr/local/bin/zest"
    }

    /// Only an installed Zest.app carries the CLI (a `swift run` build doesn't).
    private static var hasBundledCLI: Bool { FileManager.default.isExecutableFile(atPath: helperPath) }

    /// The download choices, by their real names (`as=` and `--as`).
    private static var optionNames: [String] { LinkDownloader.Option.allCases.map(\.rawValue) }

    var body: some View {
        SettingsSection {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(Citrus.text(15, .bold))
                    .foregroundStyle(Citrus.onAccent)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Citrus.accent))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    SectionTitle("Convert File")
                    Text("A Shortcuts action that squeezes with the same engine as the drop zone.")
                        .font(Citrus.text(12))
                        .foregroundStyle(Citrus.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }

        SettingsSection {
            SectionTitle("Links")
            VStack(spacing: 4) {
                ForEach(Self.links, id: \.url) { link in
                    CodeRow(code: link.url, accessibilityName: "\(link.name) link")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("convert also takes")
                    .font(Citrus.text(12, .semibold))
                    .foregroundStyle(Citrus.inkSoft)
                parameters
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("download takes")
                    .font(Citrus.text(12, .semibold))
                    .foregroundStyle(Citrus.inkSoft)
                downloadParameters
            }
        }

        SettingsSection {
            VStack(alignment: .leading, spacing: 2) {
                SectionTitle("Command line")
                Text(Self.hasBundledCLI
                     ? "The zest command ships inside Zest and downloads links too. Link it onto your PATH once:"
                     : "The zest command downloads links too (run it with swift run zest from the source).")
                    .font(Citrus.text(12))
                    .foregroundStyle(Citrus.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if Self.hasBundledCLI {
                CodeRow(code: Self.linkCommand, accessibilityName: "command that puts zest on your PATH")
            }
            CodeRow(code: Self.downloadCommand, accessibilityName: "download command")
            (Text("--as").font(Citrus.mono(11, .semibold)).foregroundColor(Citrus.ink)
             + Text(" takes the same names; leave it off to list what the link offers. ")
             + Text("--out").font(Citrus.mono(11, .semibold)).foregroundColor(Citrus.ink)
             + Text(" picks the folder and ")
             + Text("--cookies").font(Citrus.mono(11, .semibold)).foregroundColor(Citrus.ink)
             + Text(" a browser sign-in.")
            )
            .font(Citrus.text(12))
            .foregroundStyle(Citrus.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }

        SettingsSection {
            SectionTitle("In the drop zone")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    slicesHint; returnHint; escHint; pasteHint
                }
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow { slicesHint; returnHint }
                    GridRow { escHint; pasteHint }
                }
                VStack(alignment: .leading, spacing: 8) {
                    slicesHint; returnHint; escHint; pasteHint
                }
            }
        }
    }

    /// `url` and `as` for zest://download, with every `as` value spelled out.
    private var downloadParameters: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
            GridRow {
                ParameterName("url")
                ParameterNote("a YouTube, Instagram, Facebook, Pinterest… link")
            }
            GridRow {
                ParameterName("as")
                VStack(alignment: .leading, spacing: 2) {
                    optionList
                        .accessibilityLabel(Self.optionNames.joined(separator: ", "))
                    ParameterNote("omit it to choose on the wheel")
                }
            }
        }
        .textSelection(.enabled)
    }

    /// best · compatible · m4a · mp3 · wav · image
    private var optionList: Text {
        var text = Text("")
        for (index, name) in Self.optionNames.enumerated() {
            if index > 0 { text = text + Text(" · ").font(Citrus.text(12)).foregroundColor(Citrus.inkSoft) }
            text = text + Text(name).font(Citrus.mono(11, .semibold)).foregroundColor(Citrus.ink)
        }
        return text
    }

    private var parameters: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
            GridRow {
                ParameterName("to"); ParameterNote("format, e.g. png")
                ParameterName("quality"); ParameterNote("0–1")
            }
            GridRow {
                ParameterName("target-size"); ParameterNote("e.g. 2MB")
                ParameterName("max-dim"); ParameterNote("longest side, px")
            }
            GridRow {
                ParameterName("keep-metadata=1"); ParameterNote("keep camera info")
                ParameterName("output"); ParameterNote("save path")
            }
        }
        .textSelection(.enabled)
    }

    private var slicesHint: some View {
        KeyHint(keys: ["1–9", "0"], action: "pick a slice", spoken: "1 to 9 and 0 pick a slice")
    }
    private var returnHint: some View { KeyHint(keys: ["Return"], action: "picks the highlighted one") }
    private var escHint: some View { KeyHint(keys: ["Esc"], action: "backs out") }
    private var pasteHint: some View {
        KeyHint(keys: ["⌘V"], action: "pastes a link or files", spoken: "Command V pastes a link or files")
    }
}

/// A one-line monospaced snippet with a Copy button.
private struct CodeRow: View {
    var code: String
    var accessibilityName: String
    @StateObject private var copied = ViewState(false)

    var body: some View {
        HStack(spacing: 8) {
            Text(code)
                .font(Citrus.mono(12))
                .foregroundStyle(Citrus.ink)
                .lineLimit(1)
                // A pane that scrolls loses width to a legacy scroller; shrink
                // a touch before cutting an example URL in half.
                .minimumScaleFactor(0.88)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(code)
            Spacer(minLength: 0)
            Button(action: copy) {
                Text(copied.value ? "Copied" : "Copy")
                    .font(Citrus.display(12))
                    .frame(minWidth: 44)
            }
            .buttonStyle(CitrusSoftButtonStyle(height: 22, fullWidth: false))
            .help("Copy to the clipboard")
            .accessibilityLabel(copied.value ? "Copied" : "Copy \(accessibilityName)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(minHeight: 30)
        .background(RoundedRectangle(cornerRadius: Citrus.Radius.control, style: .continuous).fill(Citrus.surface))
        .task(id: copied.value) { @MainActor in
            guard copied.value else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied.value = false
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied.value = true
    }
}

private struct ParameterName: View {
    var name: String
    init(_ name: String) { self.name = name }
    var body: some View {
        Text(name).font(Citrus.mono(11, .semibold)).foregroundStyle(Citrus.ink)
    }
}

private struct ParameterNote: View {
    var note: String
    init(_ note: String) { self.note = note }
    var body: some View {
        Text(note).font(Citrus.text(12)).foregroundStyle(Citrus.inkSoft)
    }
}

/// Key caps followed by what they do, e.g. [Esc] backs out.
private struct KeyHint: View {
    var keys: [String]
    var action: String
    var spoken: String?

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(Citrus.text(11, .semibold))
                        .foregroundStyle(Citrus.ink)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Citrus.surface))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Citrus.line, lineWidth: 1))
                }
            }
            Text(action)
                .font(Citrus.text(12))
                .foregroundStyle(Citrus.inkSoft)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken ?? "\(keys.joined(separator: " ")) \(action)")
    }
}

// MARK: - Advanced

private struct AdvancedPane: View {
    @ObservedObject var settings: ZestSettings
    @StateObject private var engines = ViewState<[Engine]>([])
    @StateObject private var confirmReset = ViewState(false)

    var body: some View {
        SettingsSection {
            SectionTitle("Engines")
            VStack(spacing: 0) {
                ForEach(Array(engines.value.enumerated()), id: \.element.id) { index, engine in
                    if index > 0 { Hairline() }
                    EngineRow(engine: engine)
                }
            }
            if !installCommands.isEmpty {
                Text("Install the missing ones with Homebrew:")
                    .font(Citrus.text(12, .semibold))
                    .foregroundStyle(Citrus.inkSoft)
                ForEach(installCommands, id: \.self) { command in
                    CodeRow(code: command, accessibilityName: "install command")
                }
            }
        }
        .onAppear(perform: refreshEngines)
        // The window is reused: look again when it comes back (say, after a
        // `brew install` in Terminal). Detection is a few file checks.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshEngines()
        }

        SettingsSection {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionTitle("Start fresh")
                    Text("Puts every option back the way Zest shipped.")
                        .font(Citrus.text(12))
                        .foregroundStyle(Citrus.inkSoft)
                }
                Spacer(minLength: 8)
                Button { confirmReset.value = true } label: {
                    Text("Reset all settings…").foregroundStyle(Citrus.danger)
                }
                .buttonStyle(CitrusSoftButtonStyle(height: 36, fullWidth: false))
            }
        }
        .confirmationDialog("Reset all settings?", isPresented: $confirmReset.value, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { settings.resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Destination, quality, browser sign-in and every switch go back to their defaults. Launch at login and your recent files stay as they are.")
        }
    }

    private func refreshEngines() {
        let detected = Engine.detect()
        if detected != engines.value { engines.value = detected }
    }

    /// `brew install …` lines for whatever is missing (formulae together, casks apart).
    private var installCommands: [String] {
        let missing = engines.value.filter { $0.status == .missing }
        let formulae = missing.compactMap(\.formula)
        var commands = formulae.isEmpty ? [] : ["brew install " + formulae.joined(separator: " ")]
        commands += missing.compactMap(\.cask).map { "brew install --cask \($0)" }
        return commands
    }
}

/// A conversion engine and whether Zest can find it.
private struct Engine: Identifiable, Equatable {
    enum Status: Equatable {
        case found(URL), missing, builtIn
    }

    var name: String
    var role: String
    var status: Status
    var formula: String? = nil
    var cask: String? = nil

    var id: String { name }

    static func detect() -> [Engine] {
        func status(_ url: URL?) -> Status { url.map(Status.found) ?? .missing }
        return [
            Engine(name: "ffmpeg", role: "Audio & video", status: status(ToolLocator.find("ffmpeg")), formula: "ffmpeg"),
            Engine(name: "cwebp", role: "WebP images", status: status(ToolLocator.find("cwebp")), formula: "webp"),
            Engine(name: "LibreOffice", role: "Word, Excel & PowerPoint", status: status(DocumentBackend().soffice),
                   cask: "libreoffice"),
            Engine(name: "yt-dlp", role: "Links: YouTube, Instagram, Facebook, Pinterest…",
                   status: status(LinkDownloader().ytdlp), formula: "yt-dlp"),
            Engine(name: "Documents & images", role: "PDF, text & photos", status: .builtIn),
        ]
    }
}

private struct EngineRow: View {
    var engine: Engine

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                // Name and role share a line when they fit (yt-dlp's role is long).
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) { name; role }
                    VStack(alignment: .leading, spacing: 2) { name; role }
                }
                detail
            }
            Spacer(minLength: 8)
            StatusChip(status: engine.status)
            Group {
                if case .found(let url) = engine.status {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([Self.revealTarget(url)])
                    } label: {
                        Text("Reveal").font(Citrus.display(12))
                    }
                    .buttonStyle(CitrusSoftButtonStyle(height: 26, fullWidth: false))
                    .help("Show \(engine.name) in Finder")
                    .accessibilityLabel("Reveal \(engine.name) in Finder")
                }
            }
            .frame(width: 76, alignment: .trailing)
        }
        .padding(.vertical, 10)
    }

    private var name: some View {
        Text(engine.name)
            .font(Citrus.text(14, .semibold))
            .foregroundStyle(Citrus.ink)
    }

    private var role: some View {
        Text(engine.role)
            .font(Citrus.text(12))
            .foregroundStyle(Citrus.inkSoft)
    }

    @ViewBuilder private var detail: some View {
        switch engine.status {
        case .found(let url):
            Text(url.path)
                .font(Citrus.mono(11))
                .foregroundStyle(Citrus.inkSoft)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(url.path)
        case .missing:
            EmptyView()   // the chip says it; the Homebrew hint below says how to fix it
        case .builtIn:
            Footnote("ImageIO & PDFKit, part of macOS")
        }
    }

    /// Reveal an app bundle rather than the binary buried inside it.
    private static func revealTarget(_ url: URL) -> URL {
        let parts = url.pathComponents
        guard let index = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return url }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(parts[...index])))
    }
}

/// Found / Not found / Built in.
private struct StatusChip: View {
    var status: Engine.Status

    var body: some View {
        Label(title, systemImage: symbol)
            .labelStyle(StatusLabelStyle(tint: tint))
            .font(Citrus.text(11, .bold))
            .foregroundStyle(Citrus.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(background))
    }

    private var title: String {
        switch status {
        case .found: return "Found"
        case .missing: return "Not found"
        case .builtIn: return "Built in"
        }
    }

    private var symbol: String {
        switch status {
        case .found: return "checkmark.circle.fill"
        case .missing: return "exclamationmark.circle.fill"
        case .builtIn: return "checkmark.seal.fill"
        }
    }

    private var tint: Color {
        switch status {
        case .found: return Citrus.success
        case .missing: return Citrus.danger
        case .builtIn: return Citrus.inkSoft
        }
    }

    private var background: Color {
        switch status {
        case .found: return Citrus.success.opacity(0.14)
        case .missing: return Citrus.danger.opacity(0.12)
        case .builtIn: return Citrus.soft
        }
    }
}

/// Icon in the status colour, title in ink so it stays readable on the tint.
private struct StatusLabelStyle: LabelStyle {
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

// MARK: - Building blocks

/// A grouped wash section. `rows` drops the vertical padding for 44pt
/// toggle rows separated by hairlines.
private struct SettingsSection<Content: View>: View {
    var rows = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: rows ? 0 : 10) { content }
            .padding(.horizontal, 16)
            .padding(.top, rows ? 0 : 14)
            .padding(.bottom, rows ? 0 : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Citrus.Radius.section, style: .continuous).fill(Citrus.wash))
    }
}

private struct SectionTitle: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(Citrus.display(16))
            .foregroundStyle(Citrus.ink)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct Footnote: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(Citrus.text(12))
            .foregroundStyle(Citrus.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Hairline: View {
    var body: some View {
        Rectangle().fill(Citrus.line).frame(height: 1).accessibilityHidden(true)
    }
}

/// Value readout capsule, e.g. the quality percentage.
private struct ValueChip: View {
    var text: String
    var body: some View {
        let colors = Citrus.chipColors(for: .image)
        Text(text)
            .font(Citrus.text(12, .bold))
            .monospacedDigit()
            .foregroundStyle(colors.foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(colors.background))
    }
}

/// Panes mostly fit the window; don't rubber-band them unless they overflow.
private struct BounceOnlyWhenScrollable: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 13.3, *) {
            content.scrollBounceBehavior(.basedOnSize)
        } else {
            content
        }
    }
}

private extension Toggle {
    /// A 44pt Citrus switch row.
    func citrusRow() -> some View {
        toggleStyle(CitrusToggleStyle()).frame(minHeight: 44)
    }
}

private extension View {
    /// Present a group of custom choice buttons to VoiceOver as a native radio group.
    func radioGroupAccessibility<Value: Hashable>(_ label: String, selection: Binding<Value>,
                                                  options: [(Value, String)]) -> some View {
        accessibilityRepresentation {
            Picker(label, selection: selection) {
                ForEach(options.indices, id: \.self) { index in Text(options[index].1).tag(options[index].0) }
            }
            .pickerStyle(.radioGroup)
        }
    }
}

// MARK: - Button styles

/// Capsule choice: accent when selected, soft (or outlined on a wash) when
/// not. Used by the tab bar and the "Longest side" chips. A press gives a
/// small squeeze, unless Reduce Motion is on.
private struct PillButtonStyle: ButtonStyle {
    var isSelected: Bool
    var height: CGFloat
    var font: Font
    var outlined = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, style: self)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let style: PillButtonStyle
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @StateObject private var hovering = ViewState(false)

        var body: some View {
            configuration.label
                .font(style.font)
                .foregroundStyle(style.isSelected ? Citrus.onAccent : Citrus.inkSoft)
                .padding(.horizontal, 16)
                .frame(height: style.height)
                .background(Capsule().fill(fill))
                .overlay {
                    if style.outlined && !style.isSelected {
                        Capsule().strokeBorder(hovering.value ? Citrus.dashedRing : Citrus.line, lineWidth: 2)
                    }
                }
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { hovering.value = $0 }
        }

        private var fill: Color {
            if style.isSelected { return configuration.isPressed ? Citrus.accentPressed : Citrus.accent }
            if style.outlined { return configuration.isPressed ? Citrus.soft : Citrus.surface }
            return hovering.value || configuration.isPressed ? Citrus.line : Citrus.soft
        }
    }
}

/// Radio option card: 2pt border, accent plus a check badge when selected.
private struct OptionCardStyle: ButtonStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration, isSelected: isSelected)
    }

    private struct CardBody: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        @StateObject private var hovering = ViewState(false)

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: Citrus.Radius.control, style: .continuous)
        }

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(shape.fill(configuration.isPressed ? Citrus.soft : Citrus.surface))
                .overlay(shape.strokeBorder(border, lineWidth: 2))
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(Citrus.text(9, .heavy))
                            .foregroundStyle(Citrus.onAccent)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Citrus.accent))
                            .padding(10)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(shape)
                .onHover { hovering.value = $0 }
        }

        private var border: Color {
            if isSelected { return Citrus.accent }
            return hovering.value ? Citrus.dashedRing : Citrus.line
        }
    }
}

/// Inline text link in ink-soft, underlined (accent text is too faint on the
/// dark wash for small type).
private struct InlineLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Citrus.text(12, .semibold))
            .foregroundStyle(Citrus.inkSoft)
            .underline()
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}
