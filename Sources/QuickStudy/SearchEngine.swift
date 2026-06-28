import Foundation
import Shared

/// Hand-rolled in-memory fuzzy ranker for ~25k card names.
/// Designed for sub-millisecond response on every keystroke.
///
/// Scoring layers (higher = better). A card is ranked by the BEST of its name
/// match and any set (code/name) match that includes it via the set index.
///   - 1000 + lengthBonus : name exact match (case-insensitive)
///   -  800 + lengthBonus : name prefix match
///   -  600 + lengthBonus : name token-start ("light bolt" -> "Lightning Bolt")
///   -  500 + lengthBonus : set-code EXACT match ("msc" -> all cards in set MSC)
///   -  450 + lengthBonus : set-name exact match
///   -  400 + lengthBonus : name substring match
///   -  350 + lengthBonus : set-name prefix / token-start match
///   -  200 - spread      : name subsequence/initials ("ljt" -> "Lightning Jolt-like Token")
///   - otherwise filtered out
///
/// Set matches use the set index (`[Card.SetGroup]`) so that a query like "modern horizons"
/// returns ALL member cards, not just the subset whose representative printing happens to be
/// that set. Set-code matching is exact-only (a deliberate 3-letter signal). Set-name matching
/// skips substring/subsequence — set names share filler words ("the"/"of") that would
/// otherwise flood results.
///
/// `lengthBonus` favors shorter names so "Bolt" beats "Lightning Bolt the Great Bolt of Bolting"
/// when the query is "bolt".
public final class SearchEngine {
    public private(set) var minis: [Card.Mini] = []
    private var setGroups: [Card.SetGroup] = []
    /// Set groups with `code`/`name` pre-lowercased, so the per-keystroke set-matching loop
    /// doesn't re-lowercase every set on every search.
    private var setGroupsLower: [(code: String, name: String, memberIDs: [String])] = []
    private var minisByID: [String: Card.Mini] = [:]
    /// Per-card metadata for inline filters, keyed by card id. Empty until loaded — when a
    /// card has no entry, positive filters fail (the card is treated as having no metadata).
    private var filterFields: [String: Card.FilterFields] = [:]
    /// Lowercased set code -> member card ids, derived from `setGroups`, for the `s:` filter.
    private var setMembersByCode: [String: Set<String>] = [:]

    public init(minis: [Card.Mini] = [], sets: [Card.SetGroup] = [],
                filterFields: [String: Card.FilterFields] = [:]) {
        load(minis, sets: sets, filterFields: filterFields)
    }

    public func load(_ minis: [Card.Mini], sets: [Card.SetGroup] = [],
                     filterFields: [String: Card.FilterFields] = [:]) {
        self.minis = minis
        self.setGroups = sets
        self.filterFields = filterFields
        self.minisByID = Dictionary(minis.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.setGroupsLower = sets.map { ($0.code.lowercased(), $0.name.lowercased(), $0.memberIDs) }
        self.setMembersByCode = Dictionary(
            sets.map { ($0.code.lowercased(), Set($0.memberIDs)) },
            uniquingKeysWith: { a, b in a.union(b) })
    }

    /// Legacy entry point: a single free-text query with no inline filters.
    public func search(_ query: String, limit: Int = 20) -> [Card.Mini] {
        search(name: query, filters: [], limit: limit)
    }

    /// Returns up to `limit` cards ranked best-first, narrowed by any inline `filters`.
    /// A card scores by the best of its name match and any set (code/name) match that
    /// includes it; filters are applied to the candidate set *before* the limit so they
    /// can't be hidden by ranking. With a name present, ranking drives the order; with an
    /// empty name but filters present, all matching cards are returned, shortest-name first.
    public func search(name: String, filters: [Filter], limit: Int = 20) -> [Card.Mini] {
        searchCounted(name: name, filters: filters, limit: limit).matches
    }

    /// Like `search(name:filters:limit:)` but also reports `total`: the number of cards that
    /// matched *before* the `limit` was applied, so the UI can indicate how many results exist
    /// beyond what it can display.
    public func searchCounted(name: String, filters: [Filter], limit: Int = 20) -> (matches: [Card.Mini], total: Int) {
        let q = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            guard !filters.isEmpty else { return ([], 0) }
            // Filter-only browse (e.g. `c:r`): order by shortest name. Top-k avoids
            // sorting the whole match set — broad filters can match thousands of cards.
            let candidates = minis.lazy.filter { self.passes(filters, $0) }
            let (top, total) = Self.selectTopK(from: candidates, limit: limit) { a, b in
                let la = Self.lengthBonus(a.nameLower), lb = Self.lengthBonus(b.nameLower)
                if la != lb { return la > lb }
                if a.nameLower != b.nameLower { return a.nameLower < b.nameLower }
                return a.id < b.id
            }
            return (top, total)
        }

        var bestByID: [String: Int] = [:]

        // Name matches.
        for m in minis {
            if let s = Self.score(query: q, name: m.nameLower) {
                if s > (bestByID[m.id] ?? Int.min) { bestByID[m.id] = s }
            }
        }

        // Set matches: a matching set contributes every member card, scored in a band below
        // high-confidence name matches. This is what makes "modern horizons" return the whole
        // set rather than the few cards whose representative printing happens to be that set.
        for g in setGroupsLower {
            var base: Int? = Self.setCodeScoreBase(query: q, code: g.code)
            if let s = Self.setNameScoreBase(query: q, setName: g.name) {
                base = max(base ?? Int.min, s)
            }
            guard let setBase = base else { continue }
            for id in g.memberIDs {
                guard let m = minisByID[id] else { continue }
                let cand = setBase + Self.lengthBonus(m.nameLower)
                if cand > (bestByID[id] ?? Int.min) { bestByID[id] = cand }
            }
        }

        // Rank by score (desc), with a deterministic name/id tiebreak. Top-k selection
        // avoids materializing + fully sorting every scored candidate each keystroke.
        let candidates = bestByID.lazy.compactMap { (id, score) -> (Int, Card.Mini)? in
            guard let m = self.minisByID[id] else { return nil }
            if !filters.isEmpty && !self.passes(filters, m) { return nil }
            return (score, m)
        }
        let (top, total) = Self.selectTopK(from: candidates, limit: limit) { a, b in
            if a.0 != b.0 { return a.0 > b.0 }
            if a.1.nameLower != b.1.nameLower { return a.1.nameLower < b.1.nameLower }
            return a.1.id < b.1.id
        }
        return (top.map { $0.1 }, total)
    }

