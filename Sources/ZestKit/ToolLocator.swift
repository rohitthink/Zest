import Foundation

/// Finds external command-line tools (ffmpeg, cwebp, …) without bundling them.
/// A production build may ship its own signed copies; the scaffold locates a
/// system install so there is nothing to license-wrangle yet.
public enum ToolLocator {
    public static let defaultSearchPaths = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
    ]

    /// Locate an executable by name. An env override `ZEST_<NAME>_PATH`
    /// (e.g. `ZEST_FFMPEG_PATH`) wins over the search paths.
    public static func find(_ name: String, extraPaths: [String] = []) -> URL? {
        let envKey = "ZEST_\(name.uppercased())_PATH"
        if let override = ProcessInfo.processInfo.environment[envKey], !override.isEmpty {
            let u = URL(fileURLWithPath: override)
            if FileManager.default.isExecutableFile(atPath: u.path) { return u }
        }
        for dir in extraPaths + defaultSearchPaths {
            let u = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: u.path) { return u }
        }
        return nil
    }
}
