import SwiftUI
import ZestKit

/// `ZestApp --selftest`: dependency-free checks for the app layer (wheel
/// geometry and batch building), in the same spirit as `zest selftest`. The
/// drag hit-test and the wheel drawing share `WheelGeometry`, so these checks
/// guard "what you see is what a drop hits".
@MainActor
enum AppSelfTest {
    static func run() -> (passed: Int, failed: Int, log: [String]) {
        var passed = 0, failed = 0
        var log: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1; log.append("  ok   \(name)") }
            else { failed += 1; log.append("  FAIL \(name)") }
        }

        // WheelGeometry — slice 0 at 12 o'clock, clockwise.
        let g8 = WheelGeometry(count: 8, diameter: 500)
        let c = g8.center
        check("top of the ring is slice 0", g8.slice(at: CGPoint(x: c.x, y: c.y - 150)) == 0)
        check("3 o'clock is slice 2 of 8", g8.slice(at: CGPoint(x: c.x + 150, y: c.y)) == 2)
        check("6 o'clock is slice 4 of 8", g8.slice(at: CGPoint(x: c.x, y: c.y + 150)) == 4)
        check("9 o'clock is slice 6 of 8", g8.slice(at: CGPoint(x: c.x - 150, y: c.y)) == 6)
        check("the hub is not a slice", g8.slice(at: c) == nil)
        check("far outside the peel is not a slice", g8.slice(at: CGPoint(x: c.x, y: c.y - 400)) == nil)
        let justPast = Angle.degrees(-90 + 22.5 + 1).radians
        check("just clockwise of slice 0's edge is slice 1",
              g8.slice(at: CGPoint(x: c.x + 150 * cos(justPast), y: c.y + 150 * sin(justPast))) == 1)
        let justBefore = Angle.degrees(-90 - 22.5 + 1).radians
        check("just inside slice 0's leading edge is slice 0",
              g8.slice(at: CGPoint(x: c.x + 150 * cos(justBefore), y: c.y + 150 * sin(justBefore))) == 0)
        check("slice span excludes the pith gap",
              abs(g8.angles(0).end.degrees - g8.angles(0).start.degrees - 40) < 0.001)
        check("label of slice 0 sits above the centre", g8.labelCenter(0).y < c.y && abs(g8.labelCenter(0).x - c.x) < 0.001)
        let g1 = WheelGeometry(count: 1, diameter: 500)
        check("a single slice owns the whole ring", g1.slice(at: CGPoint(x: c.x + 150, y: c.y)) == 0)
        check("a single slice has no pith gap", g1.gap.degrees == 0)
        check("panel wheel frame is centred on the wheel",
              PanelLayout.wheelFrame.midX == PanelLayout.wheelCenter.x && PanelLayout.wheelFrame.midY == PanelLayout.wheelCenter.y)

        // ConversionModel.makeBatch — what a drop offers.
        let suite = "app.zest.selftest"
        UserDefaults().removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let model = ConversionModel(settings: ZestSettings(defaults: defaults), recents: RecentsStore(defaults: defaults))
        let dir = URL(fileURLWithPath: "/tmp/zest-selftest")
        let heic = dir.appendingPathComponent("IMG.heic")

        if case .success(let batch) = model.makeBatch([heic]) {
            check("heic offers Strip as the last slice", batch.targets.last?.isStrip == true)
            check("heic never offers itself", !batch.targets.contains { !$0.isStrip && $0.format.id == "heic" })
            check("heic puts jpg first", batch.targets.first?.format.id == "jpg")
            check("wheel never exceeds maxSlices", batch.targets.count <= ConversionModel.maxSlices)
            check("single batch title is the file name", batch.title == "IMG.heic")
        } else {
            check("heic makes a batch", false)
        }
        if case .success(let batch) = model.makeBatch([heic, heic]) {
            check("duplicate drops are merged", batch.files.count == 1)
        } else {
            check("duplicate drop makes a batch", false)
        }
        if case .success(let batch) = model.makeBatch([dir.appendingPathComponent("a.jpg"), dir.appendingPathComponent("b.png")]) {
            let ids = Set(batch.targets.filter { !$0.isStrip }.map(\.format.id))
            check("a jpg + png batch can become either source format", ids.isSuperset(of: ["jpg", "png"]))
            check("batch of images is described as images", batch.kind == "2 images")
        } else {
            check("jpg + png makes a batch", false)
        }
        check("unknown types are rejected by extension",
              model.makeBatch([dir.appendingPathComponent("design.sketch")]) == .failure(.unsupported("sketch")))
        check("image + audio share no target",
              model.makeBatch([heic, dir.appendingPathComponent("a.mp3")]) == .failure(.noCommonTarget))
        if case .success(let batch) = model.makeBatch([heic, dir.appendingPathComponent("notes.sketch")]) {
            check("unknown files in a batch are skipped, not fatal", batch.files.count == 1 && batch.skipped == 1)
        } else {
            check("mixed known/unknown drop makes a batch", false)
        }

        // Document routing stays within a LibreOffice family.
        if case .success(let batch) = model.makeBatch([dir.appendingPathComponent("report.docx")]) {
            let ids = Set(batch.targets.map(\.format.id) + batch.overflow.map(\.format.id))
            check("a Word file never offers spreadsheet or slide formats", ids.isDisjoint(with: ["xlsx", "xls", "ods", "csv", "tsv", "pptx", "ppt"]))
            check("a Word file offers PDF", ids.contains("pdf"))
        } else {
            check("docx makes a batch", false)
        }

        // Links: wheel slices, hub text, and drag routing.
        let link = URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ")!
        let info = LinkDownloader.Info(link: link, title: "Big Buck Bunny", duration: 635, hasVideo: true, hasAudio: true,
                                       bestHeight: 2160, bestVideoCodec: "av01", compatibleHeight: 1080,
                                       audioBitrate: 129.5, audioCodec: "aac")
        let linkBatch = ConversionModel.linkBatch(info)
        check("link wheel offers best, compatible, m4a, mp3, wav",
              linkBatch.targets.map(\.id) == ["download-best", "download-compatible", "download-m4a", "download-mp3", "download-wav"])
        check("link slices are labelled by resolution", linkBatch.targets.prefix(2).map(\.label) == ["MP4 4K", "MP4 1080p"])
        check("link slices produce the right formats", linkBatch.targets.map(\.format.id) == ["mp4", "mp4", "m4a", "mp3", "wav"])
        check("link hub shows title and platform · length", linkBatch.title == "Big Buck Bunny" && linkBatch.kind == "YouTube · 10:35")
        check("link batch is a single video", linkBatch.isSingle && linkBatch.category == .video)
        check("long durations show hours", ConversionModel.Batch.clock(3725) == "1:02:05")
        check("dragging a web link is accepted", model.beginDragPreview([link]) && model.phase == .linkHover(link))
        model.endDragPreview()
        check("leaving with a link restores the panel", model.phase == .idle)
        _ = model.beginDragPreview([link, heic])
        if case .previewing = model.phase { check("files win over a link in the same drag", true) }
        else { check("files win over a link in the same drag", false) }
        model.endDragPreview()

        // Review fixes: lossless-only Strip, folders, LibreOffice hint, tool errors, queueing.
        if case .success(let batch) = model.makeBatch([dir.appendingPathComponent("anim.gif")]) {
            check("Strip isn't offered where it would re-encode (GIF)", !batch.targets.contains(where: \.isStrip))
        } else { check("gif makes a batch", false) }
        check("a dropped folder is explained",
              model.makeBatch([URL(fileURLWithPath: "/tmp/zest-selftest-folder/", isDirectory: true)]) == .failure(.folder))
        if case .success(let batch) = model.makeBatch([URL(fileURLWithPath: "/tmp/notes.rtfd/", isDirectory: true)]) {
            check("an .rtfd package counts as one file", batch.files.count == 1)
        } else { check("an .rtfd package counts as one file", false) }
        let ffmpegNoise = """
        ffmpeg version 7.1 Copyright (c) 2000-2024
          libavutil      59. 39.100
        Input #0, mp3, from 'a.mp3':
          Duration: 00:00:03.00, start: 0.000000, bitrate: 128 kb/s
        [libopus @ 0x1] The bit rate 275000 bps is unsupported. Please choose a value between 6000 and 256000.
        Error while opening encoder - maybe incorrect parameters such as bit_rate, rate, width or height
        """
        check("tool errors become plain words", ConversionModel.toolMessage(ffmpegNoise).hasPrefix("That bitrate isn't supported"))
        check("unknown tool errors keep the error line",
              ConversionModel.toolMessage("Input #0\nsomething broke\nError: disk full") == "Error: disk full")
        let queued = ZestURL.parse(URL(string: "zest://convert?input=/tmp/a.png&to=jpg")!)!
        if case .success(let batch) = model.makeBatch([heic]), let jpg = batch.targets.first {
            model.setPhaseForSnapshot(.converting(batch, target: jpg, completed: 0, fraction: 0.3))
            model.run(queued)
            check("a URL command while busy waits instead of cancelling", model.pending.count == 1 && model.isBusy)
            check("waiting work shows in the status line", model.statusLine.hasSuffix("· 1 waiting"))
            model.cancel()
            check("Esc clears waiting work", model.pending.isEmpty)
        }

        // Summary arithmetic.
        let jpg = ConversionModel.WheelTarget(format: MediaFormat.fromExtension("jpg")!, isStrip: false)
        let smaller = ConversionModel.Summary(outputs: [heic], target: jpg, inputBytes: 1000, outputBytes: 380, failures: [])
        let bigger = ConversionModel.Summary(outputs: [heic], target: jpg, inputBytes: 1000, outputBytes: 1200, failures: [])
        check("savings are reported as a fraction", abs((smaller.savedFraction ?? 0) - 0.62) < 0.0001)
        check("growth reports no savings", bigger.savedFraction == nil)

        UserDefaults().removePersistentDomain(forName: suite)
        return (passed, failed, log)
    }
}

extension Result where Success == ConversionModel.Batch, Failure == ConversionModel.BatchError {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.success(a), .success(b)): return a == b
        case let (.failure(a), .failure(b)): return a == b
        default: return false
        }
    }
}