    /// Selects the best `limit` elements (by `isBetter`, a strict total order) from
    /// `candidates` in a single pass, also returning the total candidate count. Keeps a
    /// sorted buffer of at most `limit` so broad queries never sort the whole match set.
    static func selectTopK<S: Sequence>(
        from candidates: S, limit: Int, isBetter: (S.Element, S.Element) -> Bool
    ) -> (matches: [S.Element], total: Int) {
        var top: [S.Element] = []
        if limit > 0 { top.reserveCapacity(limit) }
        var total = 0
        for c in candidates {
            total += 1
            guard limit > 0 else { continue }
            if top.count < limit {
                let idx = top.firstIndex { isBetter(c, $0) } ?? top.count
                top.insert(c, at: idx)
            } else if isBetter(c, top[limit - 1]) {
                let idx = top.firstIndex { isBetter(c, $0) } ?? top.count
                top.insert(c, at: idx)
                top.removeLast()
            }
        }
        return (top, total)
    }

    // MARK: - Inline filters

    /// True if `mini` satisfies every filter (each filter ANDs with the rest).
    private func passes(_ filters: [Filter], _ mini: Card.Mini) -> Bool {
        let fields = filterFields[mini.id]
        return filters.allSatisfy { matches($0, mini, fields) }
    }

    private func matches(_ filter: Filter, _ mini: Card.Mini, _ fields: Card.FilterFields?) -> Bool {
        let raw: Bool
        switch filter.field {
        case .rarity:
            raw = matchesRarity(filter, fields?.rarities ?? [])
        case .color:
            raw = matchesColor(filter, fields?.colors ?? [])
        case .type:
            raw = (fields?.typeLineLower?.contains(filter.value)) ?? false
        case .oracle:
            raw = (fields?.oracleTextLower?.contains(filter.value)) ?? false
        case .manaValue:
            raw = matchesManaValue(filter, fields?.cmc)
        case .set:
            raw = (mini.setCodeLower == filter.value)
                || (setMembersByCode[filter.value]?.contains(mini.id) ?? false)
        }
        return filter.negated ? !raw : raw
    }

    /// Rarity tiers, low to high, for `r>=rare`-style comparisons. Rarities outside this
    /// ladder (e.g. "special", "bonus") only ever match an exact `r:` query.
    private static let rarityRank: [String: Int] = [
        "common": 0, "uncommon": 1, "rare": 2, "mythic": 3,
    ]

    /// Canonicalizes a rarity filter value, accepting Scryfall's single-letter abbreviations.
    private static func canonRarity(_ v: String) -> String {
        switch v {
        case "c": return "common"
        case "u": return "uncommon"
        case "r": return "rare"
        case "m", "mythic rare": return "mythic"
        default: return v
        }
    }

