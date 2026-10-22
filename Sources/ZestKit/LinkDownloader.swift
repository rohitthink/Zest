import Foundation
import UniformTypeIdentifiers

/// Downloads media from web links — YouTube, Instagram, Facebook, Pinterest and
/// the many other sites yt-dlp understands — in the best quality each site
/// offers.
///
/// yt-dlp is located at runtime and never bundled: it has to keep pace with
/// the sites, so the user's Homebrew copy (`brew install yt-dlp`) is the one
/// to use. ffmpeg merges separate video/audio streams and converts audio.
///
/// Honest quality: these sites only serve compressed audio (typically AAC or
/// Opus at 128–160 kbps). M4A keeps the site's AAC stream untouched; MP3 320
/// and WAV are conversions of that stream for compatibility and editing.
public struct LinkDownloader: Sendable {
    public let ytdlp: URL?
    public let ffmpeg: URL?

    public init(ytdlp: URL? = nil, ffmpeg: URL? = nil) {
        self.ytdlp = ytdlp ?? ToolLocator.find("yt-dlp")
        self.ffmpeg = ffmpeg ?? ToolLocator.find("ffmpeg")
    }

    // MARK: - Links

    /// True for an http(s) URL with a host.
    public static func isWebLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return url.host?.isEmpty == false
    }

    /// A link from pasted text. Accepts a bare "youtu.be/…" by assuming https,
    /// and pulls the link out of surrounding text ("Watch this: https://…").
    public static func link(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains(where: \.isWhitespace) {
            guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
            return detector.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
                .compactMap(\.url).first(where: isWebLink)
        }
        if trimmed.contains("://") {
            guard let url = URL(string: trimmed), isWebLink(url), url.host?.contains(".") == true else { return nil }
            return url
        }
        // No scheme typed: only something that really reads as a web address —
        // a letters-only top-level domain and a path (or a known site), so
        // "notes.txt", "1.5" and e-mail addresses aren't taken for links.
        guard !trimmed.contains("@"), let url = URL(string: "https://\(trimmed)"), let host = url.host,
              host.contains("."), let tld = host.split(separator: ".").last,
              tld.count >= 2, tld.allSatisfy(\.isLetter) else { return nil }
        let hasPath = !url.path.isEmpty && url.path != "/"
        return hasPath || Platform.of(url) != .other ? url : nil
    }

    /// The site a link belongs to, for labels and sign-in hints.
    public enum Platform: String, Sendable, CaseIterable {
        case youtube, instagram, facebook, pinterest, tiktok, vimeo, x, other

        public var displayName: String {
            switch self {
            case .youtube: return "YouTube"
            case .instagram: return "Instagram"
            case .facebook: return "Facebook"
            case .pinterest: return "Pinterest"
            case .tiktok: return "TikTok"
            case .vimeo: return "Vimeo"
            case .x: return "X"
            case .other: return "Web"
            }
        }

        public static func of(_ url: URL) -> Platform {
            let host = (url.host ?? "").lowercased()
            func matches(_ domains: String...) -> Bool {
                domains.contains { host == $0 || host.hasSuffix(".\($0)") }
            }
            if matches("youtube.com", "youtu.be", "youtube-nocookie.com") { return .youtube }
            if matches("instagram.com", "instagr.am") { return .instagram }
            if matches("facebook.com", "fb.watch", "fb.com") { return .facebook }
            if matches("pin.it") || host == "pinterest.com" || host.hasSuffix(".pinterest.com")
                || host.hasPrefix("pinterest.") || host.contains(".pinterest.") { return .pinterest }
            if matches("tiktok.com") { return .tiktok }
            if matches("vimeo.com") { return .vimeo }
            if matches("x.com", "twitter.com") { return .x }
            return .other
        }
    }

    /// Browser whose sign-in cookies yt-dlp may borrow for private or
    /// sign-in-only posts. Off unless the user opts in.
    public enum CookieSource: String, Sendable, CaseIterable {
        case none, safari, chrome, brave, firefox, edge

        public var displayName: String {
            switch self {
            case .none: return "Off"
            case .safari: return "Safari"
            case .chrome: return "Chrome"
            case .brave: return "Brave"
            case .firefox: return "Firefox"
            case .edge: return "Edge"
            }
        }
    }

    // MARK: - What a link offers

    /// What a link holds, read before anything is downloaded.
    public struct Info: Sendable, Equatable {
        public var link: URL
        public var title: String
        public var uploader: String?
        /// Seconds.
        public var duration: Double?
        public var platform: Platform
        public var hasVideo: Bool
        public var hasAudio: Bool
        /// Best video resolution in pixels, by the short side (1080 for both
        /// 1920×1080 and a vertical 1080×1920).
        public var bestHeight: Int?
        /// Codec family of that stream: "av01", "vp9", "avc1", "hevc".
        public var bestVideoCodec: String?
        /// Best H.264 resolution (short side) — what plays everywhere.
        public var compatibleHeight: Int?
        /// Best non-DRC audio stream, kbps, and its codec family ("aac", "opus").
        public var audioBitrate: Double?
        public var audioCodec: String?
        /// Best non-DRC AAC stream, kbps — what the M4A, MP3 and WAV options
        /// start from (on YouTube usually format 140, even when Opus 251 rates higher).
        public var aacBitrate: Double?
        /// The site has an AAC stream (its bitrate may be unknown), so M4A is
        /// a straight copy rather than a conversion.
        public var hasAACStream: Bool
        /// Image posts (no video or audio): the full-size image.
        public var imageURL: URL?
        /// Items in a carousel or playlist; Zest downloads the first.
        public var itemCount: Int

        public init(link: URL, title: String, uploader: String? = nil, duration: Double? = nil,
                    platform: Platform? = nil, hasVideo: Bool, hasAudio: Bool,
                    bestHeight: Int? = nil, bestVideoCodec: String? = nil, compatibleHeight: Int? = nil,
                    audioBitrate: Double? = nil, audioCodec: String? = nil, aacBitrate: Double? = nil,
                    hasAACStream: Bool? = nil, imageURL: URL? = nil, itemCount: Int = 1) {
            self.link = link
            self.title = title
            self.uploader = uploader
            self.duration = duration
            self.platform = platform ?? Platform.of(link)
            self.hasVideo = hasVideo
            self.hasAudio = hasAudio
            self.bestHeight = bestHeight
            self.bestVideoCodec = bestVideoCodec
            self.compatibleHeight = compatibleHeight
            self.audioBitrate = audioBitrate
            self.audioCodec = audioCodec
            self.aacBitrate = aacBitrate ?? (audioCodec == "aac" ? audioBitrate : nil)
            self.hasAACStream = hasAACStream ?? (self.aacBitrate != nil || audioCodec == "aac")
            self.imageURL = imageURL
            self.itemCount = itemCount
        }
    }

    /// A way to save a link.
    public enum Option: String, Sendable, CaseIterable {
        /// Video with audio, highest resolution (AV1/VP9 above 1080p on YouTube), MP4.
        case best
        /// Video with audio as H.264 + AAC MP4 — plays everywhere.
        case compatible
        /// Audio only: the site's AAC stream untouched (converted only if there is none).
        case m4a
        /// Audio only, MP3 320 kbps.
        case mp3
        /// Audio only, uncompressed WAV.
        case wav
        /// The full-size image of an image post.
        case image
    }

    /// The options worth offering for `info`, most useful first.
    public static func options(for info: Info) -> [Option] {
        var options: [Option] = []
        if info.hasVideo {
            options.append(.best)
            // Offer a separate "plays everywhere" copy only when Best isn't already H.264.
            if let compatible = info.compatibleHeight, info.bestVideoCodec != "avc1" || compatible != info.bestHeight {
                options.append(.compatible)
            }
        }
        if info.hasAudio { options += [.m4a, .mp3, .wav] }
        if !info.hasVideo, info.imageURL != nil { options.append(.image) }
        return options
    }

    /// Whether `info` can deliver `option` at all — wider than `options(for:)`,
    /// which leaves out Compatible when it would duplicate Best.
    public static func canDeliver(_ option: Option, info: Info) -> Bool {
        switch option {
        case .best, .compatible: return info.hasVideo
        case .m4a, .mp3, .wav: return info.hasAudio
        case .image: return !info.hasVideo && info.imageURL != nil
        }
    }

    /// Short wheel label: "MP4 4K", "MP3". Compatible at Best's resolution
    /// says "H.264", so the two never read the same.
    public static func label(for option: Option, info: Info) -> String {
        switch option {
        case .best: return info.bestHeight.map { "MP4 \(resolutionName($0))" } ?? "MP4"
        case .compatible:
            guard let height = info.compatibleHeight else { return "MP4 H.264" }
            return height == info.bestHeight ? "MP4 \(resolutionName(height)) H.264" : "MP4 \(resolutionName(height))"
        case .m4a: return "M4A"
        case .mp3: return "MP3"
        case .wav: return "WAV"
        case .image: return "Image"
        }
    }

    /// One-line explanation for tooltips and VoiceOver.
    public static func detail(for option: Option, info: Info) -> String {
        let source = audioDescription(info)
        let video = info.hasAudio ? "Video with audio" : "Video (no sound)"
        switch option {
        case .best:
            let res = info.bestHeight.map { "\($0)p " } ?? ""
            switch info.bestVideoCodec {
            case "av01": return "\(video), best quality — \(res)AV1. Plays in QuickTime on Macs with M3 or newer; use VLC on older Macs."
            case "vp9": return "\(video), best quality — \(res)VP9. Plays in VLC or IINA, not QuickTime."
            case "hevc": return "\(video), best quality — \(res)HEVC."
            case "avc1": return "\(video), best quality — \(res)H.264. Plays everywhere."
            default: return "\(video), best quality the site offers."
            }
        case .compatible:
            let res = info.compatibleHeight.map { "\($0)p " } ?? ""
            return "\(video) that plays everywhere — \(res)H.264\(info.hasAudio ? " + AAC" : "")."
        case .m4a:
            if info.hasAACStream {
                let kbps = info.aacBitrate.map { " \(Int($0.rounded())) kbps" } ?? ""
                return "Audio only — the site's original AAC\(kbps) stream, untouched."
            }
            if info.audioCodec == nil {
                return "Audio only as AAC — copied untouched when the site already uses AAC, otherwise converted at 256 kbps."
            }
            return "Audio only as AAC 256 kbps, converted from the site's \(source) audio."
        case .mp3:
            return "MP3 320 kbps, converted from the site's \(source) audio — can't add back quality the site didn't keep."
        case .wav:
            return "Uncompressed WAV for editing, decoded from the site's \(source) audio."
        case .image:
            return "The original full-size image."
        }
    }

    /// File extension an option produces (image: the image's own extension).
    public static func fileExtension(for option: Option, info: Info) -> String {
        switch option {
        case .best, .compatible: return "mp4"
        case .m4a: return "m4a"
        case .mp3: return "mp3"
        case .wav: return "wav"
        case .image:
            let ext = info.imageURL?.pathExtension.lowercased() ?? ""
            return ["jpg", "jpeg", "png", "webp", "gif", "heic"].contains(ext) ? (ext == "jpeg" ? "jpg" : ext) : "jpg"
        }
    }

    /// A safe file name stem from the title ("My Video: Part 1" → "My Video - Part 1").
    public static func fileStem(for info: Info) -> String {
        // Keep emoji joiners (ZWJ/ZWNJ are "format" characters, not junk).
        let junk = CharacterSet(charactersIn: "/\\?%*|\"<>\n\r\t")
            .union(CharacterSet.controlCharacters.subtracting(CharacterSet(charactersIn: "\u{200C}\u{200D}")))
        var stem = info.title
            .replacingOccurrences(of: ":", with: " -")
            .components(separatedBy: junk)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        while stem.contains("  ") { stem = stem.replacingOccurrences(of: "  ", with: " ") }
        // APFS allows 255 UTF-16 units per name; leave room for " (12345).ext".
        while stem.utf16.count > 200 { stem.removeLast() }   // whole characters, so emoji stay intact
        stem = stem.trimmingCharacters(in: .whitespaces)
        return stem.isEmpty ? "\(info.platform.displayName) download" : stem
    }

    static func resolutionName(_ height: Int) -> String {
        switch height {
        case 4320...: return "8K"
        case 2160..<4320: return "4K"
        default: return "\(height)p"
        }
    }

    /// The stream the audio options start from: the AAC stream when there is
    /// one (MP3/WAV pick it too), else the best stream.
    private static func audioDescription(_ info: Info) -> String {
        if info.hasAACStream {
            return info.aacBitrate.map { "AAC \(Int($0.rounded())) kbps" } ?? "AAC"
        }
        let codec = info.audioCodec.map { $0 == "aac" ? "AAC" : $0.capitalized } ?? "compressed"
        guard let kbps = info.audioBitrate, kbps > 0 else { return codec }
        return "\(codec) \(Int(kbps.rounded())) kbps"
    }

    /// Remove `zest-dl-*` temp folders left by a quit or crash mid-download.
    /// Only old ones: a recent folder may belong to a running CLI download,
    /// and a failed save keeps its file there for the user to rescue.
    public static func sweepStaleTemporaryFolders(olderThan age: TimeInterval = 3 * 86_400) {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory
        guard let names = try? fm.contentsOfDirectory(atPath: temp.path) else { return }
        for name in names where name.hasPrefix("zest-dl-") {
            let url = temp.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantFuture
            if Date().timeIntervalSince(modified) > age { try? fm.removeItem(at: url) }
        }
    }

    // MARK: - Reading a link

    /// Read what a link offers (`yt-dlp -J`). Nothing is downloaded.
    public func inspect(_ link: URL, cookies: CookieSource = .none) async throws -> Info {
        guard let ytdlp else { throw LinkError.toolMissing("yt-dlp") }
        let platform = Platform.of(link)
        // --ignore-config: the user's own yt-dlp config mustn't override Zest's choices.
        var args = ["-J", "--ignore-config", "--no-warnings", "--no-progress", "--no-playlist", "--playlist-items", "1"]
        if cookies != .none { args += ["--cookies-from-browser", cookies.rawValue] }
        var out = try await ProcessRunner.stream(ytdlp, args + ["--", link.absoluteString])
        try Task.checkCancellation()
        // Image posts (Pinterest pins, Instagram photos) have no media formats,
        // which yt-dlp reports as an error; read them again for their images.
        // Only on those sites — elsewhere "no formats" means private or
        // unavailable, and must stay an error rather than offer a thumbnail.
        if out.code != 0, [.pinterest, .instagram].contains(platform), Self.isNoFormatsError(out.stderr) {
            out = try await ProcessRunner.stream(ytdlp, args + ["--ignore-no-formats-error", "--", link.absoluteString])
            try Task.checkCancellation()
        }
        guard out.code == 0 else {
            throw LinkError.from(stderr: out.stderr, platform: platform, host: link.host, cookies: cookies)
        }
        return try Self.parse(json: Data(out.stdout.utf8), link: link)
    }

    static func isNoFormatsError(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        return text.contains("no video formats") || text.contains("there is no video in this post")
    }

    /// Turn `yt-dlp -J` output into `Info`.
    public static func parse(json: Data, link: URL) throws -> Info {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw LinkError.failed("yt-dlp returned something Zest couldn't read")
        }
        // Playlists and carousels: take the first item, however deeply nested
        // (a channel is a playlist of playlists).
        var item = root
        var itemCount = 1
        var depth = 0
        while let entries = item["entries"] as? [Any], depth < 4 {
            guard let first = entries.compactMap({ $0 as? [String: Any] }).first else { throw LinkError.nothingToDownload }
            if depth == 0 { itemCount = (item["playlist_count"] as? Int) ?? entries.count }
            item = first
            depth += 1
        }

        var formats = (item["formats"] as? [[String: Any]]) ?? []
        if formats.isEmpty, item["url"] != nil { formats = [item] }   // single-format items
        formats = formats.filter { f in
            let note = (f["format_note"] as? String)?.lowercased() ?? ""
            return f["ext"] as? String != "mhtml" && !note.contains("storyboard")
        }

        func codec(_ value: Any?) -> String? { value as? String }   // nil = unknown, "none" = absent
        func carriesVideo(_ f: [String: Any]) -> Bool {
            let v = codec(f["vcodec"]), a = codec(f["acodec"])
            if let v { return v != "none" }
            return a == nil || f["height"] as? Int != nil          // unknown codecs: assume a normal video file
        }
        func carriesAudio(_ f: [String: Any]) -> Bool {
            // Only an explicit "none" means silent: direct .m4a/.wav links and
            // HLS audio renditions come with vcodec "none" and no acodec at all.
            if let a = codec(f["acodec"]) { return a != "none" }
            return true
        }
        func family(_ codec: String?) -> String? {
            guard let c = codec?.lowercased(), c != "none" else { return nil }
            if c.hasPrefix("av01") { return "av01" }
            if c.hasPrefix("vp09") || c.hasPrefix("vp9") { return "vp9" }
            if c.hasPrefix("avc") || c.hasPrefix("h264") { return "avc1" }
            if c.hasPrefix("hev") || c.hasPrefix("hvc") || c.hasPrefix("h265") { return "hevc" }
            if c.hasPrefix("mp4a") || c == "aac" { return "aac" }
            if c.hasPrefix("opus") { return "opus" }
            return c.components(separatedBy: ".").first
        }
        let codecRank = ["av01": 3, "vp9": 2, "hevc": 1, "avc1": 0]

        let video = formats.filter(carriesVideo)
        let audio = formats.filter(carriesAudio)
        // Resolution by the short side, as people name it: a vertical
        // 1080×1920 reel is "1080p", not "1920p".
        func resolution(_ f: [String: Any]) -> Int? {
            guard let h = f["height"] as? Int else { return nil }
            return (f["width"] as? Int).map { min($0, h) } ?? h
        }
        let bestHeight = video.compactMap(resolution).max()
        let best = video
            .filter { resolution($0) == bestHeight }
            .max { codecRank[family(codec($0["vcodec"])) ?? ""] ?? -1 < codecRank[family(codec($1["vcodec"])) ?? ""] ?? -1 }
        let compatibleHeight = video
            .filter { family(codec($0["vcodec"])) == "avc1" }
            .compactMap(resolution)
            .max()

        // Best audio by bitrate, skipping volume-compressed (DRC) variants.
        let audioOnly = audio.filter { codec($0["vcodec"]) == "none" }
        let audioPool = (audioOnly.isEmpty ? audio : audioOnly).filter {
            !(($0["format_id"] as? String)?.lowercased().contains("drc") ?? false)
        }
        func bitrate(_ f: [String: Any]) -> Double { (f["abr"] as? Double) ?? Double(f["abr"] as? Int ?? 0) }
        let bestAudio = audioPool.max { bitrate($0) < bitrate($1) }
        let bestAAC = audioPool.filter { family(codec($0["acodec"])) == "aac" }.max { bitrate($0) < bitrate($1) }

        var imageURL: URL?
        let isPlaylistShell = (item["_type"] as? String) == "playlist"
        let hasDRM = (item["_has_drm"] as? Bool) == true
        if video.isEmpty, audio.isEmpty, !isPlaylistShell, !hasDRM {   // a protected video isn't an image post
            let images = formats.filter { ["jpg", "jpeg", "png", "webp", "gif"].contains(($0["ext"] as? String)?.lowercased() ?? "") }
            let thumbs = (item["thumbnails"] as? [[String: Any]]) ?? []
            func area(_ t: [String: Any]) -> Int { (t["width"] as? Int ?? 0) * (t["height"] as? Int ?? 0) }
            let pick = images.max { area($0) < area($1) } ?? thumbs.max { area($0) < area($1) }
            imageURL = (pick?["url"] as? String).flatMap(URL.init(string:))
                ?? (item["thumbnail"] as? String).flatMap(URL.init(string:))
        }
        guard !video.isEmpty || !audio.isEmpty || imageURL != nil else { throw LinkError.nothingToDownload }

        let title = (item["title"] as? String) ?? (root["title"] as? String) ?? link.host ?? "Download"
        let uploader = (item["uploader"] as? String) ?? (item["channel"] as? String) ?? (root["uploader"] as? String)
        let duration = (item["duration"] as? Double) ?? (item["duration"] as? Int).map(Double.init)
        let bestAudioBitrate = bestAudio.map(bitrate).flatMap { $0 > 0 ? $0 : nil }
        return Info(link: link, title: title, uploader: uploader, duration: duration,
                    hasVideo: !video.isEmpty, hasAudio: !audio.isEmpty,
                    bestHeight: bestHeight, bestVideoCodec: family(best.flatMap { codec($0["vcodec"]) }),
                    compatibleHeight: compatibleHeight,
                    audioBitrate: bestAudioBitrate, audioCodec: family(bestAudio.flatMap { codec($0["acodec"]) }),
                    aacBitrate: bestAAC.map(bitrate).flatMap { $0 > 0 ? $0 : nil },
                    hasAACStream: bestAAC != nil, imageURL: imageURL, itemCount: itemCount)
    }

    // MARK: - Downloading

    /// yt-dlp arguments for `option`, writing to `template` (a `-o` output
    /// template). Exposed for tests.
    public func arguments(for option: Option, link: URL, template: String, cookies: CookieSource) -> [String] {
        var args = [
            "--ignore-config", "--no-warnings", "--no-playlist", "--playlist-items", "1", "--no-mtime",
            "--quiet", "--progress", "--newline",
            "--progress-template",
            "download:[zest-progress] %(info.format_id)s %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s",
            "--print", "before_dl:[zest-format] %(format_id)s",
            "--print", "after_move:[zest-file] %(filepath)s",
            "-o", template,
        ]
        if let ffmpeg { args += ["--ffmpeg-location", ffmpeg.path] }
        if cookies != .none { args += ["--cookies-from-browser", cookies.rawValue] }
        switch option {
        case .best:
            args += ["-f", "bv*+ba/b", "-S", "res,fps,vcodec:av01,acodec:m4a", "--merge-output-format", "mp4", "--remux-video", "mp4"]
        case .compatible:
            args += ["-f", "bv*+ba/b", "-S", "vcodec:h264,res,fps,acodec:m4a", "--merge-output-format", "mp4", "--remux-video", "mp4"]
        case .m4a:
            args += ["-f", "ba[acodec^=mp4a]/ba/b", "-x", "--audio-format", "m4a", "--audio-quality", "256K"]
        case .mp3:   // from the AAC stream when there is one, as the detail text says
            args += ["-f", "ba[acodec^=mp4a]/ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "320K"]
        case .wav:
            args += ["-f", "ba[acodec^=mp4a]/ba/b", "-x", "--audio-format", "wav"]
        case .image:
            break   // fetched directly, not through yt-dlp
        }
        return args + ["--", link.absoluteString]
    }

    /// Download `info` as `option` into a fresh temporary folder and return
    /// the file. The caller moves it into place (see `place(_:as:in:)`). The
    /// folder is removed on failure or cancellation.
    public func download(_ info: Info, as option: Option, cookies: CookieSource = .none,
                         progress: ProgressHandler? = nil) async throws -> URL {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("zest-dl-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let file = option == .image
                ? try await downloadImage(info, into: folder, progress: progress)
                : try await runYtdlp(info, option: option, into: folder, cookies: cookies, progress: progress)
            progress?(1)
            return file
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    /// Move a downloaded file into `directory` under the title, never
    /// overwriting (`Title.mp4`, `Title (2).mp4`, …), and remove its temp
    /// folder. Works across volumes (external drives, a NAS, a relocated
    /// Downloads). If saving fails, the finished file is kept and its path
    /// is in the error — a download is never thrown away at the last step.
    public static func place(_ file: URL, as info: Info, in directory: URL) throws -> URL {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LinkError.failed("The folder \(directory.path) doesn't exist. The download is kept at \(file.path)")
        }
        let destination = reserveUniqueURL(in: directory, stem: fileStem(for: info), extension: file.pathExtension)
        do {
            try? fm.removeItem(at: destination)            // the empty reservation; moveItem won't overwrite
            try fm.moveItem(at: file, to: destination)     // a rename on one volume, a copy across volumes
        } catch {
            throw LinkError.failed("Couldn't save to \(directory.path) (\(error.localizedDescription)). The download is kept at \(file.path)")
        }
        try? fm.removeItem(at: file.deletingLastPathComponent())
        return destination
    }

    private func runYtdlp(_ info: Info, option: Option, into folder: URL,
                          cookies: CookieSource, progress: ProgressHandler?) async throws -> URL {
        guard let ytdlp else { throw LinkError.toolMissing("yt-dlp") }
        guard ffmpeg != nil else { throw LinkError.toolMissing("ffmpeg") }
        let tracker = ProgressTracker(progress)
        let args = arguments(for: option, link: info.link, template: folder.appendingPathComponent("zest.%(ext)s").path, cookies: cookies)
        let out = try await ProcessRunner.stream(ytdlp, args) { line in tracker.consume(line) }
        try Task.checkCancellation()
        guard out.code == 0 else {
            throw LinkError.from(stderr: out.stderr, platform: info.platform, host: info.link.host, cookies: cookies)
        }
        let printed = out.stdout.components(separatedBy: "\n")
            .compactMap { $0.hasPrefix("[zest-file] ") ? String($0.dropFirst("[zest-file] ".count)) : nil }
            .last
        let file = printed.map { URL(fileURLWithPath: $0) }
            ?? (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
                .first { !$0.lastPathComponent.hasSuffix(".part") }
        guard let file, FileManager.default.fileExists(atPath: file.path) else {
            throw LinkError.failed("yt-dlp finished without saving a file")
        }
        return file
    }

    private func downloadImage(_ info: Info, into folder: URL, progress: ProgressHandler?) async throws -> URL {
        guard let source = info.imageURL else { throw LinkError.nothingToDownload }
        progress?(0.1)
        let (temp, response) = try await URLSession.shared.download(from: source)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temp)
            throw LinkError.unavailable
        }
        // Name it by what arrived, not by the URL (a ".jpg" URL may serve PNG).
        let ext = Self.imageExtension(of: temp)
            ?? response.mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }
            ?? Self.fileExtension(for: .image, info: info)
        let file = folder.appendingPathComponent("zest").appendingPathExtension(ext == "jpeg" ? "jpg" : ext)
        try FileManager.default.moveItem(at: temp, to: file)
        return file
    }

    /// Sniff an image file's real type from its first bytes.
    static func imageExtension(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let b = [UInt8](handle.readData(ofLength: 12))
        guard b.count >= 4 else { return nil }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if b.count >= 12, b.starts(with: [0x52, 0x49, 0x46, 0x46]), Array(b[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        if b.count >= 12, Array(b[4..<8]) == [0x66, 0x74, 0x79, 0x70] {   // "ftyp"
            return ["heic", "heix", "mif1"].contains(String(decoding: b[8..<12], as: UTF8.self)) ? "heic" : nil
        }
        return nil
    }

    /// Parse one `[zest-progress] format done total estimate` line.
    public static func parseProgress(_ line: String) -> (format: String, done: Double, total: Double?)? {
        guard line.hasPrefix("[zest-progress] ") else { return nil }
        let parts = line.dropFirst("[zest-progress] ".count).split(separator: " ").map(String.init)
        guard parts.count >= 2, let done = Double(parts[1]) else { return nil }
        let total = parts.dropFirst(2).lazy.compactMap(Double.init).first { $0 > 0 }
        return (parts[0], done, total)
    }
}

/// Turns yt-dlp's per-stream byte counts into one 0…1 figure across the video
/// and audio streams it fetches separately, leaving the tail for merging.
private final class ProgressTracker: @unchecked Sendable {
    private let report: ProgressHandler?
    private let lock = NSLock()
    private var parts = 1
    /// Streams in the order they started; the current one's index is the part.
    private var formats: [String] = []
    private var reported = 0.0

    init(_ report: ProgressHandler?) { self.report = report }

    func consume(_ line: String) {
        lock.lock()
        if line.hasPrefix("[zest-format] ") {
            parts = max(1, line.split(separator: "+").count)
            lock.unlock()
            return
        }
        guard let (format, done, total) = LinkDownloader.parseProgress(line), let total, total > 0 else { lock.unlock(); return }
        if !formats.contains(format) { formats.append(format) }
        let part = min(formats.firstIndex(of: format) ?? 0, parts - 1)
        let fraction = min(done / total, 1)
        let overall = min((Double(part) + fraction) / Double(parts) * 0.95, 0.95)
        guard overall > reported else { lock.unlock(); return }
        reported = overall
        lock.unlock()
        report?(overall)
    }
}

/// Why a link couldn't be saved, in words a person can act on.
public enum LinkError: Error, Sendable, Equatable, CustomStringConvertible {
    case toolMissing(String)
    case unsupported
    case signInRequired(LinkDownloader.Platform)
    /// Browser sign-in is on, and the site still wants a sign-in.
    case signInStillRequired(LinkDownloader.Platform, LinkDownloader.CookieSource)
    /// Browser sign-in was on but its cookies couldn't be read.
    case cookiesUnreadable
    /// No network, or the site couldn't be reached.
    case offline(host: String)
    case rateLimited(LinkDownloader.Platform)
    case unavailable
    case nothingToDownload
    case failed(String)

    /// Fixed in Settings › Output (browser sign-in).
    public var isSignInProblem: Bool {
        switch self {
        case .signInRequired, .signInStillRequired, .cookiesUnreadable: return true
        default: return false
        }
    }

    public var description: String {
        switch self {
        case .toolMissing("yt-dlp"):
            return "Downloading links needs yt-dlp — install it with Homebrew: brew install yt-dlp"
        case .toolMissing(let tool):
            return "Downloading links needs \(tool) — install it with Homebrew: brew install \(tool)"
        case .unsupported:
            return "Zest can't download from this link"
        case .signInRequired(let platform):
            let site = platform == .other ? "This site" : platform.displayName
            return "\(site) wants you signed in for this one. Turn on browser sign-in in Settings › Output, then try again."
        case .signInStillRequired(let platform, let browser):
            let site = platform == .other ? "This site" : platform.displayName
            return "\(site) still wants a sign-in. Make sure you're signed in to \(site) in \(browser.displayName), then try again."
        case .cookiesUnreadable:
            return "Zest couldn't read your browser sign-in. For Safari, give Zest Full Disk Access; for Chrome-based browsers, allow Keychain access when macOS asks."
        case .offline(let host):
            return "Zest couldn't reach \(host) — check your internet connection, then try again."
        case .rateLimited(let platform):
            let site = platform == .other ? "This site" : platform.displayName
            return "\(site) is limiting requests from this Mac for now — try again in a while."
        case .unavailable:
            return "This post is private, removed, or not available in your region"
        case .nothingToDownload:
            return "There's nothing to download at this link"
        case .failed(let message):
            return message
        }
    }

    /// Classify yt-dlp's error output.
    public static func from(stderr: String, platform: LinkDownloader.Platform, host: String? = nil,
                            cookies: LinkDownloader.CookieSource = .none) -> LinkError {
        let text = stderr.lowercased()
        if text.contains("unsupported url") { return .unsupported }
        if text.contains("cookie"), ["could not", "failed to", "operation not permitted", "permission", "decrypt"].contains(where: text.contains) {
            return .cookiesUnreadable
        }
        let network = ["failed to resolve", "nodename nor servname", "connection refused", "timed out", "network is unreachable",
                       "temporary failure in name resolution", "no route to host", "internet connection appears to be offline"]
        if network.contains(where: text.contains) {
            return .offline(host: host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "the site")
        }
        if ["rate-limited", "rate limit", "too many requests", "http error 429", "try again later"].contains(where: text.contains) {
            return .rateLimited(platform)
        }
        let instagramWall = platform == .instagram && text.contains("requested content is not available")
        if instagramWall || ["login required", "sign in to confirm", "log in", "--cookies"].contains(where: text.contains) {
            return cookies == .none ? .signInRequired(platform) : .signInStillRequired(platform, cookies)
        }
        if text.contains("private") || text.contains("unavailable") || text.contains("not available")
            || text.contains("has been removed") || text.contains("http error 404") || text.contains("does not exist") {
            return .unavailable
        }
        if text.contains("no video formats") || text.contains("there is no video") { return .nothingToDownload }
        let last = stderr.split(separator: "\n").last { $0.contains("ERROR") }
            .map { $0.replacingOccurrences(of: "ERROR: ", with: "").trimmingCharacters(in: .whitespaces) }
        return .failed(last.map { String($0.prefix(200)) } ?? "The download didn't work")
    }
}

/// A parsed `zest://download?url=<link>[&as=best|compatible|m4a|mp3|wav|image]`.
public struct ZestDownloadCommand: Sendable {
    public var link: URL
    /// Download straight away as this option; nil shows the choices.
    public var option: LinkDownloader.Option?

    public init(link: URL, option: LinkDownloader.Option? = nil) {
        self.link = link
        self.option = option
    }
}

public extension ZestURL {
    static func parseDownload(_ url: URL) -> ZestDownloadCommand? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "download",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name.lowercased() == "url" })?.value,
              let link = LinkDownloader.link(from: raw) else { return nil }
        let option = items.first { $0.name.lowercased() == "as" }?.value.flatMap { LinkDownloader.Option(rawValue: $0.lowercased()) }
        return ZestDownloadCommand(link: link, option: option)
    }
}
