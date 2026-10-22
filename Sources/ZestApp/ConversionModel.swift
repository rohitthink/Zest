import AppKit
import UniformTypeIdentifiers
import ZestKit

/// Drives every Zest surface: what the drop panel shows, which wheel slice is
/// lit, and the conversion itself. `@MainActor` makes it Sendable, so drag and
/// progress callbacks can hop back to it safely; the engine runs off the main
/// actor (ZestKit's `run` is nonisolated async), keeping the UI responsive.
@MainActor
final class ConversionModel: ObservableObject {

    /// One slice of the wheel.
    struct WheelTarget: Identifiable, Hashable {
        /// The output format (for a download, the file it will produce).
        let format: MediaFormat
        /// "Strip": rewrite in the same format with metadata removed.
        let isStrip: Bool
        /// Set for link downloads: how to save the link, with its wheel label and explanation.
        var download: LinkDownloader.Option? = nil
        var downloadLabel: String? = nil
        var downloadHelp: String? = nil

        var id: String { download.map { "download-\($0.rawValue)" } ?? (isStrip ? "strip" : format.id) }
        var label: String { downloadLabel ?? (isStrip ? "Strip" : format.id.uppercased()) }
        var helpText: String {
            downloadHelp ?? (isStrip ? "Remove location & camera info, keep the format" : "Convert to \(format.id.uppercased())")
        }
    }

    /// The file(s) or link in hand and what they can become.
    struct Batch: Equatable {
        let files: [URL]
        let sources: [MediaFormat]      // parallel to `files`
        let targets: [WheelTarget]      // wheel slices, most useful first (≤ maxSlices)
        let overflow: [WheelTarget]     // further targets, offered from the hub's "More" menu
        let skipped: Int                // dropped files Zest can't read (folders, unknown types)
        /// A web link being downloaded instead of files (then `files` is empty).
        var link: LinkDownloader.Info? = nil

        var isLink: Bool { link != nil }
        var isSingle: Bool { link != nil || files.count == 1 }
        /// Common category of every file, or nil for a mixed batch.
        var category: MediaCategory? {
            if let link {
                if link.hasVideo { return .video }
                return link.hasAudio ? .audio : .image
            }
            let set = Set(sources.map(\.category))
            return set.count == 1 ? set.first : nil
        }
        /// Hub title: the file name, the link's title, or "3 files".
        var title: String {
            if let link { return link.title }
            return files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
        }
        /// Hub subtitle: "HEIC image", "3 images", "Mixed files", "YouTube · 10:35".
        var kind: String {
            if let link {
                let length = link.duration.map(Self.clock).map { " · \($0)" } ?? ""
                return "\(link.platform.displayName)\(length)"
            }
            if files.count == 1 { return Citrus.kindName(for: sources[0]) }
            switch category {
            case .image?: return "\(files.count) images"
            case .audio?: return "\(files.count) audio files"
            case .video?: return "\(files.count) videos"
            case .pdf?, .document?: return "\(files.count) documents"
            case .spreadsheet?: return "\(files.count) spreadsheets"
            default: return "Mixed files"
            }
        }

        /// 635 → "10:35", 3725 → "1:02:05".
        static func clock(_ seconds: Double) -> String {
            let total = Int(seconds.rounded())
            let h = total / 3600, m = total % 3600 / 60, s = total % 60
            return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        }
    }

    /// What a finished run produced.
    struct Summary: Equatable {
        let outputs: [URL]
        let target: WheelTarget
        let inputBytes: Int
        let outputBytes: Int
        let failures: [String]
        /// Files that were already in the target format, left untouched.
        var unchanged: [URL] = []
        /// A link download rather than a conversion (no "smaller" comparison).
        var isDownload = false

        /// Fraction saved versus the inputs (0.62 = 62% smaller); nil if it grew.
        var savedFraction: Double? {
            guard inputBytes > 0, outputBytes < inputBytes else { return nil }
            return Double(inputBytes - outputBytes) / Double(inputBytes)
        }
    }

    enum Phase: Equatable {
        case idle
        /// A drag is hovering the panel: the wheel is shown, nothing dropped yet.
        case previewing(Batch)
        /// Files in hand, waiting for a slice.
        case ready(Batch)
        /// `completed` files done; `fraction` is overall progress 0...1.
        case converting(Batch, target: WheelTarget, completed: Int, fraction: Double)
        case done(Summary)
        case failed(String)
        /// A drag is hovering with files Zest can't take.
        case rejected(String)
        /// A web link is being dragged over the panel; dropping it reads the link.
        case linkHover(URL)
        /// Reading what a link offers (yt-dlp), before the wheel can show.
        case fetching(URL)
    }

