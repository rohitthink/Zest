import Foundation

/// Knobs that shape a conversion. Backends interpret them as best they can and
/// ignore what does not apply.
public struct ConversionOptions: Sendable {
    /// Quality hint, 0.0 (smallest) ... 1.0 (best). Interpreted per backend.
    public var quality: Double?
    /// Target output size in bytes. When set, the backend iterates to hit it.
    public var targetSizeBytes: Int?
    /// Clamp the longest side (pixels) for raster/video. nil keeps the original.
    public var maxDimension: Int?
    /// Strip metadata (EXIF/XMP/etc.). Defaults to true — privacy-first.
    public var stripMetadata: Bool
    /// Backend-specific passthrough knobs.
    public var extra: [String: String]

    public init(quality: Double? = nil,
                targetSizeBytes: Int? = nil,
                maxDimension: Int? = nil,
                stripMetadata: Bool = true,
                extra: [String: String] = [:]) {
        self.quality = quality
        self.targetSizeBytes = targetSizeBytes
        self.maxDimension = maxDimension
        self.stripMetadata = stripMetadata
        self.extra = extra
    }
}

/// One unit of work: turn `input` (a `source` format) into `output` (a `target`
/// format) under `options`.
public struct ConversionRequest: Sendable {
    public var input: URL
    public var output: URL
    public var source: MediaFormat
    public var target: MediaFormat
    public var options: ConversionOptions

    public init(input: URL, output: URL, source: MediaFormat, target: MediaFormat, options: ConversionOptions = .init()) {
        self.input = input
        self.output = output
        self.source = source
        self.target = target
        self.options = options
    }

    /// Build a request by inferring both formats from file extensions.
    public static func inferring(input: URL, output: URL, options: ConversionOptions = .init()) throws -> ConversionRequest {
        guard let s = MediaFormat.fromURL(input) else { throw ConversionError.unknownFormat(input.pathExtension) }
        guard let t = MediaFormat.fromURL(output) else { throw ConversionError.unknownFormat(output.pathExtension) }
        return ConversionRequest(input: input, output: output, source: s, target: t, options: options)
    }
}

/// What a finished conversion produced.
public struct ConversionResult: Sendable {
    public var output: URL
    public var bytes: Int
    public var elapsed: TimeInterval
    public var attempts: Int
    public init(output: URL, bytes: Int, elapsed: TimeInterval, attempts: Int = 1) {
        self.output = output
        self.bytes = bytes
        self.elapsed = elapsed
        self.attempts = attempts
    }
}

public enum ConversionError: Error, Sendable, CustomStringConvertible {
    case unknownFormat(String)
    case unsupportedPair(MediaFormat, MediaFormat)
    case toolNotFound(String)
    case toolFailed(code: Int32, stderr: String)
    case targetUnreachable(smallestBytes: Int, targetBytes: Int)
    case io(String)

    public var description: String {
        switch self {
        case .unknownFormat(let e):
            return "Unknown or unsupported file type: .\(e)"
        case .unsupportedPair(let s, let t):
            return "No backend can convert \(s) -> \(t)"
        case .toolNotFound(let n):
            return "Required tool not found: \(n) (install it, or set ZEST_\(n.uppercased())_PATH)"
        case .toolFailed(let c, let e):
            return "Tool exited \(c): \(e.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .targetUnreachable(let s, let t):
            return "Could not reach target size \(t) bytes; smallest attempt was \(s) bytes"
        case .io(let m):
            return "I/O error: \(m)"
        }
    }
}

/// Progress callback: fraction 0.0 ... 1.0 (may be approximate).
public typealias ProgressHandler = @Sendable (Double) -> Void

/// A pluggable conversion backend. Backends are `Sendable` so the engine can
/// hold and dispatch to them across concurrency domains.
public protocol Converter: Sendable {
    var identifier: String { get }
    func supports(from source: MediaFormat, to target: MediaFormat) -> Bool
    func convert(_ request: ConversionRequest, progress: ProgressHandler?) async throws -> ConversionResult
}

public extension Converter {
    func convert(_ request: ConversionRequest) async throws -> ConversionResult {
        try await convert(request, progress: nil)
    }
}
