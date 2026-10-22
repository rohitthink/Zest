import AppKit
import SwiftUI
import ZestKit

/// Root content of the floating drop panel. The panel is larger than anything
/// it draws (its margin only keeps shadows unclipped), so this view is exactly
/// `PanelLayout.size` on a clear background and places everything with
/// `PanelLayout`: a card for the drop zone, link, result and error states, or
/// the orange-slice wheel with a caption pill while files or a link are in hand.
struct DropWheelView: View {
    @ObservedObject var model: ConversionModel
    let actions: DropActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: ConversionModel, actions: DropActions) {
        self.model = model
        self.actions = actions
    }

    var body: some View {
        ZStack {
            if stage == .wheel {
                wheelStage.transition(stageTransition(from: 0.6))
            } else {
                cardStage.transition(stageTransition(from: 0.92))
            }
        }
        .frame(width: PanelLayout.size.width, height: PanelLayout.size.height)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.78),
                   value: stage)
    }

    // MARK: - Stages

    /// What the panel is showing; a change animates between layouts.
    private enum Stage: Hashable { case drop, rejected, catching, reading, wheel, done, failed }

    private var stage: Stage {
        switch model.phase {
        case .idle: return .drop
        case .rejected: return .rejected
        case .linkHover: return .catching
        case .fetching: return .reading
        case .previewing, .ready, .converting: return .wheel
        case .done: return .done
        case .failed: return .failed
        }
    }

    /// Card and wheel bloom from the wheel's centre; Reduce Motion just fades.
    private func stageTransition(from scale: CGFloat) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let anchor = UnitPoint(x: PanelLayout.wheelCenter.x / PanelLayout.size.width,
                               y: PanelLayout.wheelCenter.y / PanelLayout.size.height)
        return .scale(scale: scale, anchor: anchor).combined(with: .opacity)
    }

    private var cardStage: some View {
        CardChrome(onClose: actions.close) {
            cardContent
                .id(stage)
                .transition(.opacity)
        }
        .position(PanelLayout.wheelCenter)
    }

    @ViewBuilder private var cardContent: some View {
        switch model.phase {
        case .rejected(let message):
            DropPrompt(rejection: message, chooseFile: nil)
        case .linkHover(let link):
            LinkCatchPrompt(link: link)
        case .fetching(let link):
            LinkReadingPrompt(link: link, reduceMotion: reduceMotion, cancel: { model.cancel() })
        case .done(let summary):
            DoneContent(summary: summary, another: { model.reset() })
        case .failed(let message) where model.isLinkFailure:
            // A sign-in problem is fixed in Settings › Output, so offer it in place of Back.
            FailedContent(message: message, isLink: true,
                          primary: { model.retryLastLink() },
                          back: { model.reset() },
                          openSettings: model.failureNeedsSettings ? actions.openSettings : nil)
        case .failed(let message):
            FailedContent(message: message, isLink: false,
                          primary: actions.chooseFile, back: { model.reset() })
        default:
            DropPrompt(rejection: nil, chooseFile: actions.chooseFile)
        }
    }


    private var wheelStage: some View {
        ZStack {
            CitrusWheel(model: model)
                .frame(width: PanelLayout.wheelDiameter, height: PanelLayout.wheelDiameter)
                .position(PanelLayout.wheelCenter)
            CaptionPill(text: caption)
                .position(PanelLayout.captionCenter)
            // Floats over the desktop here, so it gets the pill's lift; the
            // compositing group makes the disc, not the glyph, cast it.
            CitrusCloseButton { actions.close() }
                .compositingGroup()
                .shadow(color: Citrus.shadow.opacity(0.6), radius: 10, y: 4)
                .position(Self.wheelCloseCenter)
        }
    }

    /// Just outside the peel at 45°, still well inside the panel.
    private static let wheelCloseCenter: CGPoint = {
        let radius = WheelGeometry(count: 1).peelRadius + 36
        let angle = -Double.pi / 4
        return CGPoint(x: PanelLayout.wheelCenter.x + radius * cos(angle),
                       y: PanelLayout.wheelCenter.y + radius * sin(angle))
    }()

    private var caption: String {
        switch model.phase {
        case .previewing:
            return "Release over a slice"
        case .ready(let batch):
            return "Click a slice · \(Self.keyRange(batch.targets.count)) · Esc to cancel"
        case let .converting(batch, target, completed, _):
            // Name the target: it may have come from the hub's More menu or a
            // URL command and not be on the wheel at all.
            let what: String
            if batch.isLink { what = "Downloading \(target.label)…" }
            else if target.isStrip { what = "Stripping metadata…" }
            else { what = "Squeezing to \(target.label)…" }
            let n = batch.files.count
            let count = n > 1 ? " \(min(completed + 1, n)) of \(n)" : ""
            return "\(what)\(count) · Esc to stop"
        default:
            return ""
        }
    }

    /// Number keys that pick a slice: "1–8", or "1–9, 0" when ten slices use 0.
    private static func keyRange(_ count: Int) -> String {
        switch count {
        case ...1: return "1"
        case 2...9: return "1–\(count)"
        default: return "1–9, 0"
        }
    }
}

