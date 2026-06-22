import SwiftUI

/// The design system's `variant="default"` button: a flat surface chip with a
/// hairline ring and primary-text label. Used for the artist multiple-choice
/// answers and secondary actions (e.g. "Menu" on game over).
///
/// The label decides its own alignment — pass `.frame(maxWidth: .infinity, alignment:)`
/// in the label when a full-width / left-aligned option is wanted.
struct BrandDefaultButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .fill(DS.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.md)
                            .strokeBorder(DS.separator, lineWidth: 0.5)
                    )
            )
            .brightness(configuration.isPressed ? (isDark ? 0.06 : -0.04) : 0)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
    }

    private var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

extension ButtonStyle where Self == BrandDefaultButtonStyle {
    static var brandDefault: BrandDefaultButtonStyle { BrandDefaultButtonStyle() }
}
