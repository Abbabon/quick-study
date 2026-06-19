import Foundation
import Shared

/// Hand-rolled in-memory fuzzy ranker for ~25k card names.
/// Designed for sub-millisecond response on every keystroke.
///
/// Scoring layers (higher = better). A card is ranked by the BEST of its name,
/// set-code, and set-name matches.
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
/// Set-code matching is exact-only (a deliberate 3-letter signal). Set-name matching
/// skips substring/subsequence — set names share filler words ("the"/"of") that would
/// otherwise flood results.
///
/// `lengthBonus` favors shorter names so "Bolt" beats "Lightning Bolt the Great Bolt of Bolting"
/// when the query is "bolt".
public final class SearchEngine {
    public private(set) var minis: [Card.Mini] = []

    public init(minis: [Card.Mini] = []) {
        self.minis = minis
    }

    public func load(_ minis: [Card.Mini]) {
        self.minis = minis
    }

    /// Returns up to `limit` IDs ranked best-first.
    public func search(_ query: String, limit: Int = 20) -> [Card.Mini] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

        var scored: [(score: Int, mini: Card.Mini)] = []
        scored.reserveCapacity(64)

        for m in minis {
            var best = Self.score(query: q, name: m.nameLower)
            if let code = m.setCodeLower, let s = Self.setCodeScore(query: q, code: code, name: m.nameLower) {
                best = max(best ?? Int.min, s)
            }
            if let setName = m.setNameLower, let s = Self.setNameScore(query: q, setName: setName) {
                best = max(best ?? Int.min, s)
            }
            if let s = best {
                scored.append((s, m))
            }
        }
        // Partial sort: we only need top `limit`.
        scored.sort { $0.score > $1.score }
        return scored.prefix(limit).map { $0.mini }
    }

    /// Pure scoring function. `nil` means no match.
    static func score(query q: String, name n: String) -> Int? {
        // 1. Exact match.
        if n == q {
            return 1000 + lengthBonus(n)
        }
        // 2. Prefix match.
        if n.hasPrefix(q) {
            return 800 + lengthBonus(n)
        }
        // 3. Token-start match (each whitespace-separated token).
        if matchesTokenStart(query: q, name: n) {
            return 600 + lengthBonus(n)
        }
        // 4. Substring match.
        if n.contains(q) {
            return 400 + lengthBonus(n)
        }
        // 5. Subsequence / initials.
        if let spread = subsequenceSpread(query: q, name: n) {
            // tighter spread is better (more contiguous)
            return 200 - spread
        }
        return nil
    }

    /// Exact-only set-code match. A 3-letter set code is a deliberate signal, so it
    /// ranks above weak name matches (substring/subsequence) but below high-confidence
    /// name matches (exact/prefix/token-start). `name` is used only for the tiebreak bonus.
    static func setCodeScore(query q: String, code: String, name: String) -> Int? {
        guard q == code else { return nil }
        return 500 + lengthBonus(name)
    }

    /// Fuzzy set-name match, in a band below name matches. Substring/subsequence are
    /// intentionally skipped — set names share filler words that would flood results.
    static func setNameScore(query q: String, setName n: String) -> Int? {
        if n == q {
            return 450 + lengthBonus(n)
        }
        if n.hasPrefix(q) || matchesTokenStart(query: q, name: n) {
            return 350 + lengthBonus(n)
        }
        return nil
    }

    private static func lengthBonus(_ n: String) -> Int {
        // Shorter names rank a bit higher: bonus is 100 for length 1, decaying.
        max(0, 100 - n.count)
    }

    /// True if `q` (possibly multi-word) matches the start of consecutive tokens in `n`.
    /// Also covers single-word queries that start a non-first token (e.g. "bolt" → "Lightning Bolt").
    private static func matchesTokenStart(query q: String, name n: String) -> Bool {
        let tokens = n.split(separator: " ").map(String.init)
        // Single-word query: any token startsWith.
        if !q.contains(" ") {
            return tokens.contains { $0.hasPrefix(q) } && !tokens.first!.hasPrefix(q)
            // If the first token already prefix-matches, the prefix-match rule above handled it.
        }
        // Multi-word query: each query word must prefix-match consecutive tokens.
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

    /// Walks `q` through `n` as a subsequence. Returns the "spread" (n.count from
    /// first match to last match) if all chars matched; nil otherwise.
    /// Initialism queries like "ljt" → "Lightning Jolt-like Token" produce small spreads.
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
        if qi == qChars.count {
            return lastIdx - firstIdx
        }
        return nil
    }
}
