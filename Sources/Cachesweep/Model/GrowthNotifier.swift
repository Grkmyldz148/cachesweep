import Foundation
import UserNotifications

/// Posts a proactive "X grew ▲N GB this week" notification, at most once a
/// day, when something tracked by ActivityHistory grew by ≥ 1 GB in 7 days.
/// Only active in a bundled .app (UNUserNotificationCenter needs a bundle id).
@MainActor
enum GrowthNotifier {
    private static let lastKey = "lastGrowthNotify"
    private static let threshold: Int64 = 1_000_000_000   // 1 GB / week

    static func checkAndNotify() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let store = UserDefaults.standard
        let last = store.object(forKey: lastKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 86_400 else { return }

        let since = Date().addingTimeInterval(-7 * 86_400)
        guard let top = ActivityHistory.shared.topGrowers(since: since, limit: 1).first,
              top.growth >= threshold else { return }

        store.set(Date(), forKey: lastKey)
        let title = L("notify.growth.title")
        let body = Lf("notify.growth.body", top.record.label, UInt64(top.growth).fileSize)

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: "growth", content: content, trigger: nil))
        }
    }
}
