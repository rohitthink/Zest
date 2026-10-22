import AppKit
import ServiceManagement
import ZestKit

/// Where converted ("squeezed") files land.
enum OutputDestination: String, CaseIterable, Identifiable {
    case nextToOriginal, downloads, ask

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nextToOriginal: return "Next to the original"
        case .downloads: return "Downloads"
        case .ask: return "Ask every time"
        }
    }

    var subtitle: String {
        switch self {
        case .nextToOriginal: return "Same folder"
        case .downloads: return "~/Downloads"
        case .ask: return "Choose per file"
        }
    }
}

/// User preferences, persisted in UserDefaults. One instance is shared by the
/// app; views observe it and the conversion model reads it at conversion time.
@MainActor
final class ZestSettings: ObservableObject {

    private enum Key {
        static let destination = "destination"
        static let quality = "quality"
        static let stripMetadata = "stripMetadata"
        static let showDropZoneOnLaunch = "showDropZoneOnLaunch"
        static let maxDimension = "maxDimension"
        static let revealWhenDone = "revealWhenDone"
        static let playSound = "playSound"
        static let linkCookies = "linkCookies"
    }

    private enum Default {
        static let destination = OutputDestination.nextToOriginal
        static let quality = 0.8
        static let stripMetadata = true
        static let showDropZoneOnLaunch = true
        static let maxDimension = 0
        static let revealWhenDone = false
        static let playSound = true
        static let linkCookies = LinkDownloader.CookieSource.none
    }

    /// Choices offered for "Longest side" (0 keeps the original size).
    static let maxDimensionChoices = [0, 4096, 2048, 1080]

    private let defaults: UserDefaults

    @Published var destination: OutputDestination { didSet { defaults.set(destination.rawValue, forKey: Key.destination) } }
    /// 0.1 (smallest files) ... 1.0 (sharpest).
    @Published var quality: Double { didSet { defaults.set(quality, forKey: Key.quality) } }
    @Published var stripMetadata: Bool { didSet { defaults.set(stripMetadata, forKey: Key.stripMetadata) } }
    @Published var showDropZoneOnLaunch: Bool { didSet { defaults.set(showDropZoneOnLaunch, forKey: Key.showDropZoneOnLaunch) } }
    /// Longest side in pixels for images/video; 0 keeps the original.
    @Published var maxDimension: Int { didSet { defaults.set(maxDimension, forKey: Key.maxDimension) } }
    @Published var revealWhenDone: Bool { didSet { defaults.set(revealWhenDone, forKey: Key.revealWhenDone) } }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: Key.playSound) } }
    /// Browser whose sign-in yt-dlp may borrow for private or sign-in-only
    /// posts. Off by default: it reads that browser's cookies.
    @Published var linkCookies: LinkDownloader.CookieSource { didSet { defaults.set(linkCookies.rawValue, forKey: Key.linkCookies) } }

    /// Mirrors SMAppService; not stored in defaults (the system owns it).
    @Published private(set) var launchAtLogin = false
    /// Set when the system wants the user to approve the login item.
    @Published private(set) var launchAtLoginNeedsApproval = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        destination = defaults.string(forKey: Key.destination).flatMap(OutputDestination.init(rawValue:)) ?? Default.destination
        let q = defaults.object(forKey: Key.quality) as? Double ?? Default.quality
        quality = min(max(q.isFinite ? q : Default.quality, 0.1), 1)
        stripMetadata = defaults.object(forKey: Key.stripMetadata) as? Bool ?? Default.stripMetadata
        showDropZoneOnLaunch = defaults.object(forKey: Key.showDropZoneOnLaunch) as? Bool ?? Default.showDropZoneOnLaunch
        let dim = defaults.object(forKey: Key.maxDimension) as? Int ?? Default.maxDimension
        maxDimension = Self.maxDimensionChoices.contains(dim) ? dim : Default.maxDimension
        revealWhenDone = defaults.object(forKey: Key.revealWhenDone) as? Bool ?? Default.revealWhenDone
        playSound = defaults.object(forKey: Key.playSound) as? Bool ?? Default.playSound
        linkCookies = defaults.string(forKey: Key.linkCookies).flatMap(LinkDownloader.CookieSource.init(rawValue:)) ?? Default.linkCookies
        refreshLaunchAtLogin()
    }

    /// Options for a GUI conversion, built from the current preferences.
    var conversionOptions: ConversionOptions {
        ConversionOptions(quality: quality,
                          maxDimension: maxDimension > 0 ? maxDimension : nil,
                          stripMetadata: stripMetadata)
    }

    func resetToDefaults() {
        destination = Default.destination
        quality = Default.quality
        stripMetadata = Default.stripMetadata
        showDropZoneOnLaunch = Default.showDropZoneOnLaunch
        maxDimension = Default.maxDimension
        revealWhenDone = Default.revealWhenDone
        playSound = Default.playSound
        linkCookies = Default.linkCookies
    }

    // MARK: - Launch at login

    /// Login items only work for an installed .app bundle, not `swift run`.
    var launchAtLoginAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        launchAtLoginNeedsApproval = status == .requiresApproval
    }

    /// Register or unregister the app as a login item. Throws the system's
    /// error so the caller can explain it; state is refreshed either way.
    func setLaunchAtLogin(_ enabled: Bool) throws {
        defer { refreshLaunchAtLogin() }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// One finished conversion, shown under "Recently squeezed".
struct RecentItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var outputPath: String
    var targetID: String
    var date: Date

    var outputURL: URL { URL(fileURLWithPath: outputPath) }
    var fileName: String { outputURL.lastPathComponent }
    var format: MediaFormat? { MediaFormat.catalog.first { $0.id == targetID } }
}

/// The last few outputs, newest first, persisted as JSON in UserDefaults.
@MainActor
final class RecentsStore: ObservableObject {
    static let limit = 5
    private static let key = "recents"

    private let defaults: UserDefaults
    @Published private(set) var items: [RecentItem] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([RecentItem].self, from: data) {
            items = Array(decoded.prefix(Self.limit))
        }
    }

    func add(output: URL, target: MediaFormat) {
        items.removeAll { $0.outputPath == output.path }
        items.insert(RecentItem(outputPath: output.path, targetID: target.id, date: Date()), at: 0)
        items = Array(items.prefix(Self.limit))
        save()
    }

    func clear() {
        items = []
        save()
    }

    /// Drop entries whose files were moved or deleted (call when the menu opens).
    func pruneMissing() {
        let kept = items.filter { FileManager.default.fileExists(atPath: $0.outputPath) }
        if kept.count != items.count {
            items = kept
            save()
        }
    }

    /// Reveal an output in Finder.
    func reveal(_ item: RecentItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.outputURL])
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: Self.key) }
    }
}
