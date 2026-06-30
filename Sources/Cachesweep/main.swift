import AppKit

// Menu-bar–only app: no Dock icon, no main window.
// setActivationPolicy(.accessory) makes a plain SwiftPM executable behave
// like a proper LSUIElement menu-bar app without an Info.plist.
//
// Program entry is on the main thread, so assumeIsolated is safe and lets us
// construct the @MainActor AppDelegate synchronously.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
