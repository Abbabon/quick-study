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

    private let notifiedStampKey = "notifiedUpdateStamp"

    /// Invoked on the main actor when the user taps "Update Now".
    var onUpdateAction: (() -> Void)?
    /// Invoked on the main actor when the user taps the notification body.
    var onOpenPanel: (() -> Void)?

    /// Registers the delegate and the "Update Now" action category. Call once at launch.
    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let action = UNNotificationAction(identifier: Self.updateActionID,
                                          title: "Update Now",
                                          options: [.foreground])
        let category = UNNotificationCategory(identifier: Self.categoryID,
                                              actions: [action],
                                              intentIdentifiers: [],
                                              options: [])
        center.setNotificationCategories([category])
    }

    /// Posts a notification for `stamp` unless one was already posted for it. Requests
    /// authorization lazily (on first real update) so the system prompt has context.
    func notifyIfNeeded(stamp: String) {
        guard UserDefaults.standard.string(forKey: notifiedStampKey) != stamp else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { self.post(stamp: stamp) }
                }
            case .authorized, .provisional:
                self.post(stamp: stamp)
            default:
                break // denied — respect the user's choice; other surfaces still show it.
            }
        }
    }

    private func post(stamp: String) {
        let content = UNMutableNotificationContent()
        content.title = "Quick Study"
        content.body = "New Magic cards are available — update your collection."
        content.categoryIdentifier = Self.categoryID
        content.sound = .default
        let request = UNNotificationRequest(identifier: "card-update-\(stamp)",
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
        UserDefaults.standard.set(stamp, forKey: notifiedStampKey)
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
        DispatchQueue.main.async {
            switch actionID {
            case Self.updateActionID:
                self.onUpdateAction?()
            case UNNotificationDefaultActionIdentifier:
                self.onOpenPanel?()
            default:
                break
            }
            completionHandler()
        }
    }
}
