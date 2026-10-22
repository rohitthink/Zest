import AppKit

// Menu-bar agent bootstrap. `.accessory` means no Dock icon and no app menu —
// Zest lives in the menu bar like the subject app, but on our own ZestKit.
// (A SwiftPM executable sets this at runtime instead of via an Info.plist
// LSUIElement key; a shipping .app would also carry the plist key.)
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

// `ZestApp --selftest` checks wheel geometry and batch building, then exits.
// `ZestApp --snapshot [dir]` renders every surface to PNGs and exits.
let arguments = CommandLine.arguments
if arguments.contains("--selftest") {
    let result = AppSelfTest.run()
    result.log.forEach { print($0) }
    print("\(result.passed) passed, \(result.failed) failed")
    exit(result.failed == 0 ? 0 : 1)
}
if let flag = arguments.firstIndex(of: "--snapshot") {
    let path = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : "snapshots"
    SnapshotRunner.run(outputDirectory: URL(fileURLWithPath: path))
    exit(0)
}

let delegate = AppDelegate()
application.delegate = delegate
application.run()
