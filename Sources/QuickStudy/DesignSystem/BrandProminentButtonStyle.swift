import SwiftUI

/// Prominent button with the brand accent gradient fill (design: solid fills
/// use the blue→violet gradient). Use for primary actions only.
struct BrandProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md).fill(DS.accentGradient)
            )
            .brightness(configuration.isPressed ? -0.06 : 0)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
    }
}

extension ButtonStyle where Self == BrandProminentButtonStyle {
    static var brandProminent: BrandProminentButtonStyle { BrandProminentButtonStyle() }
}
