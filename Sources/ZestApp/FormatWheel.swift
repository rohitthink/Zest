import SwiftUI
import ZestKit

/// The radial "fan" of target formats around the dropped file. Each petal is a
/// reachable output format; tapping one starts the conversion.
struct FormatWheel: View {
    let fileName: String
    let source: MediaFormat
    let targets: [MediaFormat]
    var onPick: (MediaFormat) -> Void

    private static let brand = Color(red: 1.0, green: 0x52 / 255.0, blue: 0.0) // 0xff5200

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = min(geo.size.width, geo.size.height) / 2 - 42
            ZStack {
                hub
                ForEach(Array(targets.enumerated()), id: \.element) { index, target in
                    let angle = Double(index) / Double(max(targets.count, 1)) * 2 * .pi - .pi / 2
                    petal(target)
                        .position(x: center.x + radius * cos(angle),
                                  y: center.y + radius * sin(angle))
                }
            }
        }
    }

    private var hub: some View {
        VStack(spacing: 3) {
            Image(systemName: icon(for: source.category)).font(.system(size: 24, weight: .medium))
            Text(fileName).font(.caption2).lineLimit(1).truncationMode(.middle).frame(maxWidth: 110)
            Text(source.id.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
        }
        .frame(width: 118, height: 84)
    }

    private func petal(_ target: MediaFormat) -> some View {
        Button { onPick(target) } label: {
            Text(target.id.uppercased())
                .font(.caption.weight(.bold))
                .frame(width: 58, height: 34)
                .background(Capsule().fill(Self.brand))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help("Convert to \(target.id.uppercased())")
    }

    private func icon(for category: MediaCategory) -> String {
        switch category {
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "film"
        case .pdf: return "doc.richtext"
        default: return "doc"
        }
    }
}
