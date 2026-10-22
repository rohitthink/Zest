import AppKit
import SwiftUI
import ZestKit

/// Citrus — Zest's visual language: warm cream, an orange-slice format wheel,
/// rounded display type. Every colour adapts to light and dark appearance;
/// views take tokens from here rather than hard-coding values.
enum Citrus {

    // MARK: - Palette

    static let canvas       = dynamic(0xFFE9D2, 0x1F140C)   // backdrop behind cards
    static let surface      = dynamic(0xFFFFFF, 0x2B1C11)   // cards, menu, windows
    static let wash         = dynamic(0xFFF8F0, 0x352316)   // grouped sections inside a surface
    static let soft         = dynamic(0xFFF1E3, 0x3D2817)   // secondary buttons, close button, idle pills
    static let line         = dynamic(0xFFE6CC, 0x4A3220)   // hairlines and unselected card borders
    static let ink          = dynamic(0x2A1609, 0xFFEBD6)   // primary text
    static let inkSoft      = dynamic(0x7A3E12, 0xE7B286)   // secondary text
    static let accent       = dynamic(0xC2410C, 0xCC4A12)   // primary actions, the picked slice
    static let accentPressed = dynamic(0xA3360A, 0xB03F0F)
    /// Progress fills (menu bar, wheel hub ring): accent in light; the brighter
    /// peel in dark, which keeps ≥ 3:1 against the dark tracks.
    static let progress     = dynamic(0xC2410C, 0xE8761A)
    static let onAccent     = Color.white
    static let peel         = dynamic(0xFF8A1F, 0xE8761A)   // wheel rim
    static let pith         = dynamic(0xFFF6EC, 0x3A2414)   // between wheel segments
    static let segment      = dynamic(0xFFC27A, 0x8A4A1C)   // idle wheel segment
    static let segmentInk   = dynamic(0x5A2600, 0xFFE2C4)   // label on an idle segment
    static let hubRing      = dynamic(0xFFE0BF, 0x5A3A22)
    static let ghostSegment = dynamic(0xFFEFDD, 0x3A2618)   // drop-zone slice illustration
    static let dashedRing   = dynamic(0xFFB061, 0xB86A2A)
    static let toggleOff    = dynamic(0xB58763, 0x6B4A33)
    static let success      = dynamic(0x2F7D32, 0x7BC47F)
    static let danger       = dynamic(0x8F1D1D, 0xFFB4B4)

    /// Warm drop shadow used under cards, the menu, and the wheel.
    static let shadow = dynamicColor(light: NSColor(srgbRed: 143 / 255, green: 63 / 255, blue: 0, alpha: 0.20),
                                     dark: NSColor(white: 0, alpha: 0.55))

    // MARK: - Type

    /// Display face (titles, wheel labels, buttons). SF Rounded stands in for
    /// the mock's Fredoka — native, no bundled font files.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Body face (labels, captions, list rows).
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Code face (URLs, paths, parameters).
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: - Shape

    enum Radius {
        static let card: CGFloat = 28      // drop zone + result cards
        static let menu: CGFloat = 18      // menu-bar panel
        static let section: CGFloat = 16   // grouped sections in Settings
        static let control: CGFloat = 12   // buttons, option cards, list rows
    }

    // MARK: - Format chips

    /// Background / foreground pair for a format chip, keyed by category.
    static func chipColors(for category: MediaCategory) -> (background: Color, foreground: Color) {
        switch category {
        case .image:
            return (dynamic(0xFFE0C2, 0x4A2A12), dynamic(0x8A3A00, 0xFFC48A))
        case .audio:
            return (dynamic(0xE3F2D9, 0x22361A), dynamic(0x2F5D1E, 0xB8E3A0))
        case .video:
            return (dynamic(0xE6E0FF, 0x2C2550), dynamic(0x3F2A8A, 0xC9BCFF))
        case .pdf, .document, .spreadsheet, .subtitle, .archive:
            return (dynamic(0xFFE1E1, 0x4A1F1F), dynamic(0x8F1D1D, 0xFFB4B4))
        }
    }

    /// SF Symbol for a category (hub icon, recents rows).
    static func symbol(for category: MediaCategory) -> String {
        switch category {
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "film"
        case .pdf: return "doc.richtext"
        case .spreadsheet: return "tablecells"
        case .document, .subtitle: return "doc.text"
        case .archive: return "archivebox"
        }
    }

