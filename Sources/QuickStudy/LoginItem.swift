import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` for the "Launch at login" toggle.
///
/// `SMAppService.mainApp` registers the running `.app` bundle itself as a login
/// item, which surfaces in System Settings → General → Login Items. The OS is
/// the source of truth — we never cache the state, so the toggle and System
/// Settings can't drift apart.
@MainActor
enum LoginItem {
    /// `true` when the app is currently registered to launch at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Register (or unregister) the app as a login item. Throws on failure so
    /// callers can surface the error and resync the UI to the real state.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
