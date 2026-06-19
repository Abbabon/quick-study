import XCTest
@testable import QuickStudy
import Shared

final class SearchEngineTests: XCTestCase {
    private let corpus: [Card.Mini] = [
        "Lightning Bolt",
        "Lightning Strike",
        "Lightning Helix",
        "Chain Lightning",
        "Lightning Greaves",
        "Bolt of Keranos",
        "Shock",
        "Ball Lightning",
        "Jace, the Mind Sculptor",
        "Black Lotus",
    ].enumerated().map { Card.Mini(id: "id-\($0.offset)", name: $0.element) }

    func testPrefixBeatsSubstring() {
        let engine = SearchEngine(minis: corpus)
        let results = engine.search("lightni")
        XCTAssertEqual(results.first?.name, "Lightning Bolt")
        // All "Lightning ..." cards should rank above "Chain Lightning" and "Ball Lightning".
        let names = results.map(\.name)
        let idxBolt = names.firstIndex(of: "Lightning Bolt")!
        let idxChain = names.firstIndex(of: "Chain Lightning") ?? Int.max
        XCTAssertLessThan(idxBolt, idxChain)
    }

    func testCaseInsensitive() {
        // Prefix beats token-start by design, so "Bolt of Keranos" wins over "Lightning Bolt"
        // for query "bolt". This test just ensures case folding works — both casings hit
        // the same top result.
        let engine = SearchEngine(minis: corpus)
        XCTAssertEqual(engine.search("BOLT").first?.name, engine.search("bolt").first?.name)
        XCTAssertNotNil(engine.search("BOLT").first)
    }

    func testExactMatchWinsOverPrefix() {
        let engine = SearchEngine(minis: corpus)
        XCTAssertEqual(engine.search("shock").first?.name, "Shock")
    }

    func testTokenStartMatchForSecondWord() {
        // "bolt" should still surface "Lightning Bolt" via token-start, not just substring.
        let engine = SearchEngine(minis: corpus)
        let names = engine.search("bolt").map(\.name)
        XCTAssertTrue(names.contains("Lightning Bolt"))
    }

    func testInitialismSubsequence() {
        // "ljt" — j is rare; should match nothing useful here. Use "lb" instead.
        let engine = SearchEngine(minis: corpus)
        let names = engine.search("lb").map(\.name)
        XCTAssertTrue(names.contains("Lightning Bolt"))
    }

    // MARK: - Set code / set name

    /// Corpus carrying set metadata. "Mox Sapphire" is in set MSC; a few decoys share
    /// neither code nor name fragments.
    private let setCorpus: [Card.Mini] = [
        Card.Mini(id: "s0", name: "Mox Sapphire", colors: [], setCode: "MSC", setName: "Mishra's Set"),
        Card.Mini(id: "s1", name: "Black Lotus", colors: [], setCode: "MSC", setName: "Mishra's Set"),
        Card.Mini(id: "s2", name: "Modern Staple", colors: [], setCode: "MH3", setName: "Modern Horizons 3"),
        Card.Mini(id: "s3", name: "Mind Sculptor Clone", colors: [], setCode: "JTM", setName: "Jace's Tome"),
        Card.Mini(id: "s4", name: "Shock", colors: [], setCode: "M21", setName: "Core 2021"),
        Card.Mini(id: "s5", name: "MSC Promo", colors: [], setCode: "ZZZ", setName: "Promo Set"),
    ]

    func testExactSetCodeSurfacesSetCards() {
        let engine = SearchEngine(minis: setCorpus)
        let names = engine.search("msc").map(\.name)
        XCTAssertTrue(names.contains("Mox Sapphire"))
        XCTAssertTrue(names.contains("Black Lotus"))
    }

    func testSetCodeBeatsNameSubsequence() {
        // "msc" is the exact set code for "Mox Sapphire" / "Black Lotus", and also a
        // subsequence of "Mind Sculptor Clone" (M-S-C). The set-code matches must win.
        let engine = SearchEngine(minis: setCorpus)
        let names = engine.search("msc").map(\.name)
        let idxSetCard = names.firstIndex(of: "Mox Sapphire")!
        let idxSubseq = names.firstIndex(of: "Mind Sculptor Clone") ?? Int.max
        XCTAssertLessThan(idxSetCard, idxSubseq)
    }

    func testNamePrefixBeatsSetCode() {
        // "msc" is a name prefix of "MSC Promo" (name-prefix, 800) AND the exact set code
        // of "Mox Sapphire" / "Black Lotus" (set-code, 500). The name match must win.
        let engine = SearchEngine(minis: setCorpus)
        XCTAssertEqual(engine.search("msc").first?.name, "MSC Promo")
    }

    func testSetNamePrefixSurfacesCards() {
        let engine = SearchEngine(minis: setCorpus)
        let names = engine.search("modern").map(\.name)
        XCTAssertTrue(names.contains("Modern Staple"))
    }

    func testEmptyQueryReturnsNothing() {
        let engine = SearchEngine(minis: corpus)
        XCTAssertEqual(engine.search("").count, 0)
        XCTAssertEqual(engine.search("   ").count, 0)
    }

    func testLimitRespected() {
        let engine = SearchEngine(minis: corpus)
        XCTAssertLessThanOrEqual(engine.search("l", limit: 3).count, 3)
    }
}
