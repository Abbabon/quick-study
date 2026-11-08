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
    /// Set groups with `code` pre-lowercased plus their member mini indices.
    private var setCodes: [String] = []
    private var setMembers: [[Int]] = []
    /// Per-card metadata for inline filters, by mini index. nil when a card has no entry —
    /// then positive filters fail (the card is treated as having no metadata).
    private var fields: [Card.FilterFields?] = []
    /// Per mini: W/U/B/R/G bits of its colors, plus `noColorsBit` when its colors list is empty.
    private var colorMasks: [UInt8] = []
    /// Per mini: whether its lowercased type line / oracle text is `isSimpleText`.
    private var simpleText: [(type: Bool, oracle: Bool)] = []
    /// Lowercased set code -> canonical indices of member cards, for the `s:` filter.
    private var setMembersByCode: [String: Set<Int>] = [:]

    // Per-keystroke work runs on data prepared once in `load`. The scan used to run Swift String
    // operations (Character-level `contains`, `split`, `Array(name)`) and String-keyed
    // dictionaries on every card for every keystroke: ~45 ms p50 on 35k cards. Names made only of
    // printable ASCII (all but ~100) are now matched on raw bytes, which is exactly equivalent
    // for ASCII; anything else falls back to the original String scorer, so ranking is unchanged.
    /// Card names (indices 0..<minis.count) followed by set names, flattened.
    private var names = FlatNames()
    /// Index of the first mini with the same id (scores aggregate per id).
    private var canonical: [Int] = []
    /// Position of each mini in (nameLower, id, index) order: an Int tiebreak equivalent to
    /// comparing the strings.
    private var rank: [Int] = []
    /// Scratch buffers reused across searches (`best` is Int.min where unscored).
    private var best: [Int] = []
    private var touched: [Int] = []

    private static let noColorsBit: UInt8 = 0x80

    /// Tests only: score every name with the original String implementation (no byte fast
    /// path, no prefilters), as the reference the fast path must match exactly.
    var referenceScoring = false

    public init(minis: [Card.Mini] = [], sets: [Card.SetGroup] = [],
                filterFields: [String: Card.FilterFields] = [:]) {
        load(minis, sets: sets, filterFields: filterFields)
    }

    public func load(_ minis: [Card.Mini], sets: [Card.SetGroup] = [],
                     filterFields: [String: Card.FilterFields] = [:]) {
        self.minis = minis
        self.setGroups = sets
        var firstIndex: [String: Int] = [:]
        firstIndex.reserveCapacity(minis.count)
        canonical = minis.indices.map { i in
            if let f = firstIndex[minis[i].id] { return f }
            firstIndex[minis[i].id] = i
            return i
        }
        let order = minis.indices.sorted { a, b in
            if minis[a].nameLower != minis[b].nameLower { return minis[a].nameLower < minis[b].nameLower }
            if minis[a].id != minis[b].id { return minis[a].id < minis[b].id }
            return a < b
        }
        rank = Array(repeating: 0, count: minis.count)
        for (r, i) in order.enumerated() { rank[i] = r }

        fields = minis.map { filterFields[$0.id] }
        colorMasks = fields.map { f in
            guard let colors = f?.colors else { return Self.noColorsBit }
            if colors.isEmpty { return Self.noColorsBit }
            return colors.reduce(0) { $0 | Self.colorBit($1.uppercased()) }
        }
        simpleText = fields.map { f in
            (f?.typeLineLower.map(Self.isSimpleText) ?? false, f?.oracleTextLower.map(Self.isSimpleText) ?? false)
        }
        setCodes = sets.map { $0.code.lowercased() }
        setMembers = sets.map { $0.memberIDs.compactMap { firstIndex[$0] } }
        setMembersByCode = [:]
        for (code, members) in zip(setCodes, setMembers) {
            setMembersByCode[code, default: []].formUnion(members)
        }

        names = FlatNames()
        for m in minis { names.append(m.nameLower) }
        for g in sets { names.append(g.name.lowercased()) }
        best = Array(repeating: Int.min, count: minis.count)
        touched = []
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
        let compiled = filters.map(CompiledFilter.init)
        if q.isEmpty {
            guard !filters.isEmpty else { return ([], 0) }
            // Filter-only browse (e.g. `c:r`): order by shortest name. Top-k avoids
            // sorting the whole match set — broad filters can match thousands of cards.
            let candidates = minis.indices.lazy.filter { self.passes(compiled, $0) }
            let rank = self.rank, names = self.names
            let (top, total) = Self.selectTopK(from: candidates, limit: limit) { a, b in
                let la = names.lengthBonus(a), lb = names.lengthBonus(b)
                if la != lb { return la > lb }
                return rank[a] < rank[b]
            }
            return (top.map { minis[$0] }, total)
        }

        // Take the scratch buffers out of `self` so the hot loops don't pay exclusivity checks.
        var best = self.best, touched = self.touched
        self.best = []; self.touched = []
        touched.removeAll(keepingCapacity: true)
        defer {
            for c in touched { best[c] = Int.min }
            self.best = best; self.touched = touched
        }

        let query = Query(q)
        let fast = query.bytes != nil
        let minis = self.minis, canonical = self.canonical   // locals: no per-access exclusivity checks
        let qbytes = query.bytes ?? []
        qbytes.withUnsafeBufferPointer { qp in names.withBuffers { flat in
            // Name matches.
            for i in 0..<minis.count {
                let score: Int?
                if referenceScoring {
                    score = Self.score(query: q, name: minis[i].nameLower)
                } else if flat.mask(i) & query.mask != query.mask {
                    continue
                } else if flat.isFast(i) {
                    if query.needsNonASCII { continue }
                    score = fast ? flat.score(query, qp, i) : Self.score(query: q, name: minis[i].nameLower)
                } else {
                    score = Self.score(query: q, name: minis[i].nameLower)
                }
                guard let s = score else { continue }
                let c = canonical[i]
                if best[c] == Int.min { touched.append(c) }
                if s > best[c] { best[c] = s }
            }

            // Set matches: a matching set contributes every member card, scored in a band below
            // high-confidence name matches. This is what makes "modern horizons" return the whole
            // set rather than the few cards whose representative printing happens to be that set.
            for (k, code) in setCodes.enumerated() {
                var base: Int? = Self.setCodeScoreBase(query: q, code: code)
                let j = minis.count + k
                let nameBase = fast && flat.isFast(j) && !referenceScoring
                    ? flat.setNameScoreBase(query, qp, j)
                    : Self.setNameScoreBase(query: q, setName: setGroups[k].name.lowercased())
                if let s = nameBase { base = max(base ?? Int.min, s) }
                guard let setBase = base else { continue }
                for c in setMembers[k] {
                    let cand = setBase + flat.lengthBonus(c)
                    if best[c] == Int.min { touched.append(c) }
                    if cand > best[c] { best[c] = cand }
                }
            }
        } }

        // Rank by score (desc), with a deterministic name/id tiebreak (`rank`). Top-k
        // selection avoids materializing + fully sorting every scored candidate each keystroke.
        let candidates = touched.lazy.compactMap { c -> (Int, Int)? in
            if !compiled.isEmpty && !self.passes(compiled, c) { return nil }
            return (best[c], c)
        }
        let rank = self.rank
        let (top, total) = Self.selectTopK(from: candidates, limit: limit) { a, b in
            if a.0 != b.0 { return a.0 > b.0 }
            return rank[a.1] < rank[b.1]
        }
        return (top.map { minis[$0.1] }, total)
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

    /// A filter with its per-search work (parsing, lowering, mask building) done once.
    private struct CompiledFilter {
        let filter: Filter
        let colorWant: UInt8
        let manaTarget: Double?
        /// UTF-8 of the value when it is "simple" (see `isSimpleText`), for byte search.
        let simpleValue: [UInt8]?

        init(_ f: Filter) {
            filter = f
            colorWant = SearchEngine.colorSet(f.value).reduce(0) { $0 | SearchEngine.colorBit($1) }
            manaTarget = Double(f.value)
            simpleValue = SearchEngine.isSimpleText(f.value) ? Array(f.value.utf8) : nil
        }
    }

    /// True if mini `i` satisfies every filter (each filter ANDs with the rest).
    private func passes(_ filters: [CompiledFilter], _ i: Int) -> Bool {
        filters.allSatisfy { matches($0, i) }
    }

    private func matches(_ cf: CompiledFilter, _ i: Int) -> Bool {
        let filter = cf.filter
        let raw: Bool
        // Reads `fields[i]?.x` per case rather than copying the whole struct (4 refcounts).
        switch filter.field {
        case .rarity:
            raw = matchesRarity(filter, fields[i]?.rarities ?? [])
        case .color:
            // Colors ⊇ requested (Scryfall's "at least these colors"); `c`/`colorless` means none.
            let have = colorMasks[i]
            raw = cf.colorWant == 0 ? have == Self.noColorsBit : have & cf.colorWant == cf.colorWant
        case .type:
            raw = fields[i]?.typeLineLower.map { Self.contains($0, simpleText[i].type, cf) } ?? false
        case .oracle:
            raw = fields[i]?.oracleTextLower.map { Self.contains($0, simpleText[i].oracle, cf) } ?? false
        case .manaValue:
            raw = matchesManaValue(filter.op, fields[i]?.cmc, cf.manaTarget)
        case .set:
            raw = (minis[i].setCodeLower == filter.value)
                || (setMembersByCode[filter.value]?.contains(canonical[i]) ?? false)
        }
        return filter.negated ? !raw : raw
    }

    /// `text.contains(value)`: a byte search when both sides are simple text (exactly
    /// equivalent there), otherwise Swift's Character-level `contains`.
    private static func contains(_ text: String, _ textIsSimple: Bool, _ cf: CompiledFilter) -> Bool {
        if let needle = cf.simpleValue, textIsSimple, let hit = text.utf8.withContiguousStorageIfAvailable({ hay in
            hay.count >= needle.count && memmem(hay.baseAddress, hay.count, needle, needle.count) != nil
        }) {
            return hit
        }
        return text.contains(cf.filter.value)
    }

    /// True when every Unicode scalar is its own grapheme and has no canonical-equivalence
    /// partner — then Character-level substring search equals UTF-8 byte search. Covers
    /// Latin-1/Extended (< U+0300, no combining marks), dashes/quotes/bullets, arrows and minus;
    /// excludes CR (CRLF is one grapheme). Everything else takes the String path.
    static func isSimpleText(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { u in
            let v = u.value
            return (v < 0x300 && v != 0x0D) || (0x2010...0x2027).contains(v)
                || (0x2030...0x205E).contains(v) || (0x2190...0x21FF).contains(v) || v == 0x2212
        }
    }

    static func colorBit(_ c: String) -> UInt8 {
        switch c {
        case "W": return 1
        case "U": return 2
        case "B": return 4
        case "R": return 8
        case "G": return 16
        default: return 0
        }
    }

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


    private func matchesManaValue(_ op: FilterOp, _ cmc: Double?, _ target: Double?) -> Bool {
        guard let cmc, let target else { return false }
        switch op {
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

/// Built off the main actor at launch, then handed to (and only used on) the main actor.
extension SearchEngine: @unchecked Sendable {}

/// A trimmed, lowercased query prepared for byte matching.
struct Query {
    /// UTF-8 bytes, or nil when not all printable ASCII (then only the String path is used).
    let bytes: [UInt8]?
    let hasSpace: Bool
    /// Byte ranges of the space-separated words (empty words omitted, like `split`).
    let words: [Range<Int>]

    /// `FlatNames.mask` bits every matching name must have: each layer (exact … subsequence)
    /// needs every query Character to appear in the name, so a name missing one of the
    /// query's ASCII characters can't match. Pure prefilter — never changes a score.
    let mask: UInt64
    /// True when some query Character decomposes to a non-ASCII scalar: then no all-ASCII
    /// name can contain it, so those names are skipped without the String path.
    let needsNonASCII: Bool

    init(_ q: String) {
        let u = Array(q.utf8)
        bytes = u.allSatisfy { $0 >= 0x20 && $0 < 0x7F } ? u : nil
        hasSpace = u.contains(0x20)
        words = FlatNames.tokens(u)
        mask = FlatNames.mask(q.compactMap(\.asciiValue))
        needsNonASCII = q.decomposedStringWithCanonicalMapping.unicodeScalars.contains { !$0.isASCII }
    }
}

/// Lowercased names stored contiguously for the per-keystroke scan: one byte buffer plus
/// per-name spans and token bounds, so the loop does no allocation or reference counting.
struct FlatNames {
    fileprivate struct Span {
        var start: Int32
        /// Byte count, or -1 when the name isn't all printable ASCII (String path only).
        var count: Int32
        var tokenStart: Int32
        var tokenCount: Int32
        var lengthBonus: Int32
        /// `FlatNames.mask` of the name's ASCII bytes (of its NFD form, so a Character
        /// canonically equal to an ASCII one still sets that bit).
        var mask: UInt64
    }
    private var bytes: [UInt8] = []
    private var spans: [Span] = []
    /// (start, end) byte offsets relative to the name's start, two entries per token.
    private var tokenBounds: [Int32] = []

    mutating func append(_ lower: String) {
        let u = Array(lower.utf8)
        let ascii = u.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
        let toks = ascii ? Self.tokens(u) : []
        spans.append(Span(start: Int32(bytes.count), count: ascii ? Int32(u.count) : -1,
                          tokenStart: Int32(tokenBounds.count), tokenCount: Int32(toks.count),
                          lengthBonus: Int32(SearchEngine.lengthBonus(lower)),
                          mask: Self.mask(ascii ? u : Array(lower.decomposedStringWithCanonicalMapping.utf8))))
        if ascii { bytes += u }
        for t in toks { tokenBounds += [Int32(t.lowerBound), Int32(t.upperBound)] }
    }

    func lengthBonus(_ i: Int) -> Int { Int(spans[i].lengthBonus) }

    /// One bit per ASCII byte value (mod 64; collisions only weaken the prefilter).
    static func mask(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(0) { $1 < 0x80 ? $0 | (1 << UInt64($1 & 63)) : $0 }
    }

    static func tokens(_ u: [UInt8]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = -1
        for (i, b) in u.enumerated() {
            if b == 0x20 {
                if start >= 0 { out.append(start..<i); start = -1 }
            } else if start < 0 { start = i }
        }
        if start >= 0 { out.append(start..<u.count) }
        return out
    }

    func withBuffers<R>(_ body: (Buffers) -> R) -> R {
        bytes.withUnsafeBufferPointer { b in
            spans.withUnsafeBufferPointer { s in
                tokenBounds.withUnsafeBufferPointer { t in body(Buffers(bytes: b, spans: s, tokens: t)) }
            }
        }
    }

    struct Buffers {
        fileprivate let bytes: UnsafeBufferPointer<UInt8>
        fileprivate let spans: UnsafeBufferPointer<Span>
        fileprivate let tokens: UnsafeBufferPointer<Int32>

        func isFast(_ i: Int) -> Bool { spans[i].count >= 0 }
        func lengthBonus(_ i: Int) -> Int { Int(spans[i].lengthBonus) }
        func mask(_ i: Int) -> UInt64 { spans[i].mask }

        private func name(_ s: Span) -> UnsafeBufferPointer<UInt8> {
            UnsafeBufferPointer(rebasing: bytes[Int(s.start)..<Int(s.start + s.count)])
        }

        @inline(__always)
        private static func equal(_ a: UnsafeBufferPointer<UInt8>, _ at: Int,
                                  _ b: UnsafeBufferPointer<UInt8>, _ w: Range<Int>) -> Bool {
            var k = 0
            while k < w.count {
                if a[at + k] != b[w.lowerBound + k] { return false }
                k += 1
            }
            return true
        }

        /// `SearchEngine.score(query:name:)` on bytes. Requires `isFast(i)`; `qp` is the ASCII
        /// query's bytes.
        func score(_ q: Query, _ qp: UnsafeBufferPointer<UInt8>, _ i: Int) -> Int? {
            let s = spans[i]
            let n = name(s), nc = n.count, qc = qp.count
            let bonus = Int(s.lengthBonus)
            // Subsequence first: every layer implies it, so most non-matching names are
            // rejected in this one pass. Spread = first to last greedily matched char.
            var qi = 0, first = -1, last = -1
            for j in 0..<nc where n[j] == qp[qi] {
                if first < 0 { first = j }
                last = j
                qi += 1
                if qi == qc { break }
            }
            guard qi == qc else { return nil }
            let q0 = qp[0]
            if nc >= qc && n[0] == q0 && Self.equal(n, 0, qp, 0..<qc) {
                return (nc == qc ? 1000 : 800) + bonus                      // exact / prefix
            }
            if !q.hasSpace && s.tokenCount > 0 && tokens[Int(s.tokenStart)] == 0 {
                // Common case (single-word query, name not starting with a space): one scan
                // finds both layers. An occurrence right after a space starts a later token
                // (token-start); any other occurrence is a substring.
                var substring = false
                if nc > qc {
                    for at in 1...(nc - qc) where n[at] == q0 && Self.equal(n, at, qp, 0..<qc) {
                        if n[at - 1] == 0x20 { return 600 + bonus }
                        substring = true
                    }
                }
                if substring { return 400 + bonus }
            } else {
                if tokenStart(q, qp, n, s) { return 600 + bonus }
                if nc > qc {                                                // substring
                    for at in 1...(nc - qc) where n[at] == q0 && Self.equal(n, at, qp, 0..<qc) {
                        return 400 + bonus
                    }
                }
            }
            return 200 - (last - first)                                     // subsequence
        }

        /// `SearchEngine.setNameScoreBase(query:setName:)` on bytes (same requirements).
        func setNameScoreBase(_ q: Query, _ qp: UnsafeBufferPointer<UInt8>, _ i: Int) -> Int? {
            let s = spans[i]
            let n = name(s)
            if n.count >= qp.count && Self.equal(n, 0, qp, 0..<qp.count) {
                return n.count == qp.count ? 450 : 350
            }
            return tokenStart(q, qp, n, s) ? 350 : nil
        }

        /// Byte version of `SearchEngine.matchesTokenStart`.
        private func tokenStart(_ q: Query, _ qp: UnsafeBufferPointer<UInt8>,
                                _ n: UnsafeBufferPointer<UInt8>, _ s: Span) -> Bool {
            let tc = Int(s.tokenCount), t0 = Int(s.tokenStart)
            func hasPrefix(_ k: Int, _ w: Range<Int>) -> Bool {
                let a = Int(tokens[t0 + 2 * k]), b = Int(tokens[t0 + 2 * k + 1])
                return w.count <= b - a && Self.equal(n, a, qp, w)
            }
            if !q.hasSpace {
                let whole = 0..<qp.count
                guard tc > 0, !hasPrefix(0, whole) else { return false }
                for k in 1..<tc where hasPrefix(k, whole) { return true }
                return false
            }
            let words = q.words
            if words.count > tc { return false }
            outer: for start in 0...(tc - words.count) {
                for (k, w) in words.enumerated() where !hasPrefix(start + k, w) { continue outer }
                return true
            }
            return false
        }
    }
}
