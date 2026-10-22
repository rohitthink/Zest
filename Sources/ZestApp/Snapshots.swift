import AppKit
import SwiftUI
import ZestKit

/// `ZestApp --snapshot <dir>` renders every surface in every state, light and
/// dark, to PNGs (design review, docs and store screenshots), then exits.
/// Sample files are fictitious paths; only their extensions matter.
@MainActor
enum SnapshotRunner {

    static func run(outputDirectory: URL) {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let suite = "app.zest.snapshots"
        UserDefaults().removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let settings = ZestSettings(defaults: defaults)
        let recents = RecentsStore(defaults: defaults)
        let home = URL(fileURLWithPath: "/Users/you")
        recents.add(output: home.appendingPathComponent("Documents/report.pdf"), target: format("pdf"))
        recents.add(output: home.appendingPathComponent("Music/voice.mp3"), target: format("mp3"))
        recents.add(output: home.appendingPathComponent("Pictures/photo.jpg"), target: format("jpg"))

        let model = ConversionModel(settings: settings, recents: recents)
        let dropActions = DropActions(close: {}, chooseFile: {}, openSettings: {})
        let menuActions = MenuActions(convertFile: {}, downloadLink: { _ in }, showDropZone: {}, openSettings: {}, quit: {})

        let heic = home.appendingPathComponent("Pictures/IMG_2041.heic")
        let images = ["Pictures/beach.jpg", "Pictures/receipt.png", "Pictures/IMG_2041.heic"].map { home.appendingPathComponent($0) }
        let audio = home.appendingPathComponent("Music/voice memo.m4a")
        let doc = home.appendingPathComponent("Documents/report.docx")
        func batch(_ urls: [URL]) -> ConversionModel.Batch? { try? model.makeBatch(urls).get() }

        var dropStates: [(String, ConversionModel.Phase, Int?, URL?)] = [
            ("drop-idle", .idle, nil, nil),
            ("drop-rejected", .rejected("Zest can't squeeze .sketch files yet"), nil, nil),
            ("drop-failed", .failed("Zest can't turn .heic into .mp3"), nil, nil),
        ]
        if let b = batch([heic]) {
            dropStates.append(("wheel-image", .ready(b), nil, nil))
            dropStates.append(("wheel-image-hover", .previewing(b), 1, nil))
            if let jpg = b.targets.first {
                let summary = ConversionModel.Summary(
                    outputs: [heic.deletingPathExtension().appendingPathExtension("jpg")], target: jpg,
                    inputBytes: 3_400_000, outputBytes: 1_290_000, failures: [])
                dropStates.append(("done-single", .done(summary), nil, nil))
            }
        }
        if let b = batch(images), let png = b.targets.first(where: { $0.id == "png" }) ?? b.targets.first {
            dropStates.append(("wheel-batch", .ready(b), nil, nil))
            dropStates.append(("wheel-converting", .converting(b, target: png, completed: 1, fraction: 0.45), nil, nil))
            let summary = ConversionModel.Summary(
                outputs: images.prefix(2).map { $0.deletingPathExtension().appendingPathExtension("png") }, target: png,
                inputBytes: 5_200_000, outputBytes: 6_100_000,
                failures: ["IMG_2041.heic: Tool exited 1: could not decode"])
            dropStates.append(("done-batch-partial", .done(summary), nil, nil))
        }
        if let b = batch([audio]) { dropStates.append(("wheel-audio", .ready(b), nil, nil)) }
        if let b = batch([doc]) { dropStates.append(("wheel-document", .ready(b), 0, nil)) }

        // Link downloads (a YouTube-like video with separate AV1 and H.264 streams).
        let link = URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ")!
        let video = LinkDownloader.Info(
            link: link, title: "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film",
            uploader: "Blender", duration: 635, hasVideo: true, hasAudio: true,
            bestHeight: 2160, bestVideoCodec: "av01", compatibleHeight: 1080, audioBitrate: 129.5, audioCodec: "aac")
        let linkBatch = ConversionModel.linkBatch(video)
        dropStates.append(("link-hover", .linkHover(link), nil, nil))
        dropStates.append(("link-fetching", .fetching(link), nil, nil))
        dropStates.append(("link-wheel", .ready(linkBatch), 0, nil))
        if let best = linkBatch.targets.first {
            dropStates.append(("link-downloading", .converting(linkBatch, target: best, completed: 0, fraction: 0.62), nil, nil))
            let saved = home.appendingPathComponent("Downloads/Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film.mp4")
            let summary = ConversionModel.Summary(outputs: [saved], target: best, inputBytes: 0, outputBytes: 734_000_000,
                                                  failures: [], isDownload: true)
            dropStates.append(("link-done", .done(summary), nil, nil))
        }
        let reel = LinkDownloader.Info(link: URL(string: "https://www.instagram.com/reel/C0ffee/")!, title: "Sunset run 🌅",
                                       duration: 27, hasVideo: true, hasAudio: true, bestHeight: 1080, bestVideoCodec: "avc1",
                                       compatibleHeight: 1080, audioBitrate: 128, audioCodec: "aac")
        dropStates.append(("link-wheel-instagram", .ready(ConversionModel.linkBatch(reel)), nil, nil))
        dropStates.append(("link-failed", .failed(LinkError.signInRequired(.instagram).description), nil, reel.link))

        let looks: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        for (look, name) in looks {
            guard let appearance = NSAppearance(named: name) else { continue }
            for (label, phase, hovered, link) in dropStates {
                model.setPhaseForSnapshot(phase, hovered: hovered, lastLink: link, needsSettings: label == "link-failed")
                render(DropWheelView(model: model, actions: dropActions)
                        .frame(width: PanelLayout.size.width, height: PanelLayout.size.height)
                        .background(Citrus.canvas),
                       size: PanelLayout.size, appearance: appearance,
                       to: outputDirectory.appendingPathComponent("\(look)-\(label).png"))
            }
            model.setPhaseForSnapshot(.idle)
            render(CitrusMenuView(model: model, recents: recents, actions: menuActions)
                    .padding(24).background(Citrus.canvas),
                   size: nil, appearance: appearance,
                   to: outputDirectory.appendingPathComponent("\(look)-menu.png"))
            for tab in SettingsTab.allCases {
                renderInWindow(CitrusSettingsView(settings: settings, initialTab: tab)
                        .frame(width: 600, height: 560),
                       size: CGSize(width: 600, height: 560), appearance: appearance,
                       to: outputDirectory.appendingPathComponent("\(look)-settings-\(tab.rawValue).png"))
            }
        }
        UserDefaults().removePersistentDomain(forName: suite)
        print("snapshots written to \(outputDirectory.path)")
    }