// MARK: - Card

/// The rounded card behind every non-wheel state, with its close button.
/// The whole card is a solid hit area, so the panel drags by its background.
private struct CardChrome<Content: View>: View {
    let onClose: @MainActor () -> Void
    let content: Content

    init(onClose: @escaping @MainActor () -> Void, @ViewBuilder content: () -> Content) {
        self.onClose = onClose
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Citrus.Radius.card, style: .continuous)
        ZStack(alignment: .topTrailing) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            CitrusCloseButton { onClose() }
                .padding(18)
        }
        .frame(width: PanelLayout.cardSize, height: PanelLayout.cardSize)
        .background(shape.fill(Citrus.surface).shadow(color: Citrus.shadow, radius: 25, y: 20))
        .contentShape(shape)
        .accessibilityElement(children: .contain)
    }
}

/// The drop card's layout: the slice drawing with a title block centred on its
/// hub, as in the mock, quiet extras hanging below without pushing it up, and
/// for links a badge seated in the top segment.
private struct SlicePrompt<Art: View, Below: View>: View {
    let title: String
    let subtitle: String
    var subtitleHelp: String?
    var linkBadge: Bool
    let art: Art
    let below: Below

    init(title: String, subtitle: String, subtitleHelp: String? = nil, linkBadge: Bool = false,
         @ViewBuilder art: () -> Art, @ViewBuilder below: () -> Below) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleHelp = subtitleHelp
        self.linkBadge = linkBadge
        self.art = art()
        self.below = below()
    }

    var body: some View {
        ZStack(alignment: Alignment(horizontal: .center, vertical: .promptTitle)) {
            // The badge sits in the slice's top segment, like a wheel label.
            art.overlay {
                if linkBadge { LinkBadge().offset(y: -SliceIllustration.topLabelRadius) }
            }
            VStack(spacing: 8) {
                VStack(spacing: 6) {
                    // Long titles shrink a touch rather than crowd the rim.
                    Text(title)
                        .font(Citrus.display(26))
                        .foregroundStyle(Citrus.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: 232)
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(Citrus.text(13, .semibold))
                        .foregroundStyle(Citrus.inkSoft)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .frame(maxWidth: 260)
                        .optionalHelp(subtitleHelp)
                }
                .alignmentGuide(.promptTitle) { $0[VerticalAlignment.center] }
                below
            }
        }
    }
}

/// Idle drop zone, or the same card refusing an unsupported drag.
private struct DropPrompt: View {
    /// Why the hovering files can't be taken; nil while idle.
    let rejection: String?
    let chooseFile: (@MainActor () -> Void)?