    /// Most slices the wheel shows; the rest go to the hub's "More" menu.
    static let maxSlices = 10

    /// Wheel order: most-reached-for formats first.
    private static let rank: [String] = [
        "jpg", "png", "webp", "heic", "pdf", "mp4", "mov", "mp3", "m4a", "wav", "gif", "tiff",
        "docx", "txt", "md", "rtf", "html", "flac", "aac", "aiff", "ogg", "opus", "webm", "mkv",
        "avi", "bmp", "avif", "odt", "doc", "pptx", "ppt", "xlsx", "xls", "ods", "csv", "tsv", "rtfd",
    ]

    @Published private(set) var phase: Phase = .idle
    /// The slice under the pointer (drag or mouse hover), if any.
    @Published private(set) var hoveredSlice: Int?
    /// The last link opened, so a failed read or download can be retried
    /// (say, after turning on browser sign-in). Nil once files take over.
    @Published private(set) var lastLink: URL?
    /// The current failure is a sign-in problem (fixed in Settings › Output).
    @Published private(set) var failureNeedsSettings = false
    /// Outputs being written right now that this run owns — removed if Zest
    /// quits mid-job, so no truncated file is left under a real name.
    private var inFlightOutputs: Set<URL> = []

    let settings: ZestSettings
    let recents: RecentsStore

    private var engine = ConversionEngine.standard()
    private var downloader = LinkDownloader()
    private var generation = 0          // bumped per request; a stale task's result is dropped
    private var task: Task<Void, Never>?
    private var phaseBeforePreview: Phase?

    /// Work handed over while busy (automation, Open With, a drop on the
    /// menu-bar icon). It runs, in order, once the current job settles —
    /// nothing in flight is ever cancelled to make room. Esc clears it.
    enum PendingWork {
        case files([URL])
        case convert(ZestURLCommand)
        case download(ZestDownloadCommand)
    }
    @Published private(set) var pending: [PendingWork] = []

    init(settings: ZestSettings, recents: RecentsStore) {
        self.settings = settings
        self.recents = recents
    }

    // MARK: - Reading state

    /// The batch currently on the wheel, if the wheel is showing.
    var wheelBatch: Batch? {
        switch phase {
        case let .previewing(b), let .ready(b), let .converting(b, _, _, _): return b
        default: return nil
        }
    }

    /// The current failure came from reading or downloading a link (so the
    /// card offers "Try again" for that link). File runs clear `lastLink`.
    var isLinkFailure: Bool {
        if case .failed = phase { return lastLink != nil }
        return false
    }

    /// True while a conversion runs or a link is being read; new work waits.
    var isBusy: Bool {
        switch phase {
        case .converting, .fetching: return true
        default: return false
        }
    }

    /// One-line status for the menu header, with any queued work.
    var statusLine: String {
        pending.isEmpty ? phaseStatus : "\(phaseStatus) · \(pending.count) waiting"
    }

    private var phaseStatus: String {
        switch phase {
        case .fetching:
            return "Reading link…"
        case let .converting(batch, _, completed, _):
            if batch.isLink { return "Downloading…" }
            return batch.isSingle ? "Squeezing…" : "Squeezing \(min(completed + 1, batch.files.count)) of \(batch.files.count)…"
        case let .done(summary) where summary.isDownload:
            return "Downloaded 1 file"
        case let .done(summary):
            return summary.outputs.count == 1 ? "Squeezed 1 file" : "Squeezed \(summary.outputs.count) files"
        case let .ready(batch) where batch.isLink:
            return "Ready to download"
        case .failed:
            return isLinkFailure ? "Last download didn't work" : "Last squeeze didn't work"
        default:
            return "Ready to squeeze"
        }
    }

    // MARK: - Building a batch