    private static func format(_ id: String) -> MediaFormat {
        MediaFormat.catalog.first { $0.id == id }!
    }

    /// Render a pure-SwiftUI view at 2x with `ImageRenderer`, which draws
    /// shadows the right way up. Views with AppKit-backed controls (Slider,
    /// Menu) need `renderInWindow` instead.
    private static func render<V: View>(_ view: V, size: CGSize?, appearance: NSAppearance, to url: URL) {
        let renderer = ImageRenderer(content: view
            .environment(\.colorScheme, appearance.name == .darkAqua ? .dark : .light))
        renderer.scale = 2
        if let size { renderer.proposedSize = ProposedViewSize(size) }
        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance { image = renderer.cgImage }   // resolves dynamic NSColors
        guard let image else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Lay a view out in an off-screen window and capture it at 2x. Handles
    /// AppKit-backed controls, but flips SwiftUI shadow offsets.
    private static func renderInWindow<V: View>(_ view: V, size: CGSize?, appearance: NSAppearance, to url: URL) {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, appearance.name == .darkAqua ? .dark : .light))
        hosting.appearance = appearance
        let frameSize = size ?? hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: frameSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))   // let SwiftUI settle
        hosting.display()

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(frameSize.width * scale), pixelsHigh: Int(frameSize.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = frameSize
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