    var body: some View {
        SlicePrompt(title: rejection == nil ? "Drop to squeeze" : "Can't squeeze that",
                    subtitle: rejection ?? "Images, audio, video & docs") {
            SliceIllustration(look: rejection == nil ? .idle : .muted)
        } below: {
            if let chooseFile {
                VStack(spacing: 2) {
                    Button("or choose files…") { chooseFile() }
                        .buttonStyle(LinkButtonStyle())
                        .keyboardShortcut("o", modifiers: .command)
                        .help("Pick files to squeeze (⌘O)")
                    // ⌘V itself is handled by DropController; this just says so.
                    Text("or paste a link · ⌘V")
                        .font(Citrus.text(12, .medium))
                        .foregroundStyle(Citrus.inkSoft)
                        .help("Paste a YouTube, Instagram, Facebook or Pinterest link to download it")
                        .accessibilityLabel("Or paste a link with Command-V to download it")
                }
            }
        }
    }
}

/// A web link is being dragged over the panel: the slice lights up, ready to
/// catch it. No buttons — the pointer is mid-drag.
private struct LinkCatchPrompt: View {
    let link: URL

    var body: some View {
        SlicePrompt(title: "Release to download", subtitle: LinkSite.line(for: link),
                    subtitleHelp: link.absoluteString, linkBadge: true) {
            SliceIllustration(look: .lit)
        } below: {
            EmptyView()
        }
    }
}

/// yt-dlp is reading the link (a few seconds): the ghost segments light in
/// turn, clockwise. Esc, or the hint, cancels.
private struct LinkReadingPrompt: View {
    let link: URL
    let reduceMotion: Bool
    let cancel: @MainActor () -> Void

    var body: some View {
        SlicePrompt(title: "Reading link…", subtitle: LinkSite.line(for: link),
                    subtitleHelp: link.absoluteString, linkBadge: true) {
            ReadingSlice(reduceMotion: reduceMotion)
        } below: {
            // The visible words are its name, so Voice Control's "Click Esc to cancel" works.
            Button("Esc to cancel") { cancel() }
                .buttonStyle(LinkButtonStyle())
                .help("Stop reading this link (Esc)")
        }
    }
}

/// "YouTube · youtube.com": the site a link belongs to, and its host.
private enum LinkSite {
    static func line(for link: URL) -> String {
        let platform = LinkDownloader.Platform.of(link).displayName
        var host = link.host ?? ""
        if host.lowercased().hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? platform : "\(platform) · \(host)"
    }
}

/// A chain-link glyph on an accent disc, marking the link states. Decorative.
private struct LinkBadge: View {
    var body: some View {
        Image(systemName: "link")
            .font(Citrus.text(16, .bold))
            .foregroundStyle(Citrus.onAccent)
            .frame(width: 38, height: 38)
            .background(Circle().fill(Citrus.accent))
            .padding(3)
            .background(Circle().fill(Citrus.surface))
            .accessibilityHidden(true)
    }
}

/// The drop zone's orange-slice drawing: a dashed rim and eight ghost
/// segments, on the mock's 500-unit artboard scaled to 300pt.
private struct SliceIllustration: View {
    enum Look {
        /// Waiting for a drop.
        case idle
        /// Refusing a drag.
        case muted
        /// A link hovering, ready to catch: a closed peel and warm segments.
        case lit
    }

    var look: Look = .idle
    /// Extra warmth per segment, 0…1, laid over the ghost fill (the reading
    /// chase). Indexed clockwise from 12 o'clock.
    var glow: [Double] = []

    private let geometry = WheelGeometry(count: 8, diameter: 300)
    /// Distance from the centre to the middle of a segment (where a badge sits).
    static let topLabelRadius = WheelGeometry(count: 8, diameter: 300).labelRadius
    /// Most a segment warms. Capped so `inkSoft` text crossing a lit segment
    /// keeps 4.5:1 in light and dark.
    static let maxGlow = 0.55

