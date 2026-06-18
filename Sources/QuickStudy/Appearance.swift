import AppKit
import SwiftUI

/// User-selectable app appearance, surfaced as the "Appearance" segmented
/// control in Settings. Drives the whole app theme (panel + settings window)
/// by setting `NSApp.appearance`; `.auto` follows the system.
enum Appearance: String, CaseIterable, Identifiable {
    case light, dark, auto

    static let storageKey = "appearance"
    static let defaultValue: Appearance = .auto

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .auto: return "Auto"
        }
    }

    /// The macOS appearance to assign to `NSApp`; `nil` means follow the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .auto: return nil
        }
    }

    /// Reads the current choice from `UserDefaults`. Used by non-SwiftUI callers.
    static func current() -> Appearance {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? defaultValue.rawValue
        return Appearance(rawValue: raw) ?? defaultValue
    }

    /// Applies the chosen appearance to the entire app.
    @MainActor static func apply(_ appearance: Appearance) {
        NSApp.appearance = appearance.nsAppearance
    }
}
