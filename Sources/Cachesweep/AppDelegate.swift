import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = AppModel()
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar icon — a template SF Symbol so it tints with the menu bar.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Cachesweep") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "✦"   // never leave a zero-width, invisible item
            }
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover.contentSize = NSSize(width: DS.popoverWidth, height: DS.popoverHeight)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: MenuContentView(model: model))

        model.startMonitoring()
        AppUpdater.shared.start()          // Sparkle (no-op unless running as a .app)
        NotificationCenter.default.addObserver(self, selector: #selector(openSettings),
                                               name: .showSettings, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(openHistory),
                                               name: .showHistory, object: nil)
        Task { await model.scan() }

        // First launch: confirm visibly that the app is alive. A full menu bar
        // (notch overflow) or tools like Bartender can swallow the status icon,
        // which reads as "nothing happened".
        if !UserDefaults.standard.bool(forKey: "welcomeShown") {
            UserDefaults.standard.set(true, forKey: "welcomeShown")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                self.showWelcome()
            }
        }
    }

    private func showWelcome() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("welcome.title")
        alert.informativeText = L("welcome.message")
        alert.addButton(withTitle: L("welcome.ok"))
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ActivityHistory.shared.flush()   // saves are throttled; persist the tail
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: L("window.settings"),
                                        content: NSHostingController(rootView: SettingsView()))
        }
        show(settingsWindow)
    }

    @objc func openHistory() {
        if historyWindow == nil {
            historyWindow = makeWindow(title: L("window.history"),
                                       content: NSHostingController(rootView: HistoryView()))
        }
        show(historyWindow)
    }

    private func makeWindow(title: String, content: NSViewController) -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = title
        win.contentViewController = content
        win.isReleasedWhenClosed = false
        win.center()
        return win
    }

    private func show(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            Task { await model.scan() }   // refresh each time it opens
        }
    }
}
