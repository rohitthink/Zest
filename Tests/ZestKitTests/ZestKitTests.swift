import XCTest
@testable import ZestKit

// Conventional XCTest suite — runs under full Xcode (`swift test`).
// On Command-Line-Tools-only machines XCTest is unavailable; use the
// dependency-free runner instead: `swift run zest selftest`.
final class ZestKitTests: XCTestCase {

    func testFormatLookupIsCaseInsensitive() {
        XCTAssertEqual(MediaFormat.fromExtension("JPG")?.id, "jpg")
        XCTAssertEqual(MediaFormat.fromExtension("jpeg")?.id, "jpg")
        XCTAssertEqual(MediaFormat.fromExtension("webp")?.category, .image)
        XCTAssertNil(MediaFormat.fromExtension("xyz"))
    }

    func testEngineRoutesToSupportingBackend() {
        let mp3 = MediaFormat.fromExtension("mp3")!
        let wav = MediaFormat.fromExtension("wav")!
        let engine = ConversionEngine(backends: [StubBackend(source: wav, target: mp3)])
        XCTAssertTrue(engine.canConvert(from: wav, to: mp3))
        XCTAssertFalse(engine.canConvert(from: mp3, to: wav))
    }

    func testUnsupportedPairThrows() async {
        let mp3 = MediaFormat.fromExtension("mp3")!
        let wav = MediaFormat.fromExtension("wav")!
        let engine = ConversionEngine(backends: [])
        let request = ConversionRequest(input: URL(fileURLWithPath: "/tmp/a.wav"),
                                        output: URL(fileURLWithPath: "/tmp/a.mp3"),
                                        source: wav, target: mp3)
        do {
            _ = try await engine.run(request)
            XCTFail("expected unsupportedPair")
        } catch let error as ConversionError {
            if case .unsupportedPair = error {} else { XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testDurationParsing() {
        let stderr = "  Duration: 00:01:23.45, start: 0.000000, bitrate: 128 kb/s"
        XCTAssertEqual(FFmpegBackend.parseDuration(from: stderr)!, 83.45, accuracy: 0.01)
        XCTAssertNil(FFmpegBackend.parseDuration(from: "no duration here"))
    }

    func testSizeInferenceFromExtensions() throws {
        let request = try ConversionRequest.inferring(
            input: URL(fileURLWithPath: "/tmp/clip.mov"),
            output: URL(fileURLWithPath: "/tmp/clip.mp4"))
        XCTAssertEqual(request.source.id, "mov")
        XCTAssertEqual(request.target.id, "mp4")
    }
}

/// Minimal backend for routing tests — no external tools involved.
private struct StubBackend: Converter {
    let identifier = "stub"
    let source: MediaFormat
    let target: MediaFormat
    func supports(from source: MediaFormat, to target: MediaFormat) -> Bool {
        source == self.source && target == self.target
    }
    func convert(_ request: ConversionRequest, progress: ProgressHandler?) async throws -> ConversionResult {
        ConversionResult(output: request.output, bytes: 0, elapsed: 0)
    }
}
