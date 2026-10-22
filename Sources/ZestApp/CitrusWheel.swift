import SwiftUI
import ZestKit

/// The orange-slice format wheel, Zest's hero. One segment per target format,
/// laid out with the same `WheelGeometry` that `DropTargetView` hit-tests drags
/// with, so the slice that lights up is the slice a release lands on. The hub
/// names what's in hand and becomes a progress ring while squeezing.
///
/// Exactly `PanelLayout.wheelDiameter` square with no outer padding; the drop
/// shadow spills past the frame without affecting layout. Appearing and
/// leaving are the parent's transitions to run, so a freshly rendered wheel
/// (and every snapshot of it) is always fully drawn.
struct CitrusWheel: View {
    @ObservedObject private var model: ConversionModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The last phase that had the wheel up, so a wheel being transitioned out
    /// after a squeeze keeps its slices instead of collapsing to a bare disc.
    @StateObject private var lastWheelPhase = ViewState<ConversionModel.Phase?>(nil)

    init(model: ConversionModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        let phase = model.wheelBatch != nil ? model.phase : lastWheelPhase.value
        let batch = phase.flatMap(Self.batch(in:))
        let targets = batch?.targets ?? []
        let geometry = WheelGeometry(count: targets.count)
        let unit = geometry.diameter / 500
        let picked = phase.flatMap(Self.pickedTarget(in:))

        ZStack {
            disc(radius: geometry.peelRadius, fill: Citrus.peel)
                .shadow(color: Citrus.shadow, radius: 14 * unit, y: 18 * unit)
            disc(radius: geometry.pithRadius, fill: Citrus.pith)

            ForEach(Array(targets.enumerated()), id: \.element.id) { index, target in
                let isLit = picked.map { $0.id == target.id } ?? (model.hoveredSlice == index)
                Button { model.pick(target) } label: {
                    SliceLabel(title: target.label, note: batch?.link.flatMap { Self.downloadNote(for: target, info: $0) })
                }
                    .buttonStyle(SliceButtonStyle(geometry: geometry, index: index,
                                                  help: Self.help(for: target, key: Self.shortcutKey(for: index)),
                                                  isLit: isLit, isDimmed: picked != nil && !isLit,
                                                  reduceMotion: reduceMotion))
                    .frame(width: geometry.diameter, height: geometry.diameter)
                    .zIndex(isLit ? 1 : 0)
                    .disabled(picked != nil)
                    // A download's explanation never names the format, so its
                    // name is the slice's own words ("MP4 4K") and the
                    // explanation is the hint; a file target's "Convert to JPG" says both.
                    .accessibilityLabel(Self.accessibleName(for: target, note: batch?.link.flatMap { Self.downloadNote(for: target, info: $0) }))
                    .accessibilityHint(target.download == nil ? "" : target.helpText)
                    // Selected means picked (converting), not merely hovered.
                    .accessibilityAddTraits(picked?.id == target.id ? .isSelected : [])
            }

            if let phase, let batch {
                WheelHub(model: model, phase: phase, batch: batch, radius: geometry.hubRadius,
                         reduceMotion: reduceMotion)
                    .zIndex(2)
            }
        }
        .frame(width: geometry.diameter, height: geometry.diameter)
        // One tracker for the whole wheel rather than `.onHover` per slice:
        // on these full-frame buttons a per-slice hover region makes the top
        // slice swallow every click, whatever its content shape says.
        .onContinuousHover { hover in
            switch hover {
            case .active(let point): model.hover(Self.slice(at: point, in: geometry))
            case .ended: model.hover(nil)
            }
        }
        .onReceive(model.$phase) { phase in
            if Self.batch(in: phase) != nil { lastWheelPhase.value = phase }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Format wheel")
    }

    private func disc(radius: CGFloat, fill: Color) -> some View {
        Circle()
            .fill(fill)
            .frame(width: radius * 2, height: radius * 2)
            .accessibilityHidden(true)
    }

    /// The slice under the pointer: the drag hit-test, trimmed to the peel so
    /// hovering and clicking cover exactly the same wedge.
    private static func slice(at point: CGPoint, in geometry: WheelGeometry) -> Int? {
        let dx = point.x - geometry.center.x, dy = point.y - geometry.center.y
        guard (dx * dx + dy * dy).squareRoot() <= geometry.peelRadius else { return nil }
        return geometry.slice(at: point)
    }

    /// The spoken name starts with the visible label (WCAG 2.5.3, Voice Control's
    /// "Click Strip"): "Convert to JPG", "Strip: remove…", "MP4 4K".
    private static func accessibleName(for target: ConversionModel.WheelTarget, note: String?) -> String {
        // "MP4 1080p, Plays everywhere" vs "MP4 4K, Best · AV1": the note tells same-sized choices apart.
        if target.download != nil { return note.map { "\(target.label), \($0)" } ?? target.label }
        if target.isStrip { return "Strip: remove location & camera info, keep the format" }
        return target.helpText
    }

    /// The digit that picks slice `index` (DropController's 1–9, then 0).
    private static func shortcutKey(for index: Int) -> String {
        index < 9 ? "\(index + 1)" : "0"
    }

    /// "Convert to JPG — press 1"; a download's full-sentence explanation
    /// gets its own "Press 1." rather than a trailing dash.
    private static func help(for target: ConversionModel.WheelTarget, key: String) -> String {
        let text = target.helpText
        return text.hasSuffix(".") ? "\(text) Press \(key)." : "\(text) — press \(key)"
    }

    /// A download slice's second line, so the honest difference between the
    /// choices shows without hovering: which video plays everywhere, and
    /// that only M4A keeps the site's own audio (MP3 and WAV are conversions
    /// of that compressed stream). The full story is in the tooltip.
    private static func downloadNote(for target: ConversionModel.WheelTarget, info: LinkDownloader.Info) -> String? {
        guard let option = target.download else { return nil }
        switch option {
        case .best:
            switch info.bestVideoCodec {
            case "av01"?: return "Best · AV1"
            case "vp9"?: return "Best · VP9"
            case "hevc"?: return "Best · HEVC"
            case "avc1"?: return "Plays everywhere"
            default: return "Best quality"
            }
        case .compatible: return "Plays everywhere"
        case .m4a:
            // M4A copies the site's AAC stream untouched when there is one
            // (even if an Opus stream rates higher); otherwise it converts.
            return info.hasAACStream ? "Original audio" : "AAC audio"
        case .mp3: return "Converted copy"
        case .wav: return "For editing"
        case .image: return "Full size"
        }
    }

    private static func batch(in phase: ConversionModel.Phase) -> ConversionModel.Batch? {
        switch phase {
        case let .previewing(b), let .ready(b), let .converting(b, _, _, _): return b
        default: return nil
        }
    }

    private static func pickedTarget(in phase: ConversionModel.Phase) -> ConversionModel.WheelTarget? {
        if case let .converting(_, target, _, _) = phase { return target }
        return nil
    }
}

// MARK: - Slice

/// One segment of the wheel as a button. The visible segment pops outward
/// when lit, but the hit area stays put: the whole wedge from hub to peel,
/// the same region `WheelGeometry.slice(at:)` resolves drags to.
///
/// The tooltip hangs on the label, not the button: AppKit registers a
/// tooltip by frame, and every slice button's frame is the whole wheel.
/// Keyboard focus (Full Keyboard Access) lights the slice too, so it's clear
/// which wedge has focus whatever shape the system ring takes.
private struct SliceButtonStyle: ButtonStyle {
    let geometry: WheelGeometry
    let index: Int
    let help: String
    let isLit: Bool
    let isDimmed: Bool
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        FocusReader { isFocused in
            face(configuration, isFocused: isFocused)
        }
    }

