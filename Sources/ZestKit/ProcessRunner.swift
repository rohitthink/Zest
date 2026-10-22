import Foundation

/// Stop every external tool Zest started (ffmpeg, soffice, yt-dlp…) — call
/// when the app quits so none is left running on its own.
public func terminateRunningTools() {
    ProcessRegistry.shared.terminateAll()
}

/// The tools currently running, so they can be stopped on quit.
final class ProcessRegistry: @unchecked Sendable {
    static let shared = ProcessRegistry()
    private let lock = NSLock()
    private var running: [ObjectIdentifier: Process] = [:]

    func add(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        running[ObjectIdentifier(process)] = process
    }

    func remove(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        running[ObjectIdentifier(process)] = nil
    }

    func terminateAll() {
        lock.lock()
        let processes = Array(running.values)
        running.removeAll()
        lock.unlock()
        for process in processes where process.isRunning { process.terminate() }
    }
}

/// Runs an external tool to completion, capturing stdout/stderr through temp
/// files to avoid pipe-buffer deadlocks with chatty tools like ffmpeg.
enum ProcessRunner {
    /// The environment tools run with: ours, with Homebrew's folders on PATH.
    /// An app launched from Finder inherits launchd's bare PATH, so yt-dlp
    /// wouldn't find helpers it looks up there (deno for YouTube, ffprobe).
    static let toolEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let current = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (current + ToolLocator.defaultSearchPaths.filter { !current.contains($0) }).joined(separator: ":")
        return env
    }()

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
        process.environment = toolEnvironment
        process.standardOutput = outHandle
        process.standardError = errHandle
        // Wait on the termination handler, not waitUntilExit(): the latter
        // spins the calling thread's run loop and can miss the exit when that
        // thread (a Swift concurrency or GCD worker) has no live run loop.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            try? outHandle.close()
            try? errHandle.close()
            throw ConversionError.io("failed to launch \(executable.lastPathComponent): \(error.localizedDescription)")
        }
        ProcessRegistry.shared.add(process)
        exited.wait()
        ProcessRegistry.shared.remove(process)
        try? outHandle.close()
        try? errHandle.close()

        let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return Output(code: process.terminationStatus, stdout: out, stderr: err)
    }

    /// Run a tool, handing each stdout line to `onLine` as it arrives (for
    /// progress). Cancelling the task interrupts the tool (SIGINT, then
    /// SIGTERM after two seconds) so it can clean up its partial files.
    static func stream(_ executable: URL, _ arguments: [String],
                       onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Output {
        let fm = FileManager.default
        let errURL = fm.temporaryDirectory.appendingPathComponent("zest-err-\(UUID().uuidString)")
        fm.createFile(atPath: errURL.path, contents: nil)
        guard let errHandle = try? FileHandle(forWritingTo: errURL) else {
            throw ConversionError.io("could not open capture file")
        }
        let box = ProcessBox()
        let process = box.process
        process.executableURL = executable
        process.arguments = arguments
        process.environment = toolEnvironment
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errHandle
        let lines = LineCollector(onLine)
        let exited = DispatchSemaphore(value: 0)   // see run(): never waitUntilExit() off the launching thread
        process.terminationHandler = { _ in exited.signal() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                if Task.isCancelled {
                    try? errHandle.close()
                    try? fm.removeItem(at: errURL)
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    try box.launch()
                } catch {
                    try? errHandle.close()
                    try? fm.removeItem(at: errURL)
                    continuation.resume(throwing: ConversionError.io("failed to launch \(executable.lastPathComponent): \(error.localizedDescription)"))
                    return
                }
                // Read on a background thread until EOF, then reap the process.
                DispatchQueue.global(qos: .userInitiated).async {
                    let handle = outPipe.fileHandleForReading
                    while true {
                        let data = handle.availableData
                        if data.isEmpty { break }
                        lines.feed(data)
                    }
                    lines.finish()
                    exited.wait()
                    ProcessRegistry.shared.remove(box.process)
                    try? errHandle.close()
                    let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
                    try? FileManager.default.removeItem(at: errURL)
                    continuation.resume(returning: Output(code: box.process.terminationStatus, stdout: lines.text, stderr: err))
                }
            }
        } onCancel: {
            box.stop()
        }
    }
}

/// Holds a `Process` so it can cross into the cancellation handler, and makes
/// launch/stop race-free (a stop before launch prevents the launch).
private final class ProcessBox: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var stopped = false

    func launch() throws {
        lock.lock(); defer { lock.unlock() }
        if stopped { throw CancellationError() }
        try process.run()
        ProcessRegistry.shared.add(process)
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        guard process.isRunning else { return }
        process.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { process.terminate() }
        }
    }
}

/// Splits streamed stdout into lines, forwarding each, and keeps the full text.
private final class LineCollector: @unchecked Sendable {
    private let onLine: @Sendable (String) -> Void
    private let lock = NSLock()
    private var pending = Data()
    private var all = Data()

    init(_ onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: all, as: UTF8.self)
    }

    func feed(_ data: Data) {
        var complete: [String] = []
        lock.lock()
        all.append(data)
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            complete.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        lock.unlock()
        complete.forEach(onLine)
    }

    func finish() {
        lock.lock()
        let rest = pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        lock.unlock()
        if let rest { onLine(rest) }
    }
}
