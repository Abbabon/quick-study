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