    var body: some View {
        let unit = geometry.diameter / 500
        let ringRadius = 232 * unit
        // Dash 20 : gap 14, nudged so the pattern closes without a seam.
        let circumference = 2 * CGFloat.pi * ringRadius
        let period = circumference / (circumference / (34 * unit)).rounded()
        ZStack {
            if look == .lit {
                Circle()
                    .inset(by: geometry.diameter / 2 - ringRadius)
                    .stroke(Citrus.peel, lineWidth: 10 * unit)
            } else {
                Circle()
                    .inset(by: geometry.diameter / 2 - ringRadius)
                    .stroke(look == .muted ? Citrus.toggleOff.opacity(0.5) : Citrus.dashedRing,
                            style: StrokeStyle(lineWidth: 10 * unit, lineCap: .butt,
                                               dash: [period * 20 / 34, period * 14 / 34]))
            }
            ForEach(0..<geometry.count, id: \.self) { index in
                let angles = geometry.angles(index)
                let shape = SliceShape(start: angles.start, end: angles.end,
                                       innerRadius: geometry.segmentInnerRadius,
                                       outerRadius: geometry.segmentOuterRadius)
                ZStack {
                    shape.fill(Citrus.ghostSegment)
                    shape.fill(Citrus.segment).opacity(warmth(index))
                }
                .opacity(look == .muted ? 0.55 : 1)
            }
        }
        .frame(width: geometry.diameter, height: geometry.diameter)
        .accessibilityHidden(true)
    }

    private func warmth(_ index: Int) -> Double {
        if look == .lit { return Self.maxGlow }
        guard glow.indices.contains(index) else { return 0 }
        return min(max(glow[index], 0), 1) * Self.maxGlow
    }
}

/// The slice drawing as a gentle "working" indicator: one segment at a time
/// warms up and fades, chasing clockwise. Under Reduce Motion it holds still,
/// every segment evenly warm.
private struct ReadingSlice: View {
    let reduceMotion: Bool

    /// Seconds for the glow to go once round.
    private static let lap = 1.8

    var body: some View {
        if reduceMotion {
            SliceIllustration(glow: Array(repeating: 0.5, count: 8))
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                SliceIllustration(glow: Self.glow(at: context.date))
            }
        }
    }

    /// Each segment brightens as the head reaches it, then fades over the
    /// next few segments.
    static func glow(at date: Date) -> [Double] {
        let count = 8.0
        let head = (date.timeIntervalSinceReferenceDate / lap).truncatingRemainder(dividingBy: 1) * count
        return (0..<8).map { index in
            var behind = head - Double(index)   // how far the head has moved past this segment
            if behind < 0 { behind += count }
            let rise = 0.4, fade = 3.0
            if behind < rise { return behind / rise }
            return max(0, 1 - (behind - rise) / fade)
        }
    }
}

/// Result card: what was made (or downloaded), its size, and what to do next.
private struct DoneContent: View {
    let summary: ConversionModel.Summary
    let another: @MainActor () -> Void

    /// One file in, one out. A batch that kept a single output still reads as a batch.
    private var isSingle: Bool {
        summary.isDownload || (summary.outputs.count == 1 && summary.failures.isEmpty && summary.unchanged.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            SuccessMark()
                .padding(.bottom, 14)
            Text(summary.isDownload ? "Downloaded!" : "Squeezed!")
                .font(Citrus.display(26))
                .foregroundStyle(Citrus.ink)
                .accessibilityAddTraits(.isHeader)
            details
                .padding(.top, 8)
            HStack(spacing: 10) {
                Button(summary.isDownload ? "Download another" : "Squeeze another") { another() }
                    .buttonStyle(CitrusSoftButtonStyle(height: 44))
                    .lineLimit(1)
                    // The longer label takes the width it needs; Show in Finder still fits.
                    .fixedSize(horizontal: summary.isDownload, vertical: false)
                    .help(summary.isDownload ? "Back to the drop zone to paste or drop another link"
                                             : "Back to the drop zone")
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(summary.outputs) }
                    .buttonStyle(CitrusPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .help(isSingle ? (summary.isDownload ? "Reveal the download in Finder" : "Reveal the squeezed file in Finder")
                                   : "Reveal the squeezed files in Finder")
            }
            .padding(.top, 24)
        }
        .padding(.horizontal, 32)
    }

