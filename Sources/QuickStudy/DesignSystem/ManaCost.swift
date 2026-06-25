import Shared

/// One rendered mana pip: the glyph shown inside the disc and the identity that
/// tints it. Hybrid symbols (`{W/U}`, `{2/W}`) carry their two `halves`, which
/// the view renders as a diagonally split two-tone disc.
public struct ManaPip: Equatable {
    /// One side of a hybrid pip.
    public struct Half: Equatable {
        public let glyph: String
        public let identity: ColorIdentity
        public init(glyph: String, identity: ColorIdentity) {
            self.glyph = glyph
            self.identity = identity
        }
    }

    public let glyph: String
    public let identity: ColorIdentity
    /// Non-nil for hybrids: the two halves drawn as a split disc.
    public let halves: [Half]?

    public init(glyph: String, identity: ColorIdentity, halves: [Half]? = nil) {
        self.glyph = glyph
        self.identity = identity
        self.halves = halves
    }
}

/// Pure parser for Scryfall mana-cost strings like "{2}{U}{U}".
/// W/U/B/R/G map to their color; everything else (numbers, X, C, hybrids,
/// Phyrexian) renders as a colorless disc showing the inner text. "{T}" → ↺.
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

    /// Maps a single token (the text between `{` and `}`) to a rendered pip.
    /// Used both by the cost parser and by inline oracle-text rendering.
    /// A token containing `/` (e.g. `W/U`, `2/W`, `W/P`) becomes a hybrid pip.
    public static func pip(for token: String) -> ManaPip {
        let upper = token.uppercased()
        if upper.contains("/") {
            let parts = upper.split(separator: "/").map(half(for:))
            if parts.count == 2 {
                return ManaPip(glyph: upper, identity: .multicolor, halves: parts)
            }
        }
        let h = half(for: Substring(upper))
        return ManaPip(glyph: h.glyph, identity: h.identity)
    }

    /// Maps one side of a hybrid (or a whole single pip) to a glyph + identity.
    private static func half(for token: Substring) -> ManaPip.Half {
        switch token {
        case "W": return ManaPip.Half(glyph: "W", identity: .white)
        case "U": return ManaPip.Half(glyph: "U", identity: .blue)
        case "B": return ManaPip.Half(glyph: "B", identity: .black)
        case "R": return ManaPip.Half(glyph: "R", identity: .red)
        case "G": return ManaPip.Half(glyph: "G", identity: .green)
        case "T": return ManaPip.Half(glyph: "↺", identity: .colorless)
        case "P": return ManaPip.Half(glyph: "Φ", identity: .colorless)
        default:  return ManaPip.Half(glyph: String(token), identity: .colorless)
        }
    }
}
