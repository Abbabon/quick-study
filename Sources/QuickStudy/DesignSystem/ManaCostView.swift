import SwiftUI
import Shared

/// Renders a mana-cost string as a row of colored pips.
struct ManaCostView: View {
    let cost: String
    var size: CGFloat = 18

    var body: some View {
        let pips = ManaCost.pips(from: cost)
        HStack(spacing: 3) {
            ForEach(Array(pips.enumerated()), id: \.offset) { _, pip in
                ManaPipDisc(pip: pip, size: size)
            }
        }
    }
}

/// One mana pip drawn as a disc: a solid tinted circle, or — for hybrids like
/// `{W/U}` and `{2/W}` — a diagonally split two-tone disc. Shared by
/// ``ManaCostView`` and the inline oracle-text renderer so they stay identical.
struct ManaPipDisc: View {
    let pip: ManaPip
    let size: CGFloat

    var body: some View {
        ZStack {
            if let halves = pip.halves, halves.count == 2 {
                // "/"-diagonal split: first half top-left, second bottom-right.
                Circle().fill(DS.tint(for: halves[0].identity))
                Circle().fill(DS.tint(for: halves[1].identity))
                    .clipShape(BottomRightTriangle())
                glyph(halves[0].glyph, scale: 0.40, identity: halves[0].identity).offset(x: -size * 0.19, y: -size * 0.19)
                glyph(halves[1].glyph, scale: 0.40, identity: halves[1].identity).offset(x: size * 0.19, y: size * 0.19)
            } else {
                Circle().fill(DS.tint(for: pip.identity))
                glyph(pip.glyph, scale: 0.58, identity: pip.identity)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5))
    }

    private func glyph(_ s: String, scale: CGFloat, identity: ColorIdentity) -> some View {
        Text(s)
            .font(.system(size: round(size * scale), weight: .bold, design: .monospaced))
            .foregroundStyle(DS.manaInk(for: identity))
            // The Unicode tap arrow sits 180° from the printed card glyph.
            .rotationEffect(s == ManaCost.tapGlyph ? .degrees(180) : .zero)
    }
}

/// The bottom-right half of the frame, split by the anti-diagonal from
/// bottom-left to top-right (the `/` in a hybrid symbol).
private struct BottomRightTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))    // top-right
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)) // bottom-right
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)) // bottom-left
        p.closeSubpath()
        return p
    }
}
