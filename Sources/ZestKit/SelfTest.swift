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

    // defaultOutputURL — naming, folder override, suffix, and no-clobber reservation.
    let fm = FileManager.default
    let sandbox = fm.temporaryDirectory.appendingPathComponent("zest-selftest-\(UUID().uuidString)")
    let elsewhere = sandbox.appendingPathComponent("out")
    if (try? fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)) != nil,
       let jpgFmt = MediaFormat.fromExtension("jpg") {
        let photo = sandbox.appendingPathComponent("photo.heic")
        let first = defaultOutputURL(for: photo, target: jpgFmt)
        let second = defaultOutputURL(for: photo, target: jpgFmt)
        check("output lands beside the input", first.path == sandbox.appendingPathComponent("photo.jpg").path)
        check("second output doesn't clobber the first", second.lastPathComponent == "photo (2).jpg")
        check("output honours a folder override",
              defaultOutputURL(for: photo, target: jpgFmt, in: elsewhere).path == elsewhere.appendingPathComponent("photo.jpg").path)
        check("output suffix tags the stem",
              defaultOutputURL(for: photo, target: jpgFmt, suffix: "clean").lastPathComponent == "photo-clean.jpg")
        try? fm.removeItem(at: sandbox)
    } else {
        check("output naming sandbox", false)
    }

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

    // LinkDownloader — link parsing, platform detection, yt-dlp JSON, options.
    check("bare youtu.be link gets https", LinkDownloader.link(from: " youtu.be/abc ")?.absoluteString == "https://youtu.be/abc")
    check("text with spaces isn't a link", LinkDownloader.link(from: "not a link") == nil)
    check("file URL isn't a web link", !LinkDownloader.isWebLink(URL(fileURLWithPath: "/tmp/a.mp4")))
    let platforms: [(String, LinkDownloader.Platform)] = [
        ("https://www.youtube.com/watch?v=x", .youtube), ("https://youtu.be/x", .youtube),
        ("https://www.instagram.com/reel/x/", .instagram), ("https://fb.watch/x", .facebook),
        ("https://in.pinterest.com/pin/1/", .pinterest), ("https://pin.it/x", .pinterest),
        ("https://www.pinterest.co.uk/pin/1/", .pinterest), ("https://example.com/v.mp4", .other),
        ("https://notyoutube.com/x", .other),
    ]
    for (link, expected) in platforms {
        check("platform of \(link)", LinkDownloader.Platform.of(URL(string: link)!) == expected)
    }

    let youtubeJSON = """
    {"_type":"video","title":"Big Buck: Bunny/4K","uploader":"Blender","duration":635,"formats":[
     {"format_id":"sb0","ext":"mhtml","vcodec":"none","acodec":"none","format_note":"storyboard"},
     {"format_id":"140-drc","ext":"m4a","vcodec":"none","acodec":"mp4a.40.2","abr":140.0},
     {"format_id":"140","ext":"m4a","vcodec":"none","acodec":"mp4a.40.2","abr":129.4},
     {"format_id":"251","ext":"webm","vcodec":"none","acodec":"opus","abr":128.6},
     {"format_id":"299","ext":"mp4","height":1080,"vcodec":"avc1.64002A","acodec":"none"},
     {"format_id":"315","ext":"webm","height":2160,"vcodec":"vp9","acodec":"none"},
     {"format_id":"401","ext":"mp4","height":2160,"vcodec":"av01.0.13M.08","acodec":"none"}]}
    """
    let ytLink = URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ")!
    if let info = try? LinkDownloader.parse(json: Data(youtubeJSON.utf8), link: ytLink) {
        check("yt json: video and audio", info.hasVideo && info.hasAudio)
        check("yt json: best is 2160p AV1", info.bestHeight == 2160 && info.bestVideoCodec == "av01")
        check("yt json: compatible is 1080p H.264", info.compatibleHeight == 1080)
        check("yt json: DRC audio skipped", info.audioCodec == "aac" && abs((info.audioBitrate ?? 0) - 129.4) < 0.01)
        check("yt json: M4A describes the AAC stream it copies", LinkDownloader.detail(for: .m4a, info: info).contains("original AAC 129 kbps"))
        check("yt json: storyboards ignored", info.imageURL == nil)
        let options = LinkDownloader.options(for: info)
        check("yt options: best, compatible, m4a, mp3, wav", options == [.best, .compatible, .m4a, .mp3, .wav])
        check("yt label: MP4 4K", LinkDownloader.label(for: .best, info: info) == "MP4 4K")
        check("yt label: MP4 1080p", LinkDownloader.label(for: .compatible, info: info) == "MP4 1080p")
        check("file stem is filesystem-safe", LinkDownloader.fileStem(for: info) == "Big Buck - Bunny 4K")
        let args = LinkDownloader(ytdlp: URL(fileURLWithPath: "/bin/echo"), ffmpeg: URL(fileURLWithPath: "/bin/echo"))
            .arguments(for: .mp3, link: ytLink, template: "/tmp/z.%(ext)s", cookies: .safari)
        check("mp3 asks for 320K", args.contains("320K") && args.contains("mp3"))
        check("cookies passed only when chosen", args.contains("--cookies-from-browser") && args.contains("safari"))
        check("link comes last after --", Array(args.suffix(2)) == ["--", ytLink.absoluteString])
    } else {
        check("yt json parses", false)
    }

    let opusFirstJSON = """
    {"title":"music","formats":[{"format_id":"140","ext":"m4a","vcodec":"none","acodec":"mp4a.40.2","abr":129.5},
     {"format_id":"251","ext":"webm","vcodec":"none","acodec":"opus","abr":160.0}]}
    """
    if let info = try? LinkDownloader.parse(json: Data(opusFirstJSON.utf8), link: ytLink) {
        check("Opus may rate highest, yet M4A copies the AAC stream", info.audioCodec == "opus" && info.aacBitrate == 129.5)
        check("M4A isn't called a conversion when AAC exists", LinkDownloader.detail(for: .m4a, info: info).contains("untouched"))
    } else { check("opus-first json parses", false) }

    let verticalJSON = #"{"title":"reel","formats":[{"format_id":"1","ext":"mp4","width":1080,"height":1920,"vcodec":"avc1.4d","acodec":"mp4a.40.2"}]}"#
    if let info = try? LinkDownloader.parse(json: Data(verticalJSON.utf8), link: URL(string: "https://www.instagram.com/reel/x/")!) {
        check("a vertical 1080×1920 video is called 1080p", LinkDownloader.label(for: .best, info: info) == "MP4 1080p")
    } else { check("vertical json parses", false) }

    let combinedJSON = """
    {"title":"reel","formats":[{"format_id":"1","ext":"mp4","height":1080,"vcodec":"avc1.4d","acodec":"mp4a.40.2","abr":128}]}
    """
    if let info = try? LinkDownloader.parse(json: Data(combinedJSON.utf8), link: URL(string: "https://www.instagram.com/reel/x/")!) {
        check("H.264-only post offers a single MP4", LinkDownloader.options(for: info) == [.best, .m4a, .mp3, .wav])
    } else { check("combined json parses", false) }
    let imageJSON = """
    {"title":"pin","formats":[],"thumbnails":[{"url":"https://i.pinimg.com/236x/a.jpg","width":236,"height":300},
     {"url":"https://i.pinimg.com/originals/a.jpg","width":1200,"height":1600}]}
    """
    if let info = try? LinkDownloader.parse(json: Data(imageJSON.utf8), link: URL(string: "https://pin.it/x")!) {
        check("image post offers the image", LinkDownloader.options(for: info) == [.image])
        check("image post picks the largest", info.imageURL?.absoluteString == "https://i.pinimg.com/originals/a.jpg")
    } else { check("image json parses", false) }
    let genericJSON = #"{"title":"clip","formats":[{"format_id":"mp4","ext":"mp4","url":"http://x/clip.mp4"}]}"#
    if let info = try? LinkDownloader.parse(json: Data(genericJSON.utf8), link: URL(string: "http://127.0.0.1/clip.mp4")!) {
        check("unknown codecs are treated as video with sound", info.hasVideo && info.hasAudio)
    } else { check("generic json parses", false) }

    let parsed = LinkDownloader.parseProgress("[zest-progress] 251 512 NA 2048")
    check("progress falls back to the estimate", parsed?.format == "251" && parsed?.done == 512 && parsed?.total == 2048)

    // Final-review fixes: link parsing, audio-only formats, names, errors.
    check("a link is found inside shared text",
          LinkDownloader.link(from: "Look at this https://youtu.be/abc it's great")?.absoluteString == "https://youtu.be/abc")
    check("a file name isn't taken for a link", LinkDownloader.link(from: "notes.txt") == nil && LinkDownloader.link(from: "IMG_1234.HEIC") == nil)
    check("a number or an e-mail isn't a link", LinkDownloader.link(from: "1.5") == nil && LinkDownloader.link(from: "me@example.com") == nil)
    check("a bare site with a path is a link", LinkDownloader.link(from: "vimeo.com/123")?.host == "vimeo.com")
    let audioOnlyJSON = #"{"title":"voice","formats":[{"format_id":"0","ext":"m4a","vcodec":"none","url":"http://x/voice.m4a"}]}"#
    if let info = try? LinkDownloader.parse(json: Data(audioOnlyJSON.utf8), link: URL(string: "http://127.0.0.1/voice.m4a")!) {
        check("a direct audio link offers audio", info.hasAudio && !info.hasVideo && LinkDownloader.options(for: info) == [.m4a, .mp3, .wav])
    } else { check("audio-only json parses", false) }
    let sameRes = LinkDownloader.Info(link: ytLink, title: "t", hasVideo: true, hasAudio: true,
                                      bestHeight: 1080, bestVideoCodec: "av01", compatibleHeight: 1080)
    check("same-size Compatible is told apart", LinkDownloader.label(for: .compatible, info: sameRes) == "MP4 1080p H.264")
    let h264Only = LinkDownloader.Info(link: ytLink, title: "t", hasVideo: true, hasAudio: true,
                                       bestHeight: 1080, bestVideoCodec: "avc1", compatibleHeight: 1080)
    check("Compatible can be asked for even when the wheel folds it into Best",
          !LinkDownloader.options(for: h264Only).contains(.compatible) && LinkDownloader.canDeliver(.compatible, info: h264Only))
    let silent = LinkDownloader.Info(link: ytLink, title: "t", hasVideo: true, hasAudio: false, bestHeight: 720, bestVideoCodec: "avc1")
    check("a silent video isn't described as having audio", !LinkDownloader.detail(for: .best, info: silent).contains("with audio"))
    let longTitle = LinkDownloader.Info(link: ytLink, title: String(repeating: "👩‍👩‍👧 family ", count: 40), hasVideo: true, hasAudio: true)
    let stem = LinkDownloader.fileStem(for: longTitle)
    check("long titles fit APFS's name limit", stem.utf16.count <= 200 && stem.contains("👩‍👩‍👧"))
    check("no network is called out plainly",
          LinkError.from(stderr: "ERROR: Unable to download webpage: <urlopen error [Errno 8] nodename nor servname provided>",
                         platform: .youtube, host: "www.youtube.com") == .offline(host: "youtube.com"))
    check("a rate limit isn't a sign-in wall",
          LinkError.from(stderr: "ERROR: [youtube] x: This content isn't available, try again later. rate-limited", platform: .youtube) == .rateLimited(.youtube))
    check("sign-in still needed is said when sign-in is already on",
          LinkError.from(stderr: "ERROR: Sign in to confirm you're not a bot", platform: .youtube, cookies: .safari)
            == .signInStillRequired(.youtube, .safari))
    check("sign-in wall is recognised",
          LinkError.from(stderr: "ERROR: [youtube] x: Sign in to confirm you're not a bot", platform: .youtube) == .signInRequired(.youtube))
    check("cookie read failure isn't a sign-in wall",
          LinkError.from(stderr: "ERROR: could not find chrome cookies database", platform: .youtube) == .cookiesUnreadable)
    check("unsupported URL is recognised",
          LinkError.from(stderr: "ERROR: Unsupported URL: https://example.com", platform: .other) == .unsupported)
    if let command = ZestURL.parseDownload(URL(string: "zest://download?url=https%3A%2F%2Fyoutu.be%2Fabc&as=mp3")!) {
        check("zest download url parses link", command.link.absoluteString == "https://youtu.be/abc")
        check("zest download url parses option", command.option == .mp3)
    } else { check("zest download url parses", false) }

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