    private var details: some View {
        VStack(spacing: 8) {
            if isSingle, let output = summary.outputs.first {
                Text(output.lastPathComponent)
                    .font(Citrus.text(13, .semibold))
                    .foregroundStyle(Citrus.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(summary.isDownload ? (output.path as NSString).abbreviatingWithTildeInPath
                                             : output.lastPathComponent)
                    .accessibilityLabel("Saved as \(output.lastPathComponent)")
                if summary.isDownload {
                    downloadLine
                } else {
                    sizeLine(Self.bytes(summary.outputBytes))
                }
            } else {
                Text(summary.outputs.count == 1 ? "1 file squeezed" : "\(summary.outputs.count) files squeezed")
                    .font(Citrus.text(13, .semibold))
                    .foregroundStyle(Citrus.ink)
                sizeLine("\(Self.bytes(summary.outputBytes)) total")
                if !summary.unchanged.isEmpty { unchangedNote }
                if !summary.failures.isEmpty { failureNote }
            }
        }
    }

    /// "734 MB  [MP4 4K]": a download has nothing to be smaller than, so the
    /// chip says what was saved instead.
    private var downloadLine: some View {
        let size = Self.bytes(summary.outputBytes)
        return HStack(spacing: 8) {
            Text(size)
                .font(Citrus.text(13, .medium))
                .foregroundStyle(Citrus.inkSoft)
            FormatChip(label: summary.target.label, category: summary.target.format.category)
        }
        .help(summary.target.helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(size), \(summary.target.label)")
    }

    /// "1 file was already JPG" — left alone, not a failure.
    private var unchangedNote: some View {
        let count = summary.unchanged.count
        let format = summary.target.label
        let note = count == 1 ? "1 file was already \(format)" : "\(count) files were already \(format)"
        return Label(note, systemImage: "checkmark")
            .labelStyle(CompactLabelStyle(iconColor: Citrus.success))
            .font(Citrus.text(12, .semibold))
            .foregroundStyle(Citrus.inkSoft)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Citrus.soft))
            .help(summary.unchanged.map(\.lastPathComponent).joined(separator: "\n"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(note)
    }

    /// "1.3 MB  ↓ 62% smaller"; just the size when the output grew.
    private func sizeLine(_ size: String) -> some View {
        let percent = summary.savedFraction.map { Int(($0 * 100).rounded()) } ?? 0
        let saving = percent >= 1 ? "\(percent)% smaller" : nil
        return HStack(spacing: 8) {
            Text(size)
                .font(Citrus.text(13, .medium))
                .foregroundStyle(Citrus.inkSoft)
            if let saving {
                Label(saving, systemImage: "arrow.down")
                    .labelStyle(CompactLabelStyle())
                    .font(Citrus.text(12, .bold))
                    .foregroundStyle(Citrus.surface)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Citrus.success))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([size, saving].compactMap { $0 }.joined(separator: ", "))
    }

    private var failureNote: some View {
        let count = summary.failures.count
        let note = count == 1 ? "1 file didn't squeeze" : "\(count) files didn't squeeze"
        return Label(note, systemImage: "exclamationmark.triangle.fill")
            .labelStyle(CompactLabelStyle(iconColor: Citrus.accent))
            .font(Citrus.text(12, .semibold))
            .foregroundStyle(Citrus.inkSoft)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Citrus.soft))
            .help(summary.failures.joined(separator: "\n"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(note)
            .accessibilityValue(summary.failures.joined(separator: "; "))
    }

    private static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

/// Error card: what went wrong and a way forward — another file, or for a
/// link, another go (say, after turning on browser sign-in or installing yt-dlp).
private struct FailedContent: View {
    let message: String
    let isLink: Bool
    let primary: @MainActor () -> Void
    let back: @MainActor () -> Void
    /// When set, the secondary button opens Settings instead of going back.
    var openSettings: (@MainActor () -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Citrus.text(30, .semibold))
                .foregroundStyle(Citrus.accent)
                .frame(width: 72, height: 72)
                .background(Circle().fill(Citrus.soft))
                .accessibilityHidden(true)
                .padding(.bottom, 14)
            Text(isLink ? "That didn't download" : "That didn't squeeze")
                .font(Citrus.display(24))
                .foregroundStyle(Citrus.ink)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(Citrus.text(13))
                .foregroundStyle(Citrus.inkSoft)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)   // e.g. copy "brew install yt-dlp"
                .help(message)   // the full text when a long tool error is cut off
                .padding(.top, 8)
            HStack(spacing: 10) {
                if let openSettings {
                    Button("Settings") { openSettings() }
                        .buttonStyle(CitrusSoftButtonStyle(height: 44))
                        .frame(width: 104)
                        .help("Open Settings › Output to turn on browser sign-in")
                } else {
                    Button("Back") { back() }
                        .buttonStyle(CitrusSoftButtonStyle(height: 44))
                        .frame(width: 104)
                        .help("Back to the drop zone")
                }
                Button(isLink ? "Try again" : "Choose another file") { primary() }
                    .buttonStyle(CitrusPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .help(isLink ? "Read the same link again" : "Pick a different file to squeeze")
            }
            .padding(.top, 24)
        }
        .padding(.horizontal, 32)
    }
}

/// The Zest slice with a success check tucked on its rim. Decorative.
private struct SuccessMark: View {
    var body: some View {
        CitrusLogo(size: 72)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "checkmark")
                    .font(Citrus.text(12, .heavy))
                    .foregroundStyle(Citrus.surface)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Citrus.success))
                    .padding(3)
                    .background(Circle().fill(Citrus.surface))
                    .offset(x: 6, y: 4)
            }
            .accessibilityHidden(true)
    }
}