    /// Work out what `urls` can become. Unknown files are skipped; fails only
    /// when nothing usable is left or the files share no target.
    func makeBatch(_ urls: [URL]) -> Result<Batch, BatchError> {
        engine = ConversionEngine.standard()   // cheap; picks up tools installed since launch
        var seen = Set<URL>()
        var files: [URL] = [], sources: [MediaFormat] = []
        var unknownExtension: String?
        var sawFolder = false
        for url in urls where seen.insert(url.standardizedFileURL).inserted {
            // An .rtfd document is a package (a folder on disk) but one file to the user.
            let isPackage = url.pathExtension.lowercased() == "rtfd"
            if let format = MediaFormat.fromURL(url), !url.hasDirectoryPath || isPackage {
                files.append(url)
                sources.append(format)
            } else if url.hasDirectoryPath {
                sawFolder = true
            } else if unknownExtension == nil {
                unknownExtension = url.pathExtension
            }
        }
        let skipped = seen.count - files.count
        guard !files.isEmpty else {
            if let ext = unknownExtension, !ext.isEmpty { return .failure(.unsupported(ext)) }
            return .failure(sawFolder ? .folder : .nothingUsable)
        }

        // A target is offered when every file either converts to it or already
        // is it (those are left alone), and at least one file actually changes.
        let distinctSources = Set(sources)
        let convertible = MediaFormat.catalog.filter { target in
            distinctSources.contains { $0 != target }
                && distinctSources.allSatisfy { $0 == target || engine.canConvert(from: $0, to: target) }
        }
        let ranked = convertible.sorted { rankOf($0) < rankOf($1) }.map { WheelTarget(format: $0, isStrip: false) }
        // Strip only where it's lossless (byte-level); elsewhere it would re-encode.
        let canStrip = distinctSources.allSatisfy {
            MetadataStripper.losslessFormatIDs.contains($0.id) && engine.canConvert(from: $0, to: $0)
        }
        let strip = canStrip ? [WheelTarget(format: sources[0], isStrip: true)] : []

        guard !ranked.isEmpty || !strip.isEmpty else {
            if distinctSources.allSatisfy({ DocumentBackend.needsLibreOffice($0.id) }) { return .failure(.needsLibreOffice) }
            return .failure(files.count == 1 ? .noTargets(sources[0].id) : .noCommonTarget)
        }
        let room = Self.maxSlices - strip.count
        let batch = Batch(files: files, sources: sources,
                          targets: Array(ranked.prefix(room)) + strip,
                          overflow: Array(ranked.dropFirst(room)),
                          skipped: skipped)
        return .success(batch)
    }

    enum BatchError: Error, Equatable, CustomStringConvertible {
        case nothingUsable, unsupported(String), noTargets(String), noCommonTarget, folder, needsLibreOffice
        var description: String {
            switch self {
            case .nothingUsable: return "Drop a file to squeeze"
            case .unsupported(let ext): return "Zest can't squeeze .\(ext) files yet"
            case .noTargets(let id): return "No conversions available for .\(id)"
            case .noCommonTarget: return "These files have no format in common"
            case .folder: return "Folders can't be squeezed — drop the files inside"
            case .needsLibreOffice: return "Spreadsheets and slides need LibreOffice — install it, then try again"
            }
        }
    }

    private func rankOf(_ format: MediaFormat) -> Int { Self.rank.firstIndex(of: format.id) ?? Self.rank.count }

    // MARK: - Drag flow (driven by DropController)

    /// A drag entered the panel. Returns true when it can be dropped: usable
    /// files, or a web link (read once it's dropped — too slow to do mid-drag).
    func beginDragPreview(_ urls: [URL]) -> Bool {
        guard !isBusy else { return false }
        switch phase {
        case .previewing, .rejected, .linkHover: break
        default: phaseBeforePreview = phase
        }
        hoveredSlice = nil
        let files = urls.filter(\.isFileURL)
        if files.isEmpty, let link = urls.first(where: LinkDownloader.isWebLink) {
            phase = .linkHover(link)
            return true
        }
        switch makeBatch(files) {
        case .success(let batch):
            phase = .previewing(batch)
            return true
        case .failure(let error):
            phase = .rejected(error.description)
            announce(error.description)
            return false
        }
    }

    /// The drag left without dropping: put back what was there.
    func endDragPreview() {
        switch phase {
        case .previewing, .rejected, .linkHover:
            phase = phaseBeforePreview ?? .idle
        default: break
        }
        phaseBeforePreview = nil
        hoveredSlice = nil
    }

