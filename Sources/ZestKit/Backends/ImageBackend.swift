import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Converts raster images using Apple's native **ImageIO** (no external tool for
/// HEIC/JPEG/PNG/TIFF/GIF/BMP) and **cwebp** for WebP encoding. Metadata is
/// stripped by default; when the source and target format match and no resize or
/// quality change is requested, it uses `MetadataStripper` for a lossless,
/// offset-preserving strip instead of re-encoding.
public struct ImageBackend: Converter {
    public let identifier = "imageio"
    public let cwebp: URL?
    public let dwebp: URL?

    public init(cwebp: URL? = nil, dwebp: URL? = nil) {
        self.cwebp = cwebp ?? ToolLocator.find("cwebp")
        self.dwebp = dwebp ?? ToolLocator.find("dwebp")
    }

    private static let imageIOWritable: Set<String> = ["jpg", "png", "heic", "tiff", "gif", "bmp"]

    public func supports(from source: MediaFormat, to target: MediaFormat) -> Bool {
        guard source.category == .image, target.category == .image else { return false }
        let canEncodeTarget = target.id == "webp" ? (cwebp != nil) : Self.imageIOWritable.contains(target.id)
        return canEncodeTarget
    }

    public func convert(_ request: ConversionRequest, progress: ProgressHandler?) async throws -> ConversionResult {
        let start = Date()
        let options = request.options
        progress?(0.1)

        // Fast path: lossless, offset-preserving metadata strip when nothing else changes.
        if options.stripMetadata, request.source.id == request.target.id,
           options.maxDimension == nil, options.quality == nil,
           ["jpg", "png", "heic"].contains(request.source.id) {
            if let data = try? Data(contentsOf: request.input),
               let (stripped, _) = MetadataStripper.strip(data, formatID: request.source.id),
               Self.decodes(stripped) {
                try stripped.write(to: request.output)
                progress?(1.0)
                return ConversionResult(output: request.output, bytes: stripped.count, elapsed: Date().timeIntervalSince(start))
            }
            // Fall through to a metadata-dropping re-encode if the surgical strip
            // couldn't be validated.
        }

        // Target-size: iterate quality for lossy image targets (the CLI/URL advertise it).
        if let budget = options.targetSizeBytes {
            guard ["jpg", "heic", "webp"].contains(request.target.id) else {
                throw ConversionError.io("target-size is only supported for jpg/heic/webp image targets")
            }
            let (bytes, attempts) = try targetSizeImage(request, targetBytes: budget)
            progress?(1.0)
            return ConversionResult(output: request.output, bytes: bytes, elapsed: Date().timeIntervalSince(start), attempts: attempts)
        }

        if request.target.id == "webp" {
            let bytes = try encodeWebP(request, progress: progress)
            return ConversionResult(output: request.output, bytes: bytes, elapsed: Date().timeIntervalSince(start))
        }

        let image = try loadUpright(request.input, maxPixel: options.maxDimension, source: request.source)
        try writeImageIO(image, to: request.output, format: request.target, options: options, sourceURL: request.input)
        progress?(1.0)
        return ConversionResult(output: request.output, bytes: fileSize(request.output), elapsed: Date().timeIntervalSince(start))
    }

    // MARK: - Decode

