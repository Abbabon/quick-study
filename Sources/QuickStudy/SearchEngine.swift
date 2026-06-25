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
    private var minisByID: [String: Card.Mini] = [:]

    public init(minis: [Card.Mini] = [], sets: [Card.SetGroup] = []) {
        load(minis, sets: sets)
    }

    public func load(_ minis: [Card.Mini], sets: [Card.SetGroup] = []) {
        self.minis = minis
        self.setGroups = sets
        self.minisByID = Dictionary(minis.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Returns up to `limit` cards ranked best-first. A card scores by the best of its name
    /// match and any set (code/name) match that includes it.
    public func search(_ query: String, limit: Int = 20) -> [Card.Mini] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

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
        for g in setGroups {
            var base: Int? = Self.setCodeScoreBase(query: q, code: g.code.lowercased())
            if let s = Self.setNameScoreBase(query: q, setName: g.name.lowercased()) {
                base = max(base ?? Int.min, s)
            }
            guard let setBase = base else { continue }
            for id in g.memberIDs {
                guard let m = minisByID[id] else { continue }
                let cand = setBase + Self.lengthBonus(m.nameLower)
                if cand > (bestByID[id] ?? Int.min) { bestByID[id] = cand }
            }
        }

        let scored = bestByID.compactMap { (id, score) -> (Int, Card.Mini)? in
            guard let m = minisByID[id] else { return nil }
            return (score, m)
        }
        return scored.sorted { $0.0 > $1.0 }.prefix(limit).map { $0.1 }
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
