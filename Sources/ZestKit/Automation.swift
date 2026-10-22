import Foundation

/// Parse human byte sizes like "2MB", "500kb", or a bare "800000".
public enum ByteSize {
    public static func parse(_ string: String) -> Int? {
        let lower = string.lowercased().trimmingCharacters(in: .whitespaces)
        let units: [(String, Double)] = [
            ("gb", 1_000_000_000), ("mb", 1_000_000), ("kb", 1_000),
            ("g", 1_000_000_000), ("m", 1_000_000), ("k", 1_000), ("b", 1),
        ]
        for (suffix, multiplier) in units where lower.hasSuffix(suffix) {
            let number = lower.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            guard let value = Double(number) else { return nil }
            let scaled = value * multiplier
            guard scaled.isFinite, scaled >= 0, scaled <= Double(Int.max) else { return nil }   // no trap on inf/NaN/overflow/negative
            return Int(scaled)
        }
        guard let value = Int(lower), value >= 0 else { return nil }
        return value
    }
}

/// Choose a non-clobbering output path beside the input (`photo.png`,
/// `photo (2).png`, …). Shared by every front end.
public func defaultOutputURL(for input: URL, target: MediaFormat) -> URL {
    let directory = input.deletingLastPathComponent()
    let stem = input.deletingPathExtension().lastPathComponent
    var suffix = 1
    while true {
        let name = suffix == 1 ? stem : "\(stem) (\(suffix))"
        let candidate = directory.appendingPathComponent(name).appendingPathExtension(target.primaryExtension)
        // Reserve the name atomically (O_EXCL) so two concurrent conversions can't
        // resolve to the same not-yet-written path and clobber each other.
        let fd = open(candidate.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        if fd >= 0 { close(fd); return candidate }
        if errno != EEXIST { return candidate }     // some other error: best effort
        suffix += 1
        if suffix > 10_000 { return candidate }      // safety valve
    }
}

public extension ConversionEngine {
    /// The standard engine: `ImageBackend` plus `FFmpegBackend` when ffmpeg is
    /// available. Used by the CLI, the GUI, the URL scheme, and AppIntents so
    /// every surface shares one engine definition.
    static func standard() -> ConversionEngine {
        var backends: [any Converter] = [ImageBackend(), DocumentBackend()]
        if let ffmpeg = try? FFmpegBackend() { backends.append(ffmpeg) }
        return ConversionEngine(backends: backends)
    }

    /// Convert a file to a target format id (e.g. "png" or "jpg"), choosing the
    /// output path automatically unless one is supplied.
    @discardableResult
    func convertFile(at input: URL, toFormat targetID: String,
                     options: ConversionOptions = .init(), output: URL? = nil) async throws -> ConversionResult {
        guard let source = MediaFormat.fromURL(input) else { throw ConversionError.unknownFormat(input.pathExtension) }
        let id = targetID.lowercased()
        guard let target = MediaFormat.catalog.first(where: { $0.id == id || $0.fileExtensions.contains(id) }) else {
            throw ConversionError.unknownFormat(targetID)
        }
        let out = output ?? defaultOutputURL(for: input, target: target)
        return try await run(ConversionRequest(input: input, output: out, source: source, target: target, options: options))
    }
}

/// A parsed `zest://convert?…` request — the app's URL-scheme automation surface.
public struct ZestURLCommand: Sendable {
    public var input: URL
    public var targetID: String
    public var options: ConversionOptions
    public var output: URL?
}

public enum ZestURL {
    public static let scheme = "zest"

    /// Parse `zest://convert?input=<path>&to=<fmt>&quality=<0..1>&target-size=<size>&max-dim=<px>&keep-metadata=1&output=<path>`.
    /// Only `input` and `to` are required.
    public static func parse(_ url: URL) -> ZestURLCommand? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "convert" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where item.value != nil { query[item.name.lowercased()] = item.value }
        guard let inputString = query["input"], !inputString.isEmpty,
              let targetID = query["to"], !targetID.isEmpty else { return nil }

        var options = ConversionOptions()
        if let s = query["quality"], let d = Double(s) { options.quality = min(max(d, 0), 1) }
        if let s = query["target-size"], let bytes = ByteSize.parse(s) { options.targetSizeBytes = bytes }
        if let s = query["max-dim"], let n = Int(s) { options.maxDimension = n }
        if let s = query["keep-metadata"], ["1", "true", "yes"].contains(s.lowercased()) { options.stripMetadata = false }

        let input = URL(fileURLWithPath: (inputString as NSString).expandingTildeInPath)
        let output = query["output"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        return ZestURLCommand(input: input, targetID: targetID.lowercased(), options: options, output: output)
    }
}