    /// Dropped: convert straight away if released over a slice, otherwise keep
    /// the wheel up for a click.
    func commitDrop() {
        phaseBeforePreview = nil
        if case let .linkHover(link) = phase {
            phase = .idle   // not busy, so openLink proceeds
            openLink(link)
            return
        }
        guard case let .previewing(batch) = phase else { return }
        lastLink = nil
        let released = hoveredSlice.flatMap { batch.targets.indices.contains($0) ? batch.targets[$0] : nil }
        hoveredSlice = nil
        phase = .ready(batch)
        // Start after the drag callback returns: "ask every time" opens a modal
        // save panel, which must not run inside performDragOperation. If it's
        // cancelled, the batch simply stays on the wheel.
        if let released {
            DispatchQueue.main.async { [weak self] in self?.pick(released) }
        }
    }

    /// Light a slice (pointer or drag hover). Ignored unless the wheel is live.
    func hover(_ slice: Int?) {
        guard let batch = wheelBatch, !isBusy else { hoveredSlice = nil; return }
        let valid = slice.flatMap { batch.targets.indices.contains($0) ? $0 : nil }
        if hoveredSlice != valid { hoveredSlice = valid }
    }

    // MARK: - Commands

    /// Files from the open panel, the menu-bar icon, Open With, or `zest://open`.
    /// While busy they wait their turn.
    func accept(_ urls: [URL]) {
        guard !isBusy else { pending.append(.files(urls)); return }
        generation &+= 1
        hoveredSlice = nil
        lastLink = nil
        switch makeBatch(urls) {
        case .success(let batch): phase = .ready(batch)
        case .failure(let error): settle(.failed(error.description))
        }
    }

