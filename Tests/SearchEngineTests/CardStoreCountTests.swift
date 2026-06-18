import XCTest
import Shared

final class CardStoreCountTests: XCTestCase {
    private func makeStore() throws -> CardStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qs-count-\(UUID().uuidString).sqlite")
        return try CardStore(url: url)
    }

    private func card(_ id: String, _ name: String) -> Card {
        Card(id: id, name: name, manaCost: nil, typeLine: nil, oracleText: nil,
             power: nil, toughness: nil, colors: [], imagePath: nil, scryfallURI: "",
             setCode: "TST", setName: "Test Set", dateAdded: "2024-01-01")
    }

    func testCountIsZeroOnEmptyStore() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.count(), 0)
    }

    func testCountReflectsInsertedCards() throws {
        let store = try makeStore()
        try store.upsert([card("a", "Alpha"), card("b", "Bravo")])
        XCTAssertEqual(try store.count(), 2)
    }

    func testCountDoesNotDoubleCountUpserts() throws {
        let store = try makeStore()
        try store.upsert([card("a", "Alpha")])
        try store.upsert([card("a", "Alpha renamed")]) // same id → update, not insert
        XCTAssertEqual(try store.count(), 1)
    }
}
