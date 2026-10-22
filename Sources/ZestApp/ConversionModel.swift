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

    private let engine = ConversionEngine.standard()

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
        let output = defaultOutputURL(for: file, target: target)
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

    /// Run a parsed `zest://convert?…` command (the URL-scheme automation surface).
    func run(_ command: ZestURLCommand) {
        guard let source = MediaFormat.fromURL(command.input) else {
            state = .failed("Unsupported input: .\(command.input.pathExtension)")
            return
        }
        let id = command.targetID
        guard let target = MediaFormat.catalog.first(where: { $0.id == id || $0.fileExtensions.contains(id) }) else {
            state = .failed("Unknown target format: \(id)")
            return
        }
        state = .converting(target)
        let output = command.output ?? defaultOutputURL(for: command.input, target: target)
        let request = ConversionRequest(input: command.input, output: output, source: source, target: target,
                                        options: command.options)
        let engine = self.engine
        Task {
            do {
                let result = try await engine.run(request)
                state = .done(output: result.output, bytes: result.bytes)
            } catch {
                state = .failed("\(error)")
            }
        }
    }
}