    /// A web link (pasted, dropped, or `zest://download`): read what it offers,
    /// then show the download choices — or, with `option`, download straight away.
    func openLink(_ link: URL, as option: LinkDownloader.Option? = nil) {
        guard !isBusy else { pending.append(.download(ZestDownloadCommand(link: link, option: option))); return }
        generation &+= 1
        let token = generation
        hoveredSlice = nil
        phaseBeforePreview = nil
        lastLink = link
        downloader = LinkDownloader()          // picks up yt-dlp installed since launch
        let downloader = self.downloader
        let cookies = settings.linkCookies
        phase = .fetching(link)
        task?.cancel()
        task = Task { [weak self] in
            do {
                let info = try await downloader.inspect(link, cookies: cookies)
                guard let self, token == self.generation else { return }
                self.task = nil
                let batch = Self.linkBatch(info)
                guard !batch.targets.isEmpty else {
                    self.settle(.failed(LinkError.nothingToDownload.description))
                    return
                }
                if let option {
                    // Asked for by name (zest://download?as=…): resolve against what
                    // the link can deliver, not the de-duplicated wheel.
                    let target = batch.targets.first(where: { $0.download == option })
                        ?? (LinkDownloader.canDeliver(option, info: info) ? Self.linkTarget(option, info: info) : nil)
                    guard let target else {
                        self.settle(.failed("This link doesn't offer \(LinkDownloader.label(for: option, info: info))"))
                        return
                    }
                    self.phase = .ready(batch)
                    self.start(batch, target: target)
                } else {
                    // The wheel waits for a pick; queued work waits for the wheel.
                    self.phase = .ready(batch)
                    self.announce("\(info.title): \(batch.targets.count) download choices")
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, token == self.generation else { return }
                self.failLink(error)
            }
        }
    }

    /// Wheel slices for a link: one per download option.
    static func linkBatch(_ info: LinkDownloader.Info) -> Batch {
        let targets = LinkDownloader.options(for: info).map { linkTarget($0, info: info) }
        return Batch(files: [], sources: [], targets: targets, overflow: [], skipped: 0, link: info)
    }

    static func linkTarget(_ option: LinkDownloader.Option, info: LinkDownloader.Info) -> WheelTarget {
        let ext = LinkDownloader.fileExtension(for: option, info: info)
        let format = MediaFormat.fromExtension(ext) ?? MediaFormat.fromExtension("mp4")!
        return WheelTarget(format: format, isStrip: false, download: option,
                           downloadLabel: LinkDownloader.label(for: option, info: info),
                           downloadHelp: LinkDownloader.detail(for: option, info: info))
    }

    /// A link read or download failed: show it, noting whether Settings can fix it.
    private func failLink(_ error: Error) {
        failureNeedsSettings = (error as? LinkError)?.isSignInProblem ?? false
        settle(.failed(Self.friendly(error)))
    }

    /// Run a parsed `zest://download?…` command.
    func run(_ command: ZestDownloadCommand) {
        openLink(command.link, as: command.option)
    }

    /// Read the last link again (the Failed card's "Try again").
    func retryLastLink() {
        guard let lastLink else { return }
        phase = .idle
        openLink(lastLink)
    }

    /// A slice was chosen (click, release, or keyboard).
    func pick(_ target: WheelTarget) {
        switch phase {
        case let .ready(batch), let .previewing(batch):
            start(batch, target: target)
        default: break
        }
    }

    /// Keyboard 1–9/0: pick slice `index` (0-based).
    func pick(index: Int) {
        guard let batch = wheelBatch, !isBusy, batch.targets.indices.contains(index) else { return }
        pick(batch.targets[index])
    }

    /// Esc: stop — the current job and anything queued behind it. Returns
    /// false when there was nothing to back out of (the caller then hides the
    /// panel). A file already being written finishes in the background.
    @discardableResult
    func cancel() -> Bool {
        if case .idle = phase, pending.isEmpty { return false }
        pending.removeAll()
        reset()
        return true
    }

    /// Back to the empty drop card (Back, Squeeze another, closing the panel).
    /// Queued work then gets its turn; only Esc (cancel) throws it away.
    func reset() {
        generation &+= 1
        task?.cancel()
        task = nil
        phaseBeforePreview = nil
        hoveredSlice = nil
        failureNeedsSettings = false
        phase = .idle
        runNextPending()
    }

    /// Run a parsed `zest://convert?…` command (URL-scheme automation). Uses
    /// the command's own options, not the Settings defaults. While busy it
    /// waits its turn — it never cancels work in flight.
    func run(_ command: ZestURLCommand) {
        guard !isBusy else { pending.append(.convert(command)); return }
        lastLink = nil
        guard let source = MediaFormat.fromURL(command.input) else {
            settle(.failed("Unsupported input: .\(command.input.pathExtension)"))
            return
        }
        let id = command.targetID
        guard let format = MediaFormat.catalog.first(where: { $0.id == id || $0.fileExtensions.contains(id) }) else {
            settle(.failed("Unknown target format: \(id)"))
            return
        }
        engine = ConversionEngine.standard()
        guard engine.canConvert(from: source, to: format) else {
            settle(.failed("Zest can't turn .\(source.id) into .\(format.id)"))
            return
        }
        let batch = (try? makeBatch([command.input]).get())
            ?? Batch(files: [command.input], sources: [source], targets: [], overflow: [], skipped: 0)
        let plan: OutputPlan = command.output.map { .exact($0) } ?? .beside
        start(batch, target: WheelTarget(format: format, isStrip: false), options: command.options, plan: plan)
    }

    // MARK: - Running

    private enum OutputPlan {
        case beside               // next to each original
        case folder(URL)          // Downloads, or a folder chosen for a batch
        case exact(URL)           // a save-panel choice or an explicit URL-scheme output
    }

    private func start(_ batch: Batch, target: WheelTarget,
                       options explicit: ConversionOptions? = nil, plan explicitPlan: OutputPlan? = nil) {
        guard let plan = explicitPlan ?? outputPlan(for: batch, target: target) else { return }   // user cancelled "ask"
        var options = explicit ?? settings.conversionOptions
        if target.isStrip {
            // Strip is lossless: same pixels, no metadata. Quality or size knobs
            // would push ImageBackend off its byte-preserving path into a re-encode.
            options.stripMetadata = true
            options.quality = nil
            options.maxDimension = nil
        }

        generation &+= 1
        let token = generation
        phaseBeforePreview = nil
        hoveredSlice = nil
        if !batch.isLink { lastLink = nil }   // a file run's failure isn't a download failure
        failureNeedsSettings = false
        phase = .converting(batch, target: target, completed: 0, fraction: 0)
        task?.cancel()

        if let info = batch.link, let option = target.download {
            startDownload(info, option: option, batch: batch, target: target, plan: plan, token: token)
            return
        }

        let engine = self.engine
        // Wheel picks leave files already in the target format alone; an explicit
        // URL command (resize, recompress, target-size) always runs the engine.
        let skipUnchanged = explicit == nil
        task = Task { [weak self] in
            var outputs: [URL] = [], failures: [String] = [], unchanged: [URL] = []
            var inputBytes = 0, outputBytes = 0
            for (index, file) in batch.files.enumerated() {
                if Task.isCancelled { return }
                let source = batch.sources[index]
                let format = target.isStrip ? source : target.format
                if skipUnchanged, !target.isStrip, source == format {
                    unchanged.append(file)
                    self?.progressed(token: token, completed: index + 1, current: 0)
                    continue
                }
                // The engine always writes a file this run owns: the reserved
                // name, or — for an exact path (save panel, URL output=) — a
                // hidden sibling swapped in on success, so a failure can never
                // truncate a file that was already there.
                let destination = Self.outputURL(for: file, format: format, strip: target.isStrip, plan: plan)
                let work: URL
                if case .exact = plan {
                    work = reserveUniqueURL(in: destination.deletingLastPathComponent(),
                                            stem: ".zest-\(UUID().uuidString)", extension: format.primaryExtension)
                } else {
                    work = destination
                }
                self?.inFlightOutputs.insert(work)
                let request = ConversionRequest(input: file, output: work, source: source, target: format, options: options)
                let progress: ProgressHandler = { fraction in
                    Task { @MainActor in self?.progressed(token: token, completed: index, current: fraction) }
                }
                do {
                    var result = try await engine.run(request, progress: progress)
                    if work != destination {
                        if FileManager.default.fileExists(atPath: destination.path) {
                            _ = try FileManager.default.replaceItemAt(destination, withItemAt: work)   // same folder, same volume
                        } else {
                            try FileManager.default.moveItem(at: work, to: destination)
                        }
                        result.output = destination
                    }
                    self?.inFlightOutputs.remove(work)
                    outputs.append(result.output)
                    outputBytes += result.bytes
                    inputBytes += Self.fileSize(file)
                    self?.recents.add(output: result.output, target: format)
                } catch {
                    self?.inFlightOutputs.remove(work)
                    try? FileManager.default.removeItem(at: work)
                    failures.append(batch.isSingle ? Self.friendly(error) : "\(file.lastPathComponent): \(Self.friendly(error))")
                }
                self?.progressed(token: token, completed: index + 1, current: 0)
            }
            guard let self, token == self.generation, !Task.isCancelled else { return }
            self.finish(Summary(outputs: outputs, target: target, inputBytes: inputBytes,
                                outputBytes: outputBytes, failures: failures, unchanged: unchanged))
        }
    }

    /// Download a link, then move the file into place under its title.
    private func startDownload(_ info: LinkDownloader.Info, option: LinkDownloader.Option, batch: Batch,
                               target: WheelTarget, plan: OutputPlan, token: Int) {
        let downloader = self.downloader
        let cookies = settings.linkCookies
        task = Task { [weak self] in
            do {
                let file = try await downloader.download(info, as: option, cookies: cookies) { fraction in
                    Task { @MainActor in self?.progressed(token: token, completed: 0, current: fraction) }
                }
                guard let self, token == self.generation, !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                    return
                }
                // Off the main actor: across volumes this is a full copy.
                let saved = try await Task.detached { try Self.place(file, info: info, plan: plan) }.value
                guard token == self.generation else { return }
                let bytes = Self.fileSize(saved)
                self.recents.add(output: saved, target: MediaFormat.fromExtension(saved.pathExtension) ?? target.format)
                self.finish(Summary(outputs: [saved], target: target, inputBytes: 0, outputBytes: bytes,
                                    failures: [], isDownload: true))
            } catch is CancellationError {
                return
            } catch {
                guard let self, token == self.generation else { return }
                self.failLink(error)
            }
        }
    }

