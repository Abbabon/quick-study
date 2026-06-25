import SwiftUI

/// Compact at-a-glance rarity indicator: a single tinted letter (C/U/R/M) derived from a
/// card's representative rarity. Renders nothing when the rarity is unknown — which is the
/// case for rows ingested before the v9 schema, until the next refresh backfills it.
struct RarityBadge: View {
    let rarity: String?
    var size: CGFloat = 15

    var body: some View {
        if let info = Self.info(for: rarity) {
            Text(info.letter)
                .font(.system(size: size * 0.7, weight: .bold, design: .rounded))
                .foregroundStyle(info.color)
                .frame(width: size, height: size)
                .background(Circle().fill(info.color.opacity(0.16)))
                .help(info.label)
                .accessibilityLabel("Rarity: \(info.label)")
        }
    }

    struct Info {
        let letter: String
        let color: Color
        let label: String
    }

    /// Maps a Scryfall rarity string to a badge letter, tint, and human label. Off-ladder
    /// rarities (e.g. "special", "bonus") get their initial and a neutral tint.
    static func info(for rarity: String?) -> Info? {
        guard let r = rarity?.lowercased(), !r.isEmpty else { return nil }
        switch r {
        case "common":   return Info(letter: "C", color: DS.rarityCommon, label: "Common")
        case "uncommon": return Info(letter: "U", color: DS.rarityUncommon, label: "Uncommon")
        case "rare":     return Info(letter: "R", color: DS.rarityRare, label: "Rare")
        case "mythic", "mythic rare":
            return Info(letter: "M", color: DS.rarityMythic, label: "Mythic")
        default:
            return Info(letter: String(r.prefix(1)).uppercased(), color: DS.textTertiary,
                        label: r.capitalized)
        }
    }
}
