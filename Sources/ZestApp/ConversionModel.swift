import SwiftUI
import ZestKit

/// Bridges the SwiftUI drop UI to the ZestKit engine. `@MainActor` makes it
/// Sendable, so it can be captured by the drop-provider completion safely; the
/// engine call runs off the main actor (ZestKit's `convert` is nonisolated
/// async), keeping the UI responsive.
@MainActor
final class ConversionModel: ObservableObject {

    enum State {
        case idle
        case ready(file: URL, source: MediaFormat, targets: [MediaFormat])
        case converting(MediaFormat)
        case done(output: URL, bytes: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let engine: ConversionEngine = {
        var backends: [any Converter] = [ImageBackend()]
        if let ffmpeg = try? FFmpegBackend() { backends.append(ffmpeg) }
        return ConversionEngine(backends: backends)
    }()

    /// A file was dropped — resolve its format and the reachable targets.
    func accept(_ url: URL) {
        guard let source = MediaFormat.fromURL(url) else {
            state = .failed("Unsupported file type: .\(url.pathExtension)")
            return
        }
        let targets = MediaFormat.catalog.filter { $0.id != source.id && engine.canConvert(from: source, to: $0) }
        guard !targets.isEmpty else {
            state = .failed("No conversions available for .\(source.id)")
            return
        }
        state = .ready(file: url, source: source, targets: Array(targets.prefix(8)))
    }

    /// Run a conversion to the chosen target. Output lands beside the source.
    func convert(file: URL, source: MediaFormat, to target: MediaFormat) {
        state = .converting(target)
        let output = Self.outputURL(for: file, target: target)
        let request = ConversionRequest(input: file, output: output, source: source, target: target,
                                        options: ConversionOptions(quality: 0.8))
        let engine = self.engine
        Task {
            do {
                let result = try await engine.run(request)   // runs off the main actor
                state = .done(output: result.output, bytes: result.bytes)
            } catch {
                state = .failed("\(error)")
            }
        }
    }

    func reset() { state = .idle }

    /// Choose a non-clobbering output path beside the input.
    static func outputURL(for input: URL, target: MediaFormat) -> URL {
        let directory = input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent(stem).appendingPathExtension(target.primaryExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) (\(suffix))").appendingPathExtension(target.primaryExtension)
            suffix += 1
        }
        return candidate
    }
}