    /// Put a finished download where the destination setting says.
    nonisolated private static func place(_ file: URL, info: LinkDownloader.Info, plan: OutputPlan) throws -> URL {
        switch plan {
        case .exact(let url):
            // A save-panel choice. Replace only the very file the user approved;
            // if the real extension differs (an image turned out PNG), take a
            // fresh name beside it rather than overwrite something unasked.
            let fm = FileManager.default
            let approved = url.pathExtension.lowercased() == file.pathExtension.lowercased()
            let destination = approved
                ? url
                : reserveUniqueURL(in: url.deletingLastPathComponent(),
                                   stem: url.deletingPathExtension().lastPathComponent, extension: file.pathExtension)
            do {
                try? fm.removeItem(at: destination)          // the approved file, or our empty reservation
                try fm.moveItem(at: file, to: destination)   // works across volumes
            } catch {
                throw LinkError.failed("Couldn't save \(destination.lastPathComponent) (\(error.localizedDescription)). The download is kept at \(file.path)")
            }
            try? fm.removeItem(at: file.deletingLastPathComponent())
            return destination
        case .folder(let dir):
            return try LinkDownloader.place(file, as: info, in: dir)
        case .beside:
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
            return try LinkDownloader.place(file, as: info, in: downloads)
        }
    }

