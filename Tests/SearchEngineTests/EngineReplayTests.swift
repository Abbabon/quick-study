import XCTest
@testable import QuickStudy
import Shared
import EngineBindings

/// Stage 2 gate (temporary, removed with the Swift engine): replays a large real-corpus query
/// set through the Swift `SearchEngine` and the Rust `SearchIndex` on a copy of the local DB;
/// top-20 ids, their order and the totals must be identical.
final class EngineReplayTests: XCTestCase {
    func testSwiftAndRustAgree() throws {
        let src = Paths.databaseURL
        guard FileManager.default.fileExists(atPath: src.path) else { throw XCTSkip("No local DB") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qs-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dst = dir.appendingPathComponent("cards.sqlite")
        for suffix in ["", "-wal"] {
            let s = URL(fileURLWithPath: src.path + suffix)
            if FileManager.default.fileExists(atPath: s.path) {
                try FileManager.default.copyItem(at: s, to: URL(fileURLWithPath: dst.path + suffix))
            }
        }
        let store = try CardStore(url: dst)
        let minis = try store.loadMinis()
        let sets = try store.loadSetIndex()
        let swift = SearchEngine(minis: minis, sets: sets, filterFields: try store.loadFilterFields())
        let rust = try SearchIndex.open(dbPath: dst.path)
        XCTAssertEqual(Int(rust.cardCount()), minis.count)

        let queries = Self.corpus(minis: minis, sets: sets)
        print("replay: \(queries.count) queries over \(minis.count) cards, \(sets.count) sets")
        var diffs: [String] = []
        var nonEmpty = 0
        for q in queries {
            let parsed = QueryParser.parse(q)
            let s = swift.searchCounted(name: parsed.name, filters: parsed.filters)
            let r = rust.search(query: q)
            let sIDs = s.matches.map(\.id), rIDs = r.hits.map(\.id)
            if s.total > 0 { nonEmpty += 1 }
            if sIDs != rIDs || s.total != Int(r.total) {
                diffs.append("\"\(q)\" swift=\(s.total) \(sIDs.prefix(3)) rust=\(r.total) \(rIDs.prefix(3))")
                continue
            }
            for (a, b) in zip(s.matches, r.hits) {
                if a.name != b.name || a.setCodeLower != b.setCode?.lowercased() || a.rarity != b.rarity
                    || a.identity != Card.Mini(id: b.id, name: b.name, colors: b.colors).identity {
                    diffs.append("\"\(q)\" payload differs for \(a.id)")
                    break
                }
            }
        }
        print("replay: \(queries.count) queries, \(nonEmpty) non-empty, \(diffs.count) diffs")
        for d in diffs.prefix(40) { print("  DIFF \(d)") }
        XCTAssertTrue(diffs.isEmpty, "\(diffs.count) of \(queries.count) queries differ")
    }

    static func corpus(minis: [Card.Mini], sets: [Card.SetGroup]) -> [String] {
        var out: [String] = []
        let filters = ["r:common", "r:u", "r>=rare", "r<rare", "c:r", "c:wu", "c:colorless", "c:g", "t:creature", "-t:land",
                       "t:legendary", "mv>=3", "mv=0", "mv<2", "o:flying", "o:\"draw a card\"", "-o:draw", "s:m21", "s:lea", "set:mh3",
                       "t:\"legendary creature\"", "o:é", "t:—", "c:rg t:elf"]
        for (k, m) in minis.enumerated() {
            let n = m.nameLower
            if k % 5 == 0 {
                // typing simulation: every prefix up to 14 characters
                for len in 1...min(n.count, 14) { out.append(String(n.prefix(len))) }
            }
            if k % 11 == 0 {
                let words = n.split(separator: " ").map(String.init)
                out.append(words.map { String($0.prefix(1)) }.joined())            // initialism
                out.append(String(n.enumerated().filter { $0.offset % 2 == 0 }.map(\.element).prefix(4)))
                if words.count >= 2 { out.append("\(words[0].prefix(3)) \(words[1].prefix(3))") }
                if words.count >= 1 { out.append(String(words.last!.prefix(4))) }
                out.append(String(n.dropFirst(2).prefix(4)))                          // substring
                out.append(n.uppercased())
            }
            if k % 40 == 0 {
                let first = String(n.split(separator: " ").first ?? "x")
                for f in filters { out.append("\(first.prefix(3)) \(f)") }
            }
            if k % 700 == 0 { out.append(n); out.append("\"\(n)\""); out.append("  \(n)  ") }
        }
        // non-ASCII names: every prefix, decomposed, ASCII-folded variants
        for m in minis where m.nameLower.unicodeScalars.contains(where: { !$0.isASCII }) {
            let n = m.nameLower
            for len in 1...min(n.count, 16) { out.append(String(n.prefix(len))) }
            out.append(n.decomposedStringWithCanonicalMapping)
            out.append(n.folding(options: .diacriticInsensitive, locale: nil))
            if let w = n.split(separator: " ").last { out.append(String(w)) }
        }
        out += ["é", "ö", "û", "á", "í", "ú", "ñ", "æ", "ae", "ß", "’", "'", "-", ",", "//", ".", "e\u{301}", "u\u{302}l", "ï", "ō", "ü", "œ",
                "a\u{308}", "n\u{303}", "σ", "ς", "İ", "ı", "ǆ", "ﬁ", "ǅ", "\u{212B}", "\u{212A}", "\u{2126}", "☃", "日本", "emoji😀", "\t", "bolt\t", "\n", "a\nb", "\r\n", "x\u{0}y"]
        // sets
        for g in sets {
            let c = g.code.lowercased(), n = g.name.lowercased()
            out += [c, n, "s:\(c)", "set:\(c) bolt", String(n.prefix(5)), String(n.prefix(9))]
            if let w = n.split(separator: " ").last { out.append(String(w)) }
            if n.count > 3 { out.append("\(n.prefix(4)) \(c)") }
        }
        // filter-only and odd syntax
        for f in filters { out.append(f) }
        out += ["o:", "t:", "c:", "r:", "mv:", "mv>=x", "mv:1.5", "mv:inf", "mv:nan", "c:wubrg", "c:xyz", "r:special", "r:bonus", "r>=special",
                "-", "--", "-bolt", "\"", "\"\"", "\"bolt", "bolt\"", "o:\"", "o:\"\"", "foo:bar", "bolt:", ":bolt", "t:land t:basic", "t:land -t:basic",
                "a b c d", "the of", "a", "e", "i", "o", "s", "t", "ll", "zz", "qq", "  ", "bolt   bolt", "lightning  bolt", "BOLT R:COMMON", "Mv>=3 Elf",
                "r>common", "r<=uncommon", "mv>3 mv<5", "o:é", "t:—", "t:–", "o:•", "o:{t}", "o:\"{t}:", "o:™", "o:\"\u{2122}\"", "t:\u{3b1}"]
        // names with a trailing/leading space or punctuation as a typed query
        for m in minis.prefix(500) { out.append(m.nameLower + " ") }
        return out
    }
}
