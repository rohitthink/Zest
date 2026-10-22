import Foundation

/// Runs an external tool to completion, capturing stdout/stderr through temp
/// files to avoid pipe-buffer deadlocks with chatty tools like ffmpeg.
enum ProcessRunner {
    struct Output: Sendable {
        var code: Int32
        var stdout: String
        var stderr: String
    }

    static func run(_ executable: URL, _ arguments: [String]) throws -> Output {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let outURL = tmp.appendingPathComponent("zest-out-\(UUID().uuidString)")
        let errURL = tmp.appendingPathComponent("zest-err-\(UUID().uuidString)")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? fm.removeItem(at: outURL)
            try? fm.removeItem(at: errURL)
        }

        guard let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL) else {
            throw ConversionError.io("could not open capture files")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = outHandle
        process.standardError = errHandle

        do {
            try process.run()
        } catch {
            try? outHandle.close()
            try? errHandle.close()
            throw ConversionError.io("failed to launch \(executable.lastPathComponent): \(error.localizedDescription)")
        }
        process.waitUntilExit()
        try? outHandle.close()
        try? errHandle.close()

        let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return Output(code: process.terminationStatus, stdout: out, stderr: err)
    }
}