    /// Human kind name, e.g. "HEIC image", "MP3 audio".
    static func kindName(for format: MediaFormat) -> String {
        let noun: String
        switch format.category {
        case .image: noun = "image"
        case .audio: noun = "audio"
        case .video: noun = "video"
        case .pdf: noun = "document"
        case .document: noun = "document"
        case .spreadsheet: noun = "spreadsheet"
        case .subtitle: noun = "subtitles"
        case .archive: noun = "archive"
        }
        return "\(format.id.uppercased()) \(noun)"
    }

    // MARK: - Menu-bar icon

    /// Template orange-slice glyph for the status item (adapts to the menu bar).
    static func statusImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            NSColor.black.setStroke()
            let rim = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            rim.lineWidth = 1.6
            rim.stroke()
            let spokes = NSBezierPath()
            spokes.lineWidth = 1.2
            for i in 0..<8 {
                let a = Double(i) * .pi / 4
                spokes.move(to: center)
                spokes.line(to: NSPoint(x: center.x + 5.6 * cos(a), y: center.y + 5.6 * sin(a)))
            }
            spokes.stroke()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 1.6, y: center.y - 1.6, width: 3.2, height: 3.2)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Zest"
        return image
    }

    // MARK: - Helpers

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        dynamicColor(light: NSColor(hex: light), dark: NSColor(hex: dark))
    }

    static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// Local view state. Use `@StateObject private var x = ViewState(0)` and
/// `x.value` instead of `@State`: in recent SDKs `@State` is a macro whose
/// plugin ships only with full Xcode, so it won't build with the Command Line
/// Tools this package targets.
final class ViewState<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

// MARK: - Panel + wheel geometry

/// Fixed layout of the floating drop panel. The panel is larger than what it
/// draws so shadows are not clipped; its transparent margin passes clicks
/// through to whatever is behind it. Coordinates are top-left origin.
enum PanelLayout {
    static let size = CGSize(width: 520, height: 560)
    static let wheelCenter = CGPoint(x: 260, y: 250)
    static let wheelDiameter: CGFloat = 440
    static let cardSize: CGFloat = 380
    /// Centre of the caption pill under the wheel.
    static let captionCenter = CGPoint(x: 260, y: 512)

    /// The wheel's frame inside the panel.
    static var wheelFrame: CGRect {
        CGRect(x: wheelCenter.x - wheelDiameter / 2, y: wheelCenter.y - wheelDiameter / 2,
               width: wheelDiameter, height: wheelDiameter)
    }
}

/// Geometry of the orange-slice wheel, shared by drawing (CitrusWheel) and
/// drag hit-testing (DropController) so they can never disagree. Proportions
/// follow the Citrus mock's 500-unit artboard. Coordinates are local to the
/// wheel's own square, top-left origin, y down; angles are clockwise from
/// 3 o'clock (SwiftUI convention). Slice 0 is centred at 12 o'clock.
struct WheelGeometry {
    var count: Int
    var diameter: CGFloat = PanelLayout.wheelDiameter

    private var unit: CGFloat { diameter / 500 }
    var center: CGPoint { CGPoint(x: diameter / 2, y: diameter / 2) }
    var peelRadius: CGFloat { 236 * unit }
    var pithRadius: CGFloat { 222 * unit }
    var segmentOuterRadius: CGFloat { 208 * unit }
    var segmentInnerRadius: CGFloat { 78 * unit }
    var hubRadius: CGFloat { 70 * unit }
    /// Radius at which a slice's label sits.
    var labelRadius: CGFloat { (segmentInnerRadius + segmentOuterRadius) / 2 + 2 * unit }
    /// Angular pith gap between neighbouring segments.
    var gap: Angle { count > 1 ? .degrees(5) : .zero }

    private var span: Double { 360 / Double(max(count, 1)) }

    /// Centre angle of slice `index`.
    func midAngle(_ index: Int) -> Angle { .degrees(-90 + Double(index) * span) }

    /// Start/end angles of slice `index`, pith gap already removed.
    func angles(_ index: Int) -> (start: Angle, end: Angle) {
        let mid = midAngle(index).degrees
        let half = span / 2 - gap.degrees / 2
        return (.degrees(mid - half), .degrees(mid + half))
    }

    /// Where slice `index`'s label is centred.
    func labelCenter(_ index: Int) -> CGPoint {
        let a = midAngle(index).radians
        return CGPoint(x: center.x + labelRadius * cos(a), y: center.y + labelRadius * sin(a))
    }

