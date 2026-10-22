import Foundation

/// Broad kind of file a format belongs to. Backends advertise which categories
/// they can read and write.
public enum MediaCategory: String, Sendable, CaseIterable {
    case image, video, audio, document, spreadsheet, subtitle, archive, pdf
}

/// A file format Zest knows how to name and route. Identified by a short token
/// (`mp4`), the category it belongs to, the extensions that map to it, and an
/// optional Uniform Type Identifier.
public struct MediaFormat: Sendable, Hashable, CustomStringConvertible {
    public let id: String
    public let category: MediaCategory
    public let fileExtensions: [String]
    public let uti: String?

    public init(id: String, category: MediaCategory, fileExtensions: [String], uti: String? = nil) {
        self.id = id
        self.category = category
        self.fileExtensions = fileExtensions
        self.uti = uti
    }

    public var primaryExtension: String { fileExtensions.first ?? id }
    public var description: String { id }

    /// Resolve a known format from a file extension (case-insensitive).
    public static func fromExtension(_ ext: String) -> MediaFormat? {
        let e = ext.lowercased()
        return catalog.first { $0.fileExtensions.contains(e) }
    }

    /// Resolve a known format from a file URL's extension.
    public static func fromURL(_ url: URL) -> MediaFormat? {
        fromExtension(url.pathExtension)
    }

    /// Starter catalog. It intentionally overlaps the subject app's observed
    /// input/output set, but is maintained independently and extended freely —
    /// no catalog data was copied from any other application.
    public static let catalog: [MediaFormat] = [
        // Images
        MediaFormat(id: "jpg",  category: .image, fileExtensions: ["jpg", "jpeg"], uti: "public.jpeg"),
        MediaFormat(id: "png",  category: .image, fileExtensions: ["png"], uti: "public.png"),
        MediaFormat(id: "webp", category: .image, fileExtensions: ["webp"], uti: "org.webmproject.webp"),
        MediaFormat(id: "heic", category: .image, fileExtensions: ["heic"], uti: "public.heic"),
        MediaFormat(id: "tiff", category: .image, fileExtensions: ["tiff", "tif"], uti: "public.tiff"),
        MediaFormat(id: "avif", category: .image, fileExtensions: ["avif"]),
        MediaFormat(id: "bmp",  category: .image, fileExtensions: ["bmp"], uti: "com.microsoft.bmp"),
        MediaFormat(id: "gif",  category: .image, fileExtensions: ["gif"], uti: "com.compuserve.gif"),
        // Audio
        MediaFormat(id: "mp3",  category: .audio, fileExtensions: ["mp3"], uti: "public.mp3"),
        MediaFormat(id: "m4a",  category: .audio, fileExtensions: ["m4a"], uti: "public.mpeg-4-audio"),
        MediaFormat(id: "wav",  category: .audio, fileExtensions: ["wav"], uti: "com.microsoft.waveform-audio"),
        MediaFormat(id: "flac", category: .audio, fileExtensions: ["flac"]),
        MediaFormat(id: "aac",  category: .audio, fileExtensions: ["aac"]),
        MediaFormat(id: "aiff", category: .audio, fileExtensions: ["aiff", "aif"], uti: "public.aiff-audio"),
        MediaFormat(id: "ogg",  category: .audio, fileExtensions: ["ogg", "oga"]),
        MediaFormat(id: "opus", category: .audio, fileExtensions: ["opus"]),
        // Video
        MediaFormat(id: "mp4",  category: .video, fileExtensions: ["mp4", "m4v"], uti: "public.mpeg-4"),
        MediaFormat(id: "mov",  category: .video, fileExtensions: ["mov"], uti: "com.apple.quicktime-movie"),
        MediaFormat(id: "mkv",  category: .video, fileExtensions: ["mkv"]),
        MediaFormat(id: "webm", category: .video, fileExtensions: ["webm"]),
        MediaFormat(id: "avi",  category: .video, fileExtensions: ["avi"]),
    ]
}
