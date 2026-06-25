import Foundation

/// The field an inline filter targets. Aliases (`r`/`rarity`, `c`/`color`, …) collapse here.
public enum FilterField: Sendable, Equatable {
    case rarity
    case color
    case type
    case manaValue
    case oracle
    case set
}

/// Comparison operator parsed from a filter token. `:` and `=` both map to `.eq`; the
/// field's matcher decides whether `.eq` means "equals" (rarity/mana value) or "contains"
/// (type/oracle text).
public enum FilterOp: Sendable, Equatable {
    case eq
    case lt
    case le
    case gt
    case ge
}

/// One parsed inline filter, e.g. `r>=rare` → `(.rarity, .ge, "rare", negated: false)`.
public struct Filter: Sendable, Equatable {
    public let field: FilterField
    public let op: FilterOp
    public let value: String
    public let negated: Bool

    public init(field: FilterField, op: FilterOp, value: String, negated: Bool) {
        self.field = field
        self.op = op
        self.value = value
        self.negated = negated
    }
}

/// Splits a search box string into a free-text name query plus structured inline filters,
/// imitating Scryfall's syntax (`bolt r:common`, `c:r t:creature mv>=3`, `o:"draw a card"`,
/// `-t:land`). Pure and synchronous — runs on every keystroke alongside `SearchEngine`.
public enum QueryParser {
    /// Recognized filter keys and their aliases.
    private static let fields: [String: FilterField] = [
        "r": .rarity, "rarity": .rarity,
        "c": .color, "color": .color,
        "t": .type, "type": .type,
        "mv": .manaValue, "cmc": .manaValue,
        "o": .oracle, "oracle": .oracle,
        "s": .set, "set": .set,
    ]

    public static func parse(_ raw: String) -> (name: String, filters: [Filter]) {
        var nameParts: [String] = []
        var filters: [Filter] = []
        for token in tokenize(raw) {
            if let filter = parseFilter(token) {
                filters.append(filter)
            } else {
                nameParts.append(unquote(token))
            }
        }
        let name = nameParts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return (name, filters)
    }

    /// Whitespace-splits the input, but keeps double-quoted runs together so a value like
    /// `o:"draw a card"` survives as one token.
    private static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in s {
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if ch == " " && !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Returns a `Filter` if `token` matches `[-]key(op)value` with a known key; nil otherwise
    /// (in which case the token is treated as free text).
    private static func parseFilter(_ token: String) -> Filter? {
        var t = Substring(token)
        var negated = false
        if t.first == "-" {
            negated = true
            t = t.dropFirst()
        }
        // Key is the leading run of letters.
        let key = String(t.prefix { $0.isLetter }).lowercased()
        guard !key.isEmpty, let field = fields[key] else { return nil }
        var rest = t.dropFirst(key.count)

        let op: FilterOp
        if rest.hasPrefix(">=") { op = .ge; rest = rest.dropFirst(2) }
        else if rest.hasPrefix("<=") { op = .le; rest = rest.dropFirst(2) }
        else if rest.hasPrefix(">") { op = .gt; rest = rest.dropFirst(1) }
        else if rest.hasPrefix("<") { op = .lt; rest = rest.dropFirst(1) }
        else if rest.hasPrefix("=") { op = .eq; rest = rest.dropFirst(1) }
        else if rest.hasPrefix(":") { op = .eq; rest = rest.dropFirst(1) }
        else { return nil }

        let value = unquote(String(rest)).lowercased()
        guard !value.isEmpty else { return nil }
        return Filter(field: field, op: op, value: value, negated: negated)
    }

    /// Strips a single pair of surrounding double quotes if present.
    private static func unquote(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        return String(s.dropFirst().dropLast())
    }
}