    private func matchesRarity(_ filter: Filter, _ rarities: Set<String>) -> Bool {
        let target = Self.canonRarity(filter.value)
        guard filter.op != .eq, let tr = Self.rarityRank[target] else {
            // Exact match (`:`/`=`) or an off-ladder rarity: simple membership.
            return rarities.contains(target)
        }
        return rarities.contains { r in
            guard let rank = Self.rarityRank[r] else { return false }
            switch filter.op {
            case .gt: return rank > tr
            case .ge: return rank >= tr
            case .lt: return rank < tr
            case .le: return rank <= tr
            case .eq: return rank == tr
            }
        }
    }

    /// `c:r` / `c:wu` / `c:colorless`. A card matches when its colors are a superset of the
    /// requested colors (Scryfall's "at least these colors"); `c`/`colorless` means no colors.
    private func matchesColor(_ filter: Filter, _ cardColors: [String]) -> Bool {
        let have = Set(cardColors.map { $0.uppercased() })
        let want = Self.colorSet(filter.value)
        if want.isEmpty { return have.isEmpty }   // colorless request
        return want.isSubset(of: have)
    }

    private static func colorSet(_ v: String) -> Set<String> {
        switch v {
        case "white": return ["W"]
        case "blue": return ["U"]
        case "black": return ["B"]
        case "red": return ["R"]
        case "green": return ["G"]
        case "colorless": return []
        default: break
        }
        var s: Set<String> = []
        for ch in v {
            switch ch {
            case "w": s.insert("W")
            case "u": s.insert("U")
            case "b": s.insert("B")
            case "r": s.insert("R")
            case "g": s.insert("G")
            case "c": return []   // colorless
            default: break
            }
        }
        return s
    }

    private func matchesManaValue(_ filter: Filter, _ cmc: Double?) -> Bool {
        guard let cmc, let target = Double(filter.value) else { return false }
        switch filter.op {
        case .eq: return cmc == target
        case .gt: return cmc > target
        case .ge: return cmc >= target
        case .lt: return cmc < target
        case .le: return cmc <= target
        }
    }

    /// Pure name scoring. `nil` means no match.
    static func score(query q: String, name n: String) -> Int? {
        if n == q { return 1000 + lengthBonus(n) }       // exact
        if n.hasPrefix(q) { return 800 + lengthBonus(n) } // prefix
        if matchesTokenStart(query: q, name: n) { return 600 + lengthBonus(n) } // token-start
        if n.contains(q) { return 400 + lengthBonus(n) }  // substring
        if let spread = subsequenceSpread(query: q, name: n) { return 200 - spread } // subsequence
        return nil
    }

    /// Base score for an exact set-code match (the caller adds a per-member length bonus).
    /// Exact-only: a 3-letter code is a deliberate signal, ranked above weak name matches
    /// (substring/subsequence) but below high-confidence name matches.
    static func setCodeScoreBase(query q: String, code: String) -> Int? {
        q == code ? 500 : nil
    }

    /// Base score for a set-name match. Exact (450) or prefix/token-start (350). Substring
    /// and subsequence are intentionally skipped — set names share filler words that would
    /// otherwise flood results.
    static func setNameScoreBase(query q: String, setName n: String) -> Int? {
        if n == q { return 450 }
        if n.hasPrefix(q) || matchesTokenStart(query: q, name: n) { return 350 }
        return nil
    }

    static func lengthBonus(_ n: String) -> Int {
        // Shorter names rank a bit higher: bonus is 100 for length 1, decaying.
        max(0, 100 - n.count)
    }

    /// True if `q` (possibly multi-word) matches the start of consecutive tokens in `n`.
    /// Also covers single-word queries that start a non-first token (e.g. "bolt" → "Lightning Bolt").
    private static func matchesTokenStart(query q: String, name n: String) -> Bool {
        let tokens = n.split(separator: " ").map(String.init)
        if !q.contains(" ") {
            return tokens.contains { $0.hasPrefix(q) } && !(tokens.first?.hasPrefix(q) ?? true)
        }
        let qWords = q.split(separator: " ").map(String.init)
        if qWords.count > tokens.count { return false }
        outer: for start in 0...(tokens.count - qWords.count) {
            for (i, qw) in qWords.enumerated() {
                if !tokens[start + i].hasPrefix(qw) { continue outer }
            }
            return true
        }
        return false
    }

    /// Walks `q` through `n` as a subsequence. Returns the "spread" (distance from first to
    /// last matched char) if all chars matched; nil otherwise.
    private static func subsequenceSpread(query q: String, name n: String) -> Int? {
        let qChars = Array(q)
        let nChars = Array(n)
        var qi = 0
        var firstIdx = -1
        var lastIdx = -1
        for (i, c) in nChars.enumerated() {
            if qi < qChars.count && c == qChars[qi] {
                if firstIdx < 0 { firstIdx = i }
                lastIdx = i
                qi += 1
            }
        }
        return qi == qChars.count ? lastIdx - firstIdx : nil
    }
}
