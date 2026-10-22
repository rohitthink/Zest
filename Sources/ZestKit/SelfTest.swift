import Foundation

/// Minimal backend used only by the self-checks — no external tools involved.
private struct SelfTestStubBackend: Converter {
    let identifier = "stub"
    let from: MediaFormat
    let to: MediaFormat
    func supports(from source: MediaFormat, to target: MediaFormat) -> Bool {
        source == from && target == to
    }
    func convert(_ request: ConversionRequest, progress: ProgressHandler?) async throws -> ConversionResult {
        ConversionResult(output: request.output, bytes: 0, elapsed: 0)
    }
}

/// Dependency-free self-checks that run anywhere `swift run` works — no XCTest
/// or swift-testing needed, which matters on machines that have only the Command
/// Line Tools (where SwiftPM test targets can't build). The conventional XCTest
/// suite in Tests/ runs the same assertions under full Xcode.
public func runZestSelfTests() -> (passed: Int, failed: Int, log: [String]) {
    var passed = 0
    var failed = 0
    var log: [String] = []
    func check(_ name: String, _ condition: Bool) {
        if condition { passed += 1; log.append("  ok   \(name)") }
        else { failed += 1; log.append("  FAIL \(name)") }
    }

    check("extension JPG resolves to jpg", MediaFormat.fromExtension("JPG")?.id == "jpg")
    check("webp is an image", MediaFormat.fromExtension("webp")?.category == .image)
    check("unknown extension is nil", MediaFormat.fromExtension("xyz") == nil)

    let mp3 = MediaFormat.fromExtension("mp3")!
    let wav = MediaFormat.fromExtension("wav")!
    let engine = ConversionEngine(backends: [SelfTestStubBackend(from: wav, to: mp3)])
    check("engine routes wav -> mp3", engine.canConvert(from: wav, to: mp3))
    check("engine rejects mp3 -> wav", !engine.canConvert(from: mp3, to: wav))

    let seconds = FFmpegBackend.parseDuration(from: "  Duration: 00:01:23.45, start: 0.0")
    check("ffmpeg duration parses to 83.45", seconds != nil && abs((seconds ?? 0) - 83.45) < 0.01)
    check("bad duration string is nil", FFmpegBackend.parseDuration(from: "nope") == nil)

    if let request = try? ConversionRequest.inferring(
        input: URL(fileURLWithPath: "/tmp/c.mov"),
        output: URL(fileURLWithPath: "/tmp/c.mp4")) {
        check("inference mov -> mp4", request.source.id == "mov" && request.target.id == "mp4")
    } else {
        check("inference mov -> mp4", false)
    }

    // MetadataStripper — JPEG segment removal (lossless).
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x08, 0x45, 0x78, 0x69, 0x66, 0x00, 0x00,
                     0xFF, 0xDB, 0x00, 0x04, 0xAA, 0xBB, 0xFF, 0xD9])
    if let stripped = MetadataStripper.stripJPEG(jpeg) {
        let bytes = [UInt8](stripped)
        check("jpeg strip removes APP1 (Exif)", !hasMarker(bytes, 0xE1))
        check("jpeg strip keeps DQT table", hasMarker(bytes, 0xDB))
        check("jpeg strip shrinks file", stripped.count < jpeg.count)
    } else {
        check("jpeg strip parses", false)
    }

    // MetadataStripper — PNG chunk removal (lossless).
    let png = selfTestPNGWithText()
    if let stripped = MetadataStripper.stripPNG(png) {
        check("png strip removes tEXt chunk", !dataHasASCII(stripped, "tEXt"))
        check("png strip shrinks file", stripped.count < png.count)
    } else {
        check("png strip parses", false)
    }

    // ZestURL — the URL-scheme automation surface.
    if let command = ZestURL.parse(URL(string: "zest://convert?input=/tmp/a.wav&to=mp3&quality=0.5&target-size=1MB")!) {
        check("zest url parses input", command.input.path == "/tmp/a.wav")
        check("zest url parses target", command.targetID == "mp3")
        check("zest url parses quality", command.options.quality == 0.5)
        check("zest url parses target-size", command.options.targetSizeBytes == 1_000_000)
    } else {
        check("zest url parses", false)
    }
    check("zest url rejects non-zest scheme", ZestURL.parse(URL(string: "https://example.com/convert")!) == nil)
    check("ByteSize parses 2MB", ByteSize.parse("2MB") == 2_000_000)

    // DocumentBackend catalog + routing (native paths — no external tools needed).
    check("pdf format is category pdf", MediaFormat.fromExtension("pdf")?.category == .pdf)
    check("docx is a document", MediaFormat.fromExtension("docx")?.category == .document)
    check("xlsx is a spreadsheet", MediaFormat.fromExtension("xlsx")?.category == .spreadsheet)
    let engineDoc = ConversionEngine.standard()
    let txt = MediaFormat.fromExtension("txt")!, rtf = MediaFormat.fromExtension("rtf")!
    let pdf = MediaFormat.fromExtension("pdf")!, pngFmt = MediaFormat.fromExtension("png")!
    check("engine routes txt -> rtf", engineDoc.canConvert(from: txt, to: rtf))
    check("engine routes txt -> pdf", engineDoc.canConvert(from: txt, to: pdf))
    check("engine routes pdf -> txt", engineDoc.canConvert(from: pdf, to: txt))
    check("engine routes pdf -> png", engineDoc.canConvert(from: pdf, to: pngFmt))
    check("engine routes png -> pdf", engineDoc.canConvert(from: pngFmt, to: pdf))

    return (passed, failed, log)
}

private func hasMarker(_ bytes: [UInt8], _ marker: UInt8) -> Bool {
    var i = 0
    while i + 1 < bytes.count {
        if bytes[i] == 0xFF && bytes[i + 1] == marker { return true }
        i += 1
    }
    return false
}

private func dataHasASCII(_ data: Data, _ string: String) -> Bool {
    let needle = [UInt8](string.utf8)
    let hay = [UInt8](data)
    guard needle.count <= hay.count, !needle.isEmpty else { return false }
    for start in 0...(hay.count - needle.count) where Array(hay[start..<start + needle.count]) == needle {
        return true
    }
    return false
}

private func selfTestPNGWithText() -> Data {
    var d: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] // signature
    d += [0, 0, 0, 1, 0x74, 0x45, 0x58, 0x74, 0x41, 0, 0, 0, 0]       // tEXt chunk (1 data byte)
    d += [0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0, 0, 0, 0]             // IEND
    return Data(d)
}