    private func progressed(token: Int, completed: Int, current: Double) {
        guard token == generation, case let .converting(batch, target, _, _) = phase else { return }
        let n = Double(max(batch.files.count, 1))
        let overall = min(max((Double(completed) + min(max(current, 0), 1)) / n, 0), 1)
        phase = .converting(batch, target: target, completed: completed, fraction: overall)
    }

    private func finish(_ summary: Summary) {
        guard !summary.outputs.isEmpty else {
            settle(.failed(summary.failures.first ?? "Nothing was squeezed"))
            return
        }
        if settings.playSound { NSSound(named: NSSound.Name("Pop"))?.play() }
        if settings.revealWhenDone { NSWorkspace.shared.activateFileViewerSelecting(summary.outputs) }
        settle(.done(summary))
    }

    /// End a job: show its result, tell VoiceOver, and start anything queued.
    private func settle(_ result: Phase) {
        task = nil
        phase = result
        switch result {
        case .done(let summary):
            let name = summary.outputs.count == 1 ? summary.outputs[0].lastPathComponent : "\(summary.outputs.count) files"
            let verb = summary.isDownload ? "Downloaded" : "Squeezed"
            let saving = summary.savedFraction.map { ", \(Int(($0 * 100).rounded()))% smaller" } ?? ""
            announce("\(verb) \(name)\(saving)")
        case .failed(let message):
            announce("That didn't work: \(message)")
            // Leave a failure up long enough to read before queued work replaces it.
            runNextPending(after: 4)
            return
        default:
            break
        }
        runNextPending()
    }

