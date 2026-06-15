import SwiftUI
import Shared

/// Mana-tinted gradient fill shown wherever a card image is missing.
struct IdentityPlaceholder: View {
    let identity: ColorIdentity
    var cornerRadius: CGFloat = DS.Radius.xs
    var symbol: String? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(DS.identityGradient(for: identity))
            .overlay {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.title)
                        .foregroundStyle(DS.manaInk.opacity(0.45))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
            )
    }
}
