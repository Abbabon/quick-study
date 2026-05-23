import Foundation
import Shared

/// Hand-rolled in-memory fuzzy ranker for ~25k card names.
/// Designed for sub-millisecond response on every keystroke.
///
/// Scoring layers (higher = better):
///   - 1000 + lengthBonus : exact match (case-insensitive)
///   -  800 + lengthBonus : prefix match
///   -  600 + tokenStartBonus : matches start of a word in the name ("light bolt" -> "Lightning Bolt")
///   -  400 + lengthBonus : substring match
///   -  200 + spreadPenalty : subsequence/initials match ("ljt" -> "Lightning Jolt-like Token")
///   - otherwise filtered out
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
            if let s = Self.score(query: q, name: m.nameLower) {
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