    private func loadUpright(_ url: URL, maxPixel: Int?, source: MediaFormat) throws -> CGImage {
        if let image = Self.makeUpright(url: url, maxPixel: maxPixel) { return image }
        // WebP (or anything ImageIO can't read) → decode via dwebp into a temp PNG.
        if source.id == "webp", let dwebp {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("zest-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let out = try ProcessRunner.run(dwebp, [url.path, "-o", tmp.path])
            guard out.code == 0, let image = Self.makeUpright(url: tmp, maxPixel: maxPixel) else {
                throw ConversionError.toolFailed(code: out.code, stderr: out.stderr)
            }
            return image
        }
        throw ConversionError.io("could not decode image: \(url.lastPathComponent)")
    }

    /// Decode to an upright, optionally downscaled CGImage. Using the thumbnail
    /// path with `WithTransform` bakes in EXIF orientation; a max-pixel equal to
    /// the source's largest side returns full resolution.
    static func makeUpright(url: URL, maxPixel: Int?) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let width = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let sourceLargest = max(width, height)
        // Only clamp when a real target size or a real source dimension is known;
        // with neither, full-decode instead of asking for a 1px thumbnail.
        guard let maxPx = maxPixel ?? (sourceLargest > 0 ? sourceLargest : nil) else {
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPx,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    // MARK: - Encode (ImageIO)

    private func writeImageIO(_ image: CGImage, to url: URL, format: MediaFormat, options: ConversionOptions, sourceURL: URL) throws {
        guard let uti = Self.utiFor(format) else { throw ConversionError.io("no destination type for \(format)") }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil) else {
            throw ConversionError.io("could not create image destination for \(format)")
        }
        var props: [CFString: Any] = [:]
        if let q = options.quality { props[kCGImageDestinationLossyCompressionQuality] = q }
        if !options.stripMetadata,
           let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let srcProps = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                        kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary] where srcProps[key] != nil {
                props[key] = srcProps[key]
            }
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.io("image encode failed") }
    }

    static func utiFor(_ format: MediaFormat) -> String? {
        switch format.id {
        case "jpg":  return UTType.jpeg.identifier
        case "png":  return UTType.png.identifier
        case "heic": return "public.heic"
        case "tiff": return UTType.tiff.identifier
        case "gif":  return UTType.gif.identifier
        case "bmp":  return UTType.bmp.identifier
        default:     return format.uti
        }
    }

    // MARK: - Encode (WebP via cwebp)

    private func encodeWebP(_ request: ConversionRequest, progress: ProgressHandler?) throws -> Int {
        let image = try loadUpright(request.input, maxPixel: request.options.maxDimension, source: request.source)
        let keep = !request.options.stripMetadata
        let staged = try stagePNG(image, metadataFrom: keep ? request.input : nil)
        defer { try? FileManager.default.removeItem(at: staged) }
        progress?(0.6)
        let quality = request.options.quality.map { Int($0 * 100) } ?? 80
        let bytes = try runCwebp(staged, to: request.output, quality: quality, keepMetadata: keep)
        progress?(1.0)
        return bytes
    }

    /// Stage an upright PNG for cwebp. When `metadataFrom` is set, the staged PNG
    /// carries the source's EXIF/GPS/TIFF/IPTC so cwebp's `-metadata all` has data
    /// to copy (otherwise "keep metadata" silently produced a bare WebP).
    private func stagePNG(_ image: CGImage, metadataFrom sourceURL: URL?) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("zest-\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ConversionError.io("could not stage PNG for webp")
        }
        var props: [CFString: Any] = [:]
        if let sourceURL, let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let srcProps = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                        kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary] where srcProps[key] != nil {
                props[key] = srcProps[key]
            }
        }
        CGImageDestinationAddImage(dest, image, props.isEmpty ? nil : (props as CFDictionary))
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.io("png staging failed") }
        return tmp
    }

    private func runCwebp(_ staged: URL, to output: URL, quality: Int, keepMetadata: Bool) throws -> Int {
        guard let cwebp else { throw ConversionError.toolNotFound("cwebp") }
        let args = [staged.path, "-o", output.path, "-quiet",
                    "-q", String(min(max(quality, 0), 100)),
                    "-metadata", keepMetadata ? "all" : "none"]
        let out = try ProcessRunner.run(cwebp, args)
        guard out.code == 0 else { throw ConversionError.toolFailed(code: out.code, stderr: out.stderr) }
        return fileSize(output)
    }

    /// Encode one CGImage to the target at a given quality — used by target-size search.
    private func encode(_ image: CGImage, to url: URL, format: MediaFormat, quality: Double) throws -> Int {
        if format.id == "webp" {
            let staged = try stagePNG(image, metadataFrom: nil)
            defer { try? FileManager.default.removeItem(at: staged) }
            return try runCwebp(staged, to: url, quality: Int(quality * 100), keepMetadata: false)
        }
        guard let uti = Self.utiFor(format),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil) else {
            throw ConversionError.io("could not create image destination")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.io("image encode failed") }
        return fileSize(url)
    }

    /// Binary-search quality to land a lossy image target within a byte budget.
    private func targetSizeImage(_ request: ConversionRequest, targetBytes: Int) throws -> (bytes: Int, attempts: Int) {
        let image = try loadUpright(request.input, maxPixel: request.options.maxDimension, source: request.source)
        var low = 0.0, high = 1.0
        var closest = Int.max
        var bestUnder: (bytes: Int, quality: Double)?
        let tolerance = 0.08
        let maxAttempts = 7
        for attempt in 1...maxAttempts {
            let quality = (low + high) / 2.0
            let bytes = try encode(image, to: request.output, format: request.target, quality: quality)
            closest = min(closest, bytes)
            if bytes <= targetBytes, bestUnder == nil || bytes > bestUnder!.bytes { bestUnder = (bytes, quality) }
            if bytes <= targetBytes, abs(1.0 - Double(bytes) / Double(targetBytes)) <= tolerance {
                return (bytes, attempt)
            }
            if bytes > targetBytes { high = quality } else { low = quality }
        }
        if let bestUnder {
            let bytes = try encode(image, to: request.output, format: request.target, quality: bestUnder.quality)
            return (bytes, maxAttempts)
        }
        throw ConversionError.targetUnreachable(smallestBytes: closest, targetBytes: targetBytes)
    }

    // MARK: - Helpers

    static func decodes(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceCreateImageAtIndex(src, 0, nil) != nil
    }

    private func fileSize(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int) ?? 0
    }
}