private extension VerticalAlignment {
    /// Centre of the drop prompt's title block, lined up with the slice's hub.
    enum PromptTitle: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }
    static var promptTitle: VerticalAlignment { VerticalAlignment(PromptTitle.self) }
}

// MARK: - Wheel caption

/// The hint under the wheel: a small surface-coloured pill.
private struct CaptionPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Citrus.text(13, .semibold))
            .foregroundStyle(Citrus.inkSoft)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(Capsule().fill(Citrus.surface)
                .shadow(color: Citrus.shadow.opacity(0.6), radius: 10, y: 4))
            .fixedSize()
    }
}

// MARK: - Small styles

private extension View {
    /// A tooltip only when there is something to say.
    @ViewBuilder func optionalHelp(_ text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}

/// Quiet underlined text button. On hover and press the text darkens and a
/// capsule appears in `line`, which still shows over the ghost segments
/// (`soft` all but matches them).
private struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LinkLabel(configuration: configuration)
    }

    private struct LinkLabel: View {
        let configuration: ButtonStyleConfiguration
        @StateObject private var hovering = ViewState(false)

        init(configuration: ButtonStyleConfiguration) {
            self.configuration = configuration
        }

        var body: some View {
            let active = configuration.isPressed || hovering.value
            configuration.label
                .font(Citrus.text(12, .semibold))
                .underline(color: active ? Citrus.inkSoft : Citrus.dashedRing)
                .foregroundStyle(active ? Citrus.ink : Citrus.inkSoft)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Citrus.line)
                    .opacity(configuration.isPressed ? 1 : hovering.value ? 0.7 : 0))
                .contentShape(Capsule())
                .onHover { hovering.value = $0 }
        }
    }
}

/// Icon and title close together, the icon optionally tinted.
private struct CompactLabelStyle: LabelStyle {
    var iconColor: Color?

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            if let iconColor {
                configuration.icon.foregroundStyle(iconColor).imageScale(.small)
            } else {
                configuration.icon.imageScale(.small)
            }
            configuration.title
        }
    }
}
