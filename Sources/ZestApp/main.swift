import AppKit

// Menu-bar agent bootstrap. `.accessory` means no Dock icon and no app menu —
// Zest lives in the menu bar like the subject app, but on our own ZestKit.
// (A SwiftPM executable sets this at runtime instead of via an Info.plist
// LSUIElement key; a shipping .app would also carry the plist key.)
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
