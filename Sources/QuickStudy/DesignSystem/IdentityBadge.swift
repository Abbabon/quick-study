import SwiftUI
import Shared

/// A small identity-tinted capsule shown in the card preview header.
/// Displays the card's color letters (e.g. "WU"), or "C" when colorless.
struct IdentityBadge: View {
    let colors: [String]

    private var identity: ColorIdentity { ColorIdentity(colors: colors) }
    private var label: String { colors.isEmpty ? "C" : colors.joined() }

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DS.manaInk(for: identity))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(DS.tint(for: identity)))
    }
}