    @ViewBuilder
    private func face(_ configuration: Configuration, isFocused: Bool) -> some View {
        let lit = isLit || configuration.isPressed || (isFocused && !isDimmed)
        let fill = configuration.isPressed ? Citrus.accentPressed : (lit ? Citrus.accent : Citrus.segment)
        let unit = geometry.diameter / 500
        let isRing = geometry.count == 1
        let angles = geometry.angles(index)

        ZStack(alignment: .topLeading) {
            SliceShape(start: angles.start, end: angles.end,
                       innerRadius: geometry.segmentInnerRadius, outerRadius: geometry.segmentOuterRadius)
                .fill(fill, style: FillStyle(eoFill: isRing))
                // A light rim on the lit slice: in dark mode accent vs. segment
                // alone is too close (≈1.5:1) to read as "this one".
                .overlay(SliceShape(start: angles.start, end: angles.end,
                                    innerRadius: geometry.segmentInnerRadius, outerRadius: geometry.segmentOuterRadius)
                    .stroke(lit ? Citrus.onAccent.opacity(0.85) : .clear, lineWidth: 2 * unit))
                .shadow(color: lit ? Citrus.shadow : .clear, radius: 6 * unit, y: 3 * unit)
                .animation(.easeOut(duration: 0.12), value: lit)
            configuration.label
                .font(Citrus.display(15))
                .foregroundStyle(lit ? Citrus.onAccent : Citrus.segmentInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: labelWidth(unit: unit), height: 44 * unit)
                .help(help)
                .position(geometry.labelCenter(index))
        }
        .offset(lit ? popOffset : .zero)   // the pop is a cue, kept under Reduce Motion — only its animation goes
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.55), value: lit)
        .opacity(isDimmed ? 0.4 : 1)
        .animation(.easeOut(duration: 0.2), value: isDimmed)
        .contentShape(hitArea, eoFill: isRing)
    }

    /// Widest a label can be and stay inside its segment: the chord at the
    /// label radius, capped by the segment's depth.
    private func labelWidth(unit: CGFloat) -> CGFloat {
        let angles = geometry.angles(index)
        let halfSweep = min((angles.end.radians - angles.start.radians) / 2, .pi / 2)
        let chord = 2 * geometry.labelRadius * sin(halfSweep)
        let depth = geometry.segmentOuterRadius - geometry.segmentInnerRadius
        return min(chord, depth) - 10 * unit
    }

    /// A short hop along the slice's mid-angle, out into the pith and short of
    /// the peel. A lone full ring has nowhere to pop.
    private var popOffset: CGSize {
        guard geometry.count > 1 else { return .zero }
        let distance = (geometry.pithRadius - geometry.segmentOuterRadius) * 0.6
        let angle = geometry.midAngle(index).radians
        return CGSize(width: cos(angle) * distance, height: sin(angle) * distance)
    }

    private var hitArea: SliceShape {
        let mid = geometry.midAngle(index).degrees
        let half = 180 / Double(max(geometry.count, 1))
        return SliceShape(start: .degrees(mid - half), end: .degrees(mid + half),
                          innerRadius: geometry.hubRadius, outerRadius: geometry.peelRadius)
    }
}

