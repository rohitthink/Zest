import Foundation
import ImageIO
import ZestKit

/// `zest` — a headless command-line front end for ZestKit.
///
/// A first-class CLI is one of the things the subject app lacks entirely; Zest
/// treats automation as a built-in, not an afterthought. This same engine will
/// back the GUI, a URL scheme, and a Shortcuts/AppIntents surface.
@main
struct ZestCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { printUsage(); exit(2) }

        switch command {
        case "formats":
            for category in MediaCategory.allCases {
                let ids = MediaFormat.catalog
                    .filter { $0.category == category }
                    .map(\.id)
                    .sorted()
                if !ids.isEmpty { print("\(category.rawValue): \(ids.joined(separator: ", "))") }
            }
        case "selftest":
            let result = runZestSelfTests()
            result.log.forEach { print($0) }
            print("\(result.passed) passed, \(result.failed) failed")
            exit(result.failed == 0 ? 0 : 1)
        case "inspect":
            inspect(Array(args.dropFirst()))
        case "stripinfo":
            guard let path = args.dropFirst().first, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { fail("usage: zest stripinfo <file>") }
            print(MetadataStripper.diagnoseISOBMFF(data))
        case "convert":
            await runConvert(Array(args.dropFirst()))
        case "-h", "--help", "help":
            printUsage()
        default:
            FileHandle.standardError.write(Data("Unknown command: \(command)\n".utf8))
            printUsage()
            exit(2)
        }
    }

    static func runConvert(_ args: [String]) async {
        var positional: [String] = []
        var options = ConversionOptions()
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--target-size":
                index += 1
                guard index < args.count, let bytes = parseSize(args[index]) else { fail("--target-size needs a value like 2MB, 500kb, or 800000") }
                options.targetSizeBytes = bytes
            case "--quality":
                index += 1
                guard index < args.count, let q = Double(args[index]) else { fail("--quality needs a number 0.0 ... 1.0") }
                options.quality = min(max(q, 0), 1)
            case "--max-dim":
                index += 1
                guard index < args.count, let dim = Int(args[index]) else { fail("--max-dim needs an integer") }
                options.maxDimension = dim
            case "--keep-metadata":
                options.stripMetadata = false
            default:
                positional.append(args[index])
            }
            index += 1
        }

        guard positional.count == 2 else { fail("usage: zest convert <input> <output> [options]") }
        let input = URL(fileURLWithPath: positional[0])
        let output = URL(fileURLWithPath: positional[1])

        do {
            let request = try ConversionRequest.inferring(input: input, output: output, options: options)
            let engine = ConversionEngine(backends: defaultBackends())
            guard engine.canConvert(from: request.source, to: request.target) else {
                fail("no backend converts \(request.source) -> \(request.target)")
            }
            FileHandle.standardError.write(Data("Converting \(request.source) -> \(request.target)…\n".utf8))
            let result = try await engine.run(request) { fraction in
                FileHandle.standardError.write(Data("\r  \(Int(fraction * 100))%   ".utf8))
            }
            FileHandle.standardError.write(Data("\r".utf8))
            let passes = result.attempts == 1 ? "1 pass" : "\(result.attempts) passes"
            print("✔ \(result.output.path)  (\(byteString(result.bytes)), \(passes), \(String(format: "%.1f", result.elapsed))s)")
        } catch {
            fail("\(error)")
        }
    }

    static func defaultBackends() -> [any Converter] {
        var backends: [any Converter] = [ImageBackend()]
        if let ffmpeg = try? FFmpegBackend() { backends.append(ffmpeg) }
        return backends
    }

    static func inspect(_ args: [String]) {
        guard let path = args.first else { fail("usage: zest inspect <file>") }
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            fail("could not read image: \(path)")
        }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        func present(_ key: CFString) -> String {
            if let dict = props[key] as? [CFString: Any] { return dict.isEmpty ? "none" : "present" }
            return props[key] != nil ? "present" : "none"
        }
        print("file:   \(url.lastPathComponent)")
        print("pixels: \(width) x \(height)")
        print("exif:   \(present(kCGImagePropertyExifDictionary))")
        print("gps:    \(present(kCGImagePropertyGPSDictionary))")
        print("tiff:   \(present(kCGImagePropertyTIFFDictionary))")
        print("iptc:   \(present(kCGImagePropertyIPTCDictionary))")
    }

    static func parseSize(_ string: String) -> Int? {
        let lower = string.lowercased()
        let units: [(String, Double)] = [
            ("gb", 1_000_000_000), ("mb", 1_000_000), ("kb", 1_000),
            ("g", 1_000_000_000), ("m", 1_000_000), ("k", 1_000), ("b", 1),
        ]
        for (suffix, multiplier) in units where lower.hasSuffix(suffix) {
            let number = lower.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            if let value = Double(number) { return Int(value * multiplier) }
        }
        return Int(lower)
    }

    static func byteString(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1000 && unit < units.count - 1 { value /= 1000; unit += 1 }
        return unit == 0 ? "\(Int(value)) \(units[unit])" : String(format: "%.1f \(units[unit])", value)
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(1)
    }

    static func printUsage() {
        print("""
        zest — clean-room file converter (scaffold)

        USAGE:
          zest formats
          zest selftest
          zest inspect <file>
          zest convert <input> <output> [options]

        OPTIONS:
          --target-size <size>   iterate encode to hit a size (e.g. 2MB, 500kb, 800000)
          --quality <0..1>       quality hint (audio bitrate / video CRF)
          --max-dim <pixels>     clamp the longest side (video)
          --keep-metadata        keep metadata (default: strip, privacy-first)

        NOTES:
          Audio/video route through ffmpeg. Install it (brew install ffmpeg)
          or point ZEST_FFMPEG_PATH at a binary.
        """)
    }
}
