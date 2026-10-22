import Foundation

/// Converts audio and video by orchestrating a system `ffmpeg` binary over a
/// `Process`. Clean-room: this calls the stock, upstream ffmpeg CLI — no code,
/// build, or data from any other application is used. A production build would
/// link ffmpeg's LGPL libraries (or ship its own signed `ffmpeg`) and carry the
/// required notices and source offer; see README "Licensing".
public struct FFmpegBackend: Converter {
    public let identifier = "ffmpeg"
    public let ffmpeg: URL
    public let ffprobe: URL?

    public init(ffmpeg: URL? = nil, ffprobe: URL? = nil) throws {
        guard let f = ffmpeg ?? ToolLocator.find("ffmpeg") else {
            throw ConversionError.toolNotFound("ffmpeg")
        }
        self.ffmpeg = f
        self.ffprobe = ffprobe ?? ToolLocator.find("ffprobe")
    }

    public func supports(from source: MediaFormat, to target: MediaFormat) -> Bool {
        let av: Set<MediaCategory> = [.audio, .video]
        guard av.contains(source.category), av.contains(target.category) else { return false }
        // Audio -> video needs a visual source; a fuller build handles it via a
        // waveform/visualizer path. Not in this scaffold.
        return !(source.category == .audio && target.category == .video)
    }

    public func convert(_ request: ConversionRequest, progress: ProgressHandler?) async throws -> ConversionResult {
        let start = Date()
        if let target = request.options.targetSizeBytes {
            return try targetSizeEncode(request, targetBytes: target, start: start, progress: progress)
        }
        progress?(0.1)
        let out = try ProcessRunner.run(ffmpeg, baseArgs(for: request, bitrateKbps: nil))
        guard out.code == 0 else { throw ConversionError.toolFailed(code: out.code, stderr: out.stderr) }
        progress?(1.0)
        return ConversionResult(output: request.output, bytes: fileSize(request.output), elapsed: Date().timeIntervalSince(start))
    }

    // MARK: - Argument building

    private func baseArgs(for request: ConversionRequest, bitrateKbps: Int?) -> [String] {
        var args = ["-hide_banner", "-y", "-i", request.input.path]

        if request.options.stripMetadata {
            args += ["-map_metadata", "-1"]
        }

        switch request.target.category {
        case .audio:
            args += audioCodecArgs(for: request.target)
            if let kbps = bitrateKbps {
                args += ["-b:a", "\(kbps)k"]
            } else if let q = request.options.quality {
                let kbps = Int(96 + q * (320 - 96))
                args += ["-b:a", "\(kbps)k"]
            }
        case .video:
            if let maxDim = request.options.maxDimension {
                args += ["-vf", "scale='min(\(maxDim),iw)':'min(\(maxDim),ih)':force_original_aspect_ratio=decrease"]
            }
            if let kbps = bitrateKbps {
                args += ["-b:v", "\(kbps)k", "-maxrate", "\(kbps)k", "-bufsize", "\(kbps * 2)k"]
            } else if let q = request.options.quality {
                let crf = Int(32 - q * (32 - 18))   // lower CRF = better quality
                args += ["-crf", "\(crf)"]
            }
            args += videoCodecArgs(for: request.target)
        default:
            break
        }

        args.append(request.output.path)
        return args
    }

    private func audioCodecArgs(for format: MediaFormat) -> [String] {
        switch format.id {
        case "mp3":          return ["-c:a", "libmp3lame"]
        case "m4a", "aac":   return ["-c:a", "aac"]
        case "flac":         return ["-c:a", "flac"]
        case "wav":          return ["-c:a", "pcm_s16le"]
        case "opus", "ogg":  return ["-c:a", "libopus"]
        default:             return []
        }
    }

    private func videoCodecArgs(for format: MediaFormat) -> [String] {
        switch format.id {
        case "webm": return ["-c:v", "libvpx-vp9", "-c:a", "libopus"]
        default:     return ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]
        }
    }

    // MARK: - Target-size compression (the differentiator)

    /// Binary-search the bitrate so the output lands within tolerance of a byte
    /// budget — the feature the subject app gates behind its paywall. Zest ships
    /// it with no metering.
    private func targetSizeEncode(_ request: ConversionRequest, targetBytes: Int, start: Date, progress: ProgressHandler?) throws -> ConversionResult {
        guard let duration = probeDurationSeconds(request.input), duration > 0 else {
            throw ConversionError.io("could not read media duration for target-size encode")
        }
        // Total kbps budget = bits / seconds / 1000, with ~6% headroom for container overhead.
        let budget = Double(targetBytes) * 8.0 / duration / 1000.0 * 0.94
        var low = 8.0
        var high = max(budget, 16.0)
        var best: (bytes: Int, kbps: Int)?
        let tolerance = 0.06
        let maxAttempts = 6

        for attempt in 1...maxAttempts {
            let kbps = max(1, Int((low + high) / 2.0))
            progress?(Double(attempt) / Double(maxAttempts))
            let out = try ProcessRunner.run(ffmpeg, baseArgs(for: request, bitrateKbps: kbps))
            guard out.code == 0 else { throw ConversionError.toolFailed(code: out.code, stderr: out.stderr) }
            let bytes = fileSize(request.output)
            if best == nil || abs(bytes - targetBytes) < abs(best!.bytes - targetBytes) {
                best = (bytes, kbps)
            }
            let ratio = Double(bytes) / Double(targetBytes)
            if abs(1.0 - ratio) <= tolerance {
                return ConversionResult(output: request.output, bytes: bytes, elapsed: Date().timeIntervalSince(start), attempts: attempt)
            }
            if bytes > targetBytes { high = Double(kbps) } else { low = Double(kbps) }
        }

        // Settle on the closest-under bitrate found.
        if let best {
            _ = try ProcessRunner.run(ffmpeg, baseArgs(for: request, bitrateKbps: best.kbps))
            let bytes = fileSize(request.output)
            if bytes > targetBytes {
                throw ConversionError.targetUnreachable(smallestBytes: bytes, targetBytes: targetBytes)
            }
            return ConversionResult(output: request.output, bytes: bytes, elapsed: Date().timeIntervalSince(start), attempts: maxAttempts)
        }
        throw ConversionError.targetUnreachable(smallestBytes: fileSize(request.output), targetBytes: targetBytes)
    }

    // MARK: - Helpers

    private func probeDurationSeconds(_ url: URL) -> Double? {
        if let ffprobe,
           let out = try? ProcessRunner.run(ffprobe, [
               "-v", "error", "-show_entries", "format=duration",
               "-of", "default=noprint_wrappers=1:nokey=1", url.path]),
           out.code == 0,
           let d = Double(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return d
        }
        // Fallback: parse `Duration: HH:MM:SS.ss` from `ffmpeg -i` stderr.
        if let out = try? ProcessRunner.run(ffmpeg, ["-hide_banner", "-i", url.path]) {
            return Self.parseDuration(from: out.stderr)
        }
        return nil
    }

    /// Parse ffmpeg's `Duration: HH:MM:SS.ss` field into seconds. Internal for tests.
    static func parseDuration(from stderr: String) -> Double? {
        guard let range = stderr.range(of: "Duration: ") else { return nil }
        let token = stderr[range.upperBound...].prefix(11)   // HH:MM:SS.ss
        let parts = token.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]),
              let m = Double(parts[1]),
              let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    private func fileSize(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int) ?? 0
    }
}
