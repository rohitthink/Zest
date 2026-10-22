import AppIntents
import Foundation
import ZestKit

/// A Shortcuts / Spotlight action that converts a file with ZestKit. It drives
/// the exact same engine as the CLI, GUI, and URL scheme.
///
/// Note: the action compiles and runs in-process; for it to appear in the
/// Shortcuts app it must ship inside a real `.app` bundle (so the AppIntents
/// metadata extractor runs). See README "Automation".
struct ConvertFileIntent: AppIntent {
    static var title: LocalizedStringResource { "Convert File" }
    static var description: IntentDescription { IntentDescription("Convert a file to another format using Zest.") }

    @Parameter(title: "File")
    var file: IntentFile

    @Parameter(title: "Convert To", description: "Target format id, e.g. png, jpg, webp, mp3, mp4.")
    var target: String

    @Parameter(title: "Quality", default: 0.8)
    var quality: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$file) to \(\.$target)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let url = file.fileURL else {
            throw ConversionError.io("The Shortcuts input had no on-disk file URL.")
        }
        let engine = ConversionEngine.standard()
        let result = try await engine.convertFile(at: url, toFormat: target,
                                                  options: ConversionOptions(quality: min(max(quality, 0), 1)))
        return .result(value: IntentFile(fileURL: result.output))
    }
}

/// Exposes the action to the system with a spoken phrase.
struct ZestShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConvertFileIntent(),
            phrases: ["Convert a file with \(.applicationName)"],
            shortTitle: "Convert File",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
