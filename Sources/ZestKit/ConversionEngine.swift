import Foundation

/// Routes a request to the first registered backend that supports its
/// (source, target) pair. Add backends in priority order.
public struct ConversionEngine: Sendable {
    public let backends: [any Converter]

    public init(backends: [any Converter]) {
        self.backends = backends
    }

    public func backend(for request: ConversionRequest) -> (any Converter)? {
        backends.first { $0.supports(from: request.source, to: request.target) }
    }

    public func canConvert(from source: MediaFormat, to target: MediaFormat) -> Bool {
        backends.contains { $0.supports(from: source, to: target) }
    }

    @discardableResult
    public func run(_ request: ConversionRequest, progress: ProgressHandler? = nil) async throws -> ConversionResult {
        guard let backend = backend(for: request) else {
            throw ConversionError.unsupportedPair(request.source, request.target)
        }
        return try await backend.convert(request, progress: progress)
    }
}