    /// Start the next queued job when the panel is free: idle or showing a
    /// result, never over a wheel waiting for a pick. Deferred so the result
    /// just shown is published (and, after a failure, readable) first.
    private func runNextPending(after delay: TimeInterval = 0) {
        guard !pending.isEmpty else { return }
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.pending.isEmpty, delay == 0 || token == self.generation else { return }
            switch self.phase {
            case .idle, .done, .failed: break
            default: return
            }
            switch self.pending.removeFirst() {
            case .files(let urls): self.accept(urls)
            case .convert(let command): self.run(command)
            case .download(let command): self.run(command)
            }
        }
    }

    /// Zest is quitting mid-job: remove outputs still being written, so no
    /// truncated file is left under a real name.
    func abandonInFlightOutputs() {
        for url in inFlightOutputs { try? FileManager.default.removeItem(at: url) }
        inFlightOutputs.removeAll()
    }

    /// Speak a result for VoiceOver users (the panel may not have focus).
    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: - Output locations

    /// Resolve the Settings destination. Returns nil if the user cancels "ask".
    private func outputPlan(for batch: Batch, target: WheelTarget) -> OutputPlan? {
        switch settings.destination {
        case .nextToOriginal:
            return .beside
        case .downloads:
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            return downloads.map { .folder($0) } ?? .beside
        case .ask:
            NSApp.activate(ignoringOtherApps: true)
            if let info = batch.link {
                // "Next to the original" has no meaning for a link; ask with a title-based name.
                let panel = NSSavePanel()
                panel.title = "Save Download"
                panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                let ext = target.download.map { LinkDownloader.fileExtension(for: $0, info: info) } ?? target.format.primaryExtension
                panel.nameFieldStringValue = "\(LinkDownloader.fileStem(for: info)).\(ext)"
                // Pin the extension so the panel's "Replace?" check is about the real file.
                if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
                panel.allowsOtherFileTypes = false
                return panel.runModal() == .OK ? panel.url.map { .exact($0) } : nil
            }
            if batch.isSingle {
                let file = batch.files[0]
                let format = target.isStrip ? batch.sources[0] : target.format
                let panel = NSSavePanel()
                panel.title = "Save Squeezed File"
                panel.directoryURL = file.deletingLastPathComponent()
                let stem = file.deletingPathExtension().lastPathComponent + (target.isStrip ? "-clean" : "")
                panel.nameFieldStringValue = "\(stem).\(format.primaryExtension)"
                if let type = UTType(filenameExtension: format.primaryExtension) { panel.allowedContentTypes = [type] }
                return panel.runModal() == .OK ? panel.url.map { .exact($0) } : nil
            }
            let panel = NSOpenPanel()
            panel.title = "Choose Where to Save \(batch.files.count) Files"
            panel.prompt = "Save Here"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.directoryURL = batch.files[0].deletingLastPathComponent()
            return panel.runModal() == .OK ? panel.url.map { .folder($0) } : nil
        }
    }

    /// Reserve the output path right before converting, so a cancelled run
    /// leaves no placeholders behind.
    nonisolated private static func outputURL(for file: URL, format: MediaFormat, strip: Bool, plan: OutputPlan) -> URL {
        switch plan {
        case .beside: return defaultOutputURL(for: file, target: format, suffix: strip ? "clean" : nil)
        case .folder(let dir): return defaultOutputURL(for: file, target: format, in: dir, suffix: strip ? "clean" : nil)
        case .exact(let url): return url
        }
    }

    /// `defaultOutputURL` reserves an empty file; drop it if the conversion failed.
    nonisolated private static func removeEmptyPlaceholder(_ url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
        if size == 0 { try? FileManager.default.removeItem(at: url) }
    }

    nonisolated private static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    nonisolated private static func friendly(_ error: Error) -> String {
        if let error = error as? LinkError { return error.description }
        if let error = error as? ConversionError {
            switch error {
            case .toolNotFound(let name):
                return name.contains("soffice") ? "This needs LibreOffice — install it, then try again"
                                                : "This needs \(name), which isn't installed"
            case .unsupportedPair(let s, let t):
                return "Zest can't turn .\(s.id) into .\(t.id)"
            case .toolFailed(_, let stderr):
                return toolMessage(stderr)
            default:
                return error.description
            }
        }
        return error.localizedDescription
    }

    /// The useful line of a tool's error output, in plain words where we
    /// recognise it — not ffmpeg's banner and stream dump.
    nonisolated static func toolMessage(_ stderr: String) -> String {
        let lines = stderr.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let noise = ["Fontconfig", "Input #", "Output #", "Stream", "Metadata", "Duration", "Press [q]", "size=", "frame=",
                     "built with", "configuration:", "lib", "ffmpeg version", "Side data", "encoder", "handler_name",
                     // ffmpeg 7's generic teardown lines, which follow the real cause
                     "Task finished with error code", "Terminating thread", "Error sending frames", "Could not open encoder before EOF",
                     "Error opening output file", "Nothing was written", "Conversion failed", "Exiting normally"]
        let meaningful = lines.filter { line in !noise.contains { line.hasPrefix($0) } }
        let lower = stderr.lowercased()
        if lower.contains("bit rate") && lower.contains("unsupported") { return "That bitrate isn't supported for this format — try a lower quality" }
        if lower.contains("no export filter") { return "LibreOffice can't save this document in that format" }
        if lower.contains("encoder not found") || lower.contains("unknown encoder") { return "The installed ffmpeg can't write this format" }
        if lower.contains("invalid data found") { return "The file looks damaged or isn't really this format" }
        if lower.contains("does not contain any stream") || lower.contains("output file does not contain") {
            return "There's no sound or picture in this file to convert"
        }
        if lower.contains("not divisible by 2") { return "This video's size isn't supported — try setting Longest side in Settings" }
        let pick = meaningful.last { $0.localizedCaseInsensitiveContains("error") } ?? meaningful.last ?? "The conversion tool failed"
        return String(pick.prefix(200))
    }

    // MARK: - Snapshots

    /// Force a phase for the `--snapshot` renderer. Not used by the app itself.
    func setPhaseForSnapshot(_ phase: Phase, hovered: Int? = nil, lastLink: URL? = nil, needsSettings: Bool = false) {
        reset()
        self.phase = phase
        hoveredSlice = hovered
        self.lastLink = lastLink
        failureNeedsSettings = needsSettings
    }
}
