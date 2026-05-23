import Foundation
import SwiftUI

/// Multiplies font sizes and paddings by a user-controlled factor.
///
/// Stored in `UserDefaults` under the key ``UIScale/storageKey`` and
/// surfaced in SwiftUI views via `@AppStorage("uiScale")`. The card
/// image frame deliberately does NOT use this scale — the image was
/// enlarged separately and should stay at a fixed size.
struct UIScale {
    static let storageKey = "uiScale"
    static let defaultValue: Double = 1.0
    static let minValue: Double = 0.75
    static let maxValue: Double = 2.0

    let value: Double

    init(value: Double) {
        self.value = Self.clamp(value)
    }

    func pad(_ v: CGFloat) -> CGFloat { v * CGFloat(value) }
    func size(_ v: CGFloat) -> CGFloat { v * CGFloat(value) }

    func font(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: self.size(size), weight: weight, design: design)
    }

    static func clamp(_ raw: Double) -> Double {
        min(max(raw, minValue), maxValue)
    }

    /// Reads the current scale from `UserDefaults`. Used by non-SwiftUI
    /// callers like `PanelController` that can't use `@AppStorage`.
    static func current() -> UIScale {
        let raw = UserDefaults.standard.object(forKey: storageKey) as? Double ?? defaultValue
        return UIScale(value: raw)
    }
}
