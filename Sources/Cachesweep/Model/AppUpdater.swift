import Foundation
import Sparkle

/// Thin wrapper around Sparkle's standard updater.
/// Auto-update only works when running as a real `.app` bundle (with the
/// SUFeedURL + SUPublicEDKey Info.plist keys); in the bare dev binary it
/// stays inert so development runs don't spam errors.
@MainActor
final class AppUpdater {
    static let shared = AppUpdater()

    private var controller: SPUStandardUpdaterController?

    /// True only when launched from a packaged .app (so Sparkle can function).
    var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    func start() {
        guard isAvailable, controller == nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
