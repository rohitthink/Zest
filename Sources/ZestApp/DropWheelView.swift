import SwiftUI
import ZestKit
import UniformTypeIdentifiers

/// The floating drop surface. Shows the drop prompt, then the radial wheel once
/// a file lands, then conversion progress and the result.
struct DropWheelView: View {
    @ObservedObject var model: ConversionModel
    var onClose: () -> Void

    private static let brand = Color(red: 1.0, green: 0x52 / 255.0, blue: 0.0)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Self.brand.opacity(0.35), lineWidth: 1)
            content.padding(18)
            closeButton
        }
        .frame(width: 360, height: 360)
        .onDrop(of: [UTType.fileURL], isTargeted: nil, perform: handleDrop)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle:
            prompt
        case let .ready(file, source, targets):
            FormatWheel(fileName: file.lastPathComponent, source: source, targets: targets) { target in
                model.convert(file: file, source: source, to: target)
            }
        case let .converting(target):
            status(system: "arrow.triangle.2.circlepath", tint: Self.brand) {
                ProgressView().controlSize(.large)
                Text("Converting to \(target.id.uppercased())…").font(.callout)
            }
        case let .done(output, bytes):
            status(system: "checkmark.circle.fill", tint: .green) {
                Text(output.lastPathComponent).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(Self.byteString(bytes)).font(.caption).foregroundStyle(.secondary)
                Button("Convert another") { model.reset() }.buttonStyle(.borderedProminent).tint(Self.brand)
            }
        case let .failed(message):
            status(system: "exclamationmark.triangle.fill", tint: .orange) {
                Text(message).font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Try again") { model.reset() }.buttonStyle(.bordered)
            }
        }
    }

    private var prompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "drop.fill").font(.system(size: 46)).foregroundStyle(Self.brand)
            Text("Drop a file to convert").font(.headline)
            Text("Images, audio, and video").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func status<Inner: View>(system: String, tint: Color, @ViewBuilder _ inner: () -> Inner) -> some View {
        VStack(spacing: 12) {
            Image(systemName: system).font(.system(size: 40)).foregroundStyle(tint)
            inner()
        }
        .frame(maxWidth: 300)
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(12)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let model = self.model   // @MainActor class is Sendable
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in model.accept(url) }
        }
        return true
    }

    static func byteString(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1000 && unit < units.count - 1 { value /= 1000; unit += 1 }
        return unit == 0 ? "\(Int(value)) \(units[unit])" : String(format: "%.1f %@", value, units[unit])
    }
}