/// A slice's text: the format, and for a download a smaller second line
/// saying what sets it apart. Fonts and colour come from the slice style.
private struct SliceLabel: View {
    let title: String
    let note: String?

    var body: some View {
        if let note {
            VStack(spacing: 1) {
                Text(title)
                Text(note).font(Citrus.text(10.5, .semibold))
            }
        } else {
            Text(title)
        }
    }
}

/// Reads `isFocused` from inside the button, where it reports that button's
/// own keyboard focus, and hands it to the slice's drawing.
private struct FocusReader<Content: View>: View {
    @Environment(\.isFocused) private var isFocused
    @ViewBuilder let content: (Bool) -> Content

    var body: some View { content(isFocused) }
}

// MARK: - Hub

/// The wheel's centre: the file(s) in hand, or how far the squeeze has got.
private struct WheelHub: View {
    let model: ConversionModel
    let phase: ConversionModel.Phase
    let batch: ConversionModel.Batch
    let radius: CGFloat
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            Circle().fill(Citrus.surface)
            Circle().stroke(Citrus.hubRing, lineWidth: 2)
            if case let .converting(_, target, completed, fraction) = phase {
                progress(target: target, completed: completed, fraction: fraction)
            } else {
                summary
            }
        }
        .frame(width: radius * 2, height: radius * 2)
    }

    /// Icon, name, kind; plus the overflow menu and skipped count when needed.
    /// A link's title gets two lines (video titles run long and read best
    /// from the start); a file name keeps one, cut in the middle so the
    /// extension shows.
    private var summary: some View {
        VStack(spacing: 3) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(Citrus.text(17))
                    .foregroundStyle(Citrus.ink)
                    // The mock's 26pt icon box; a little shorter for a link's two-line title.
                    .frame(width: 26, height: batch.isLink ? 22 : 26)
                    .accessibilityHidden(true)
                Text(batch.title)
                    .font(Citrus.text(12, .bold))
                    .foregroundStyle(Citrus.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(batch.isLink ? 2 : 1)
                    .truncationMode(batch.isLink ? .tail : .middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(batch.title)
                Text(batch.kind)
                    .font(Citrus.text(11))
                    .foregroundStyle(Citrus.inkSoft)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)

            if !batch.overflow.isEmpty {
                overflowMenu.padding(.top, 2)
            }
            if batch.skipped > 0 {
                Text("\(batch.skipped) skipped")
                    .font(Citrus.text(10, .semibold))
                    .foregroundStyle(Citrus.inkSoft)
                    .help("Folders and files Zest can't read were left out")
            }
        }
        .frame(maxWidth: radius * 2 - (batch.isLink ? 20 : 14))
    }

    /// What's in hand: a category glyph, or for a link what it will give —
    /// a video, a sound, a picture.
    private var symbol: String {
        guard batch.isLink else { return Citrus.symbol(for: batch.category ?? .document) }
        switch batch.category {
        case .audio?: return "music.note"
        case .image?: return "photo"
        default: return "play.rectangle"
        }
    }

    /// Targets that didn't fit on the wheel, as a small soft pill. The button
    /// menu style (with a plain button style) keeps the Citrus font and colours,
    /// which the borderless style would replace with system ones.
    private var overflowMenu: some View {
        Menu {
            ForEach(batch.overflow) { target in
                Button(target.helpText) { model.pick(target) }
            }
        } label: {
            HStack(spacing: 3) {
                Text("More")
                Image(systemName: "chevron.down")
                    .font(Citrus.text(8, .heavy))
            }
            .font(Citrus.text(11, .bold))
            .foregroundStyle(Citrus.inkSoft)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(Citrus.soft))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More formats")
        .help("More formats: \(batch.overflow.map(\.label).joined(separator: ", "))")
    }

    /// Accent ring trimmed to the overall fraction, with the percentage inside.
    private func progress(target: ConversionModel.WheelTarget, completed: Int, fraction: Double) -> some View {
        let percent = Int((fraction * 100).rounded())
        let current = min(completed + 1, batch.files.count)
        let ringWidth: CGFloat = 5
        // Outer edge flush with the hub's 2pt rim, so the track replaces it.
        let inset = ringWidth / 2 - 1
        return ZStack {
            Circle()
                .inset(by: inset)
                .stroke(Citrus.hubRing, lineWidth: ringWidth)
            Circle()
                .inset(by: inset)
                .trim(from: 0, to: fraction)
                .stroke(Citrus.progress, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: fraction)
            VStack(spacing: 1) {
                Text("\(percent)%")
                    .font(Citrus.display(26))
                    .monospacedDigit()
                    .foregroundStyle(Citrus.ink)
                Text(batch.isLink ? "Downloading…" : batch.isSingle ? "Squeezing…" : "\(current) of \(batch.files.count)")
                    .font(Citrus.text(11, .semibold))
                    .foregroundStyle(Citrus.inkSoft)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityLabel(batch.isLink ? "Downloading \(target.label)" : "Squeezing to \(target.label)")
        .accessibilityValue(batch.isSingle ? "\(percent) percent"
                                           : "\(percent) percent, file \(current) of \(batch.files.count)")
    }
}