    /// The slice under `point`, or nil over the hub or well outside the wheel.
    /// Generous on purpose: anywhere between the hub and just past the peel
    /// counts, so a release near a slice still lands on it.
    func slice(at point: CGPoint) -> Int? {
        guard count > 0 else { return nil }
        let dx = point.x - center.x, dy = point.y - center.y
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > hubRadius, distance < peelRadius + 24 * unit else { return nil }
        var degrees = atan2(dy, dx) * 180 / .pi + 90 + span / 2   // 0 at slice 0's leading edge
        degrees = degrees.truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        return min(Int(degrees / span), count - 1)
    }
}

/// One segment of the orange slice: an annular sector between two angles.
/// With equal start/end span of 360° it draws a full ring.
struct SliceShape: Shape {
    var start: Angle
    var end: Angle
    var innerRadius: CGFloat
    var outerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        if end.degrees - start.degrees >= 359.99 {
            p.addEllipse(in: CGRect(x: c.x - outerRadius, y: c.y - outerRadius, width: outerRadius * 2, height: outerRadius * 2))
            p.addEllipse(in: CGRect(x: c.x - innerRadius, y: c.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2))
            return p   // drawn with eoFill to punch the hole
        }
        p.addArc(center: c, radius: outerRadius, startAngle: start, endAngle: end, clockwise: false)
        p.addArc(center: c, radius: innerRadius, startAngle: end, endAngle: start, clockwise: true)
        p.closeSubpath()
        return p
    }
}

// MARK: - Shared controls

/// Filled accent button ("Convert a file…", "Show in Finder").
struct CitrusPrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 44
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Citrus.display(16))
            .foregroundStyle(Citrus.onAccent)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(RoundedRectangle(cornerRadius: Citrus.Radius.control, style: .continuous)
                .fill(configuration.isPressed ? Citrus.accentPressed : Citrus.accent))
            .contentShape(RoundedRectangle(cornerRadius: Citrus.Radius.control, style: .continuous))
    }
}

/// Soft secondary button ("Squeeze another", settings tab pills when idle).
struct CitrusSoftButtonStyle: ButtonStyle {
    var height: CGFloat = 40
    var fullWidth = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Citrus.display(15))
            .foregroundStyle(Citrus.inkSoft)
            .padding(.horizontal, 16)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .background(RoundedRectangle(cornerRadius: Citrus.Radius.control, style: .continuous)
                .fill(Citrus.soft))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Citrus.Radius.control, style: .continuous))
    }
}

/// The Citrus switch: 40×24 capsule, accent when on. The whole row is the hit
/// target; VoiceOver still sees a toggle.
struct CitrusToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                configuration.label
                    .font(Citrus.text(14))
                    .foregroundStyle(Citrus.ink)
                Spacer(minLength: 8)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Citrus.accent : Citrus.toggleOff)
                    Circle().fill(.white)
                        .frame(width: 20, height: 20)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                        .padding(2)
                }
                .frame(width: 40, height: 24)
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// Round close button used on the drop card and around the wheel.
struct CitrusCloseButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Citrus.inkSoft)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Citrus.soft))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close drop zone")
        .help("Close")
    }
}

/// Small capsule naming a format, coloured by category ("JPG", "MP3").
struct FormatChip: View {
    var label: String
    var category: MediaCategory
    var body: some View {
        let colors = Citrus.chipColors(for: category)
        Text(label)
            .font(Citrus.text(11, .bold))
            .foregroundStyle(colors.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(colors.background))
    }
}

/// The Zest mark: an orange slice. Decorative; hidden from VoiceOver.
struct CitrusLogo: View {
    var size: CGFloat = 32
    var body: some View {
        Canvas { context, canvasSize in
            let s = canvasSize.width / 32
            let c = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            func disc(_ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: c.x - r * s, y: c.y - r * s, width: 2 * r * s, height: 2 * r * s))
            }
            context.fill(disc(15), with: .color(Citrus.peel))
            context.fill(disc(12.5), with: .color(Citrus.segment))
            var spokes = Path()
            for i in 0..<8 {
                let a = Double(i) * .pi / 4
                spokes.move(to: c)
                spokes.addLine(to: CGPoint(x: c.x + 12.5 * s * cos(a), y: c.y + 12.5 * s * sin(a)))
            }
            context.stroke(spokes, with: .color(Citrus.pith), lineWidth: 1.6 * s)
            context.fill(disc(3), with: .color(Citrus.pith))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
