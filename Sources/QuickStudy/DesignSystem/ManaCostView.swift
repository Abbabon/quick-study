import SwiftUI

/// Renders a mana-cost string as a row of colored pips.
struct ManaCostView: View {
    let cost: String
    var size: CGFloat = 18

    var body: some View {
        let pips = ManaCost.pips(from: cost)
        HStack(spacing: 3) {
            ForEach(Array(pips.enumerated()), id: \.offset) { _, pip in
                Text(pip.glyph)
                    .font(.system(size: round(size * 0.58), weight: .bold, design: .monospaced))
                    .foregroundStyle(DS.manaInk)
                    .frame(width: size, height: size)
                    .background(Circle().fill(DS.tint(for: pip.identity)))
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5))
            }
        }
    }
}
