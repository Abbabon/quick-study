import Shared

/// One rendered mana pip: the glyph shown inside the disc and the identity that tints it.
public struct ManaPip: Equatable {
    public let glyph: String
    public let identity: ColorIdentity
}

/// Pure parser for Scryfall mana-cost strings like "{2}{U}{U}".
/// W/U/B/R/G map to their color; everything else (numbers, X, C, hybrids,
/// Phyrexian) renders as a colorless disc showing the inner text. "{T}" → ↻.
public enum ManaCost {
    public static func pips(from cost: String) -> [ManaPip] {
        guard !cost.isEmpty else { return [] }
        var pips: [ManaPip] = []
        var token = ""
        var inside = false
        for ch in cost {
            switch ch {
            case "{": inside = true; token = ""
            case "}": inside = false; pips.append(pip(for: token))
            default:  if inside { token.append(ch) }
            }
        }
        return pips
    }

    private static func pip(for token: String) -> ManaPip {
        let upper = token.uppercased()
        switch upper {
        case "W": return ManaPip(glyph: "W", identity: .white)
        case "U": return ManaPip(glyph: "U", identity: .blue)
        case "B": return ManaPip(glyph: "B", identity: .black)
        case "R": return ManaPip(glyph: "R", identity: .red)
        case "G": return ManaPip(glyph: "G", identity: .green)
        case "T": return ManaPip(glyph: "↻", identity: .colorless)
        default:  return ManaPip(glyph: upper, identity: .colorless)
        }
    }
}
