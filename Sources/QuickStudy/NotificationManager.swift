import Foundation
import UserNotifications

/// Posts a native macOS notification when newer cards are available, with an
/// "Update Now" action. Deduped per Scryfall stamp so checking on every launch never
/// re-notifies for an update the user has already seen.
///
/// Local notifications only fire from the built `.app` bundle (a `swift run` process has
/// no bundle, so `UNUserNotificationCenter` is a no-op there).
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let categoryID = "card-update"
    static let updateActionID = "update-now"
    static let appCategoryID = "app-update"
    static let appUpdateActionID = "app-update-now"

    private let notifiedStampKey = "notifiedUpdateStamp"
    private let notifiedAppVersionKey = "notifiedAppVersion"

    /// Invoked on the main actor when the user taps "Update Now".
    var onUpdateAction: (() -> Void)?
    /// Invoked on the main actor when the user taps the notification body.
    var onOpenPanel: (() -> Void)?
    /// Invoked on the main actor when the user acts on an app-update notification.
    var onAppUpdateAction: (() -> Void)?

    /// Registers the delegate and the action categories. Call once at launch.
    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let action = UNNotificationAction(identifier: Self.updateActionID,
                                          title: "Download Images",
                                          options: [.foreground])
        let category = UNNotificationCategory(identifier: Self.categoryID,
                                              actions: [action],
                                              intentIdentifiers: [],
                                              options: [])
        let appAction = UNNotificationAction(identifier: Self.appUpdateActionID,
                                             title: "Install Update",
                                             options: [.foreground])
        let appCategory = UNNotificationCategory(identifier: Self.appCategoryID,
                                                 actions: [appAction],
                                                 intentIdentifiers: [],
                                                 options: [])
        center.setNotificationCategories([category, appCategory])
    }

    /// Posts a notification for `stamp` unless one was already posted for it. Requests
    /// authorization lazily (on first real update) so the system prompt has context.
    func notifyIfNeeded(stamp: String, newCards: Int) {
        guard UserDefaults.standard.string(forKey: notifiedStampKey) != stamp else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { self.post(stamp: stamp, newCards: newCards) }
                }
            case .authorized, .provisional:
                self.post(stamp: stamp, newCards: newCards)
            default:
                break // denied — respect the user's choice; other surfaces still show it.
            }
        }
    }

    private func post(stamp: String, newCards: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Quick Study"
        content.body = "Added \(newCards) new card\(newCards == 1 ? "" : "s"). Download images for offline use?"
        content.categoryIdentifier = Self.categoryID
        content.sound = .default
        let request = UNNotificationRequest(identifier: "card-update-\(stamp)",
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
        UserDefaults.standard.set(stamp, forKey: notifiedStampKey)
    }

    /// Posts an app-update notification for `version` unless one was already posted for it.
    /// Same lazy-auth + dedupe shape as `notifyIfNeeded`.
    func notifyAppUpdateIfNeeded(version: String) {
        guard UserDefaults.standard.string(forKey: notifiedAppVersionKey) != version else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { self.postApp(version: version) }
                }
            case .authorized, .provisional:
                self.postApp(version: version)
            default:
                break // denied — other surfaces (badge, banner) still show it.
            }
        }
    }

    private func postApp(version: String) {
        let content = UNMutableNotificationContent()
        content.title = "Quick Study"
        content.body = "QuickStudy \(version) is available."
        content.categoryIdentifier = Self.appCategoryID
        content.sound = .default
        let request = UNNotificationRequest(identifier: "app-update-\(version)",
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
        UserDefaults.standard.set(version, forKey: notifiedAppVersionKey)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound]) // show even while QuickStudy is frontmost
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let actionID = response.actionIdentifier
        let categoryID = response.notification.request.content.categoryIdentifier
        DispatchQueue.main.async {
            switch actionID {
            case Self.updateActionID:
                self.onUpdateAction?()
            case Self.appUpdateActionID:
                self.onAppUpdateAction?()
            case UNNotificationDefaultActionIdentifier:
                // Route based on which kind of notification was tapped.
                if categoryID == Self.appCategoryID {
                    self.onAppUpdateAction?()
                } else {
                    self.onOpenPanel?()
                }
            default:
                break
            }
            completionHandler()
        }
    }
}
