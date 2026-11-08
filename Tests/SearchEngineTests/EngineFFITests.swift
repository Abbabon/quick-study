import XCTest
import EngineBindings
@testable import Shared

/// Thin smoke test through the UniFFI boundary. The golden ranking and query-parser cases live
/// in Rust (`engine/tests/search.rs`, `engine/src/query.rs`); this checks the Swift side wires up.
final class EngineFFITests: XCTestCase {
    private func seededIndex() throws -> (SearchIndex, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qs-ffi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("cards.sqlite")
        let store = try CardStore(url: url)
        func card(_ id: String, _ name: String) -> Card {
            Card(id: id, name: name, manaCost: nil, typeLine: "Instant", oracleText: nil, power: nil, toughness: nil,
                 colors: ["R"], imagePath: nil, scryfallURI: "", setCode: "LEA", setName: "Alpha",
                 oracleID: "o-\(id)", dateAdded: nil, rarity: "common", cmc: 1)
        }
        try store.upsert([card("bolt", "Lightning Bolt"), card("shock", "Shock")])
        return (try SearchIndex.open(dbPath: url.path), dir)
    }

    func testSearchesTheDatabaseAndMarshalsHits() throws {
        let (index, dir) = try seededIndex()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(index.cardCount(), 2)
        let r = index.search(query: "bolt")
        XCTAssertEqual(r.total, 1)
        XCTAssertEqual(r.hits.first?.id, "bolt")
        XCTAssertEqual(r.hits.first?.name, "Lightning Bolt")
        XCTAssertEqual(index.searchName(name: "sh", limit: 8).map(\.id), ["shock"])
        XCTAssertEqual(index.search(query: "").total, 0)
    }

    func testEmptyIndexAndMissingDatabase() {
        XCTAssertEqual(SearchIndex.empty().search(query: "bolt").total, 0)
        XCTAssertThrowsError(try SearchIndex.open(dbPath: "/nonexistent/cards.sqlite"))
    }
}
