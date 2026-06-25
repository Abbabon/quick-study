import XCTest
import Shared

final class CardStoreListsTests: XCTestCase {
    private func makeStore() throws -> CardStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qs-lists-\(UUID().uuidString).sqlite")
        return try CardStore(url: url)
    }

    private func card(_ id: String, _ name: String) -> Card {
        Card(id: id, name: name, manaCost: nil, typeLine: nil, oracleText: nil,
             power: nil, toughness: nil, colors: [], imagePath: nil, scryfallURI: "",
             setCode: "TST", setName: "Test Set", dateAdded: nil)
    }

    func testCreateListAppearsWithZeroItems() throws {
        let store = try makeStore()
        let created = try store.createList(name: "Pauper")
        let lists = try store.loadLists()
        XCTAssertEqual(lists.map(\.id), [created.id])
        XCTAssertEqual(lists.first?.name, "Pauper")
        XCTAssertEqual(lists.first?.itemCount, 0)
    }

    func testListsOrderedByCreation() throws {
        let store = try makeStore()
        let a = try store.createList(name: "First")
        let b = try store.createList(name: "Second")
        let c = try store.createList(name: "Third")
        XCTAssertEqual(try store.loadLists().map(\.id), [a.id, b.id, c.id])
    }

    func testAddCardIsIdempotentAndCounts() throws {
        let store = try makeStore()
        try store.upsert([card("a", "Alpha"), card("b", "Bravo")])
        let list = try store.createList(name: "Deck")

        try store.addCard(cardID: "a", toList: list.id)
        try store.addCard(cardID: "b", toList: list.id)
        try store.addCard(cardID: "a", toList: list.id)   // duplicate — no-op

        let items = try store.listItems(listID: list.id)
        XCTAssertEqual(items.map(\.id), ["a", "b"])        // insertion order via position
        XCTAssertEqual(try store.loadLists().first?.itemCount, 2)
    }

    func testReorderReflectedInListItems() throws {
        let store = try makeStore()
        try store.upsert([card("a", "Alpha"), card("b", "Bravo"), card("c", "Charlie")])
        let list = try store.createList(name: "Deck")
        for id in ["a", "b", "c"] { try store.addCard(cardID: id, toList: list.id) }

        try store.setListOrder(listID: list.id, orderedCardIDs: ["c", "a", "b"])
        XCTAssertEqual(try store.listItems(listID: list.id).map(\.id), ["c", "a", "b"])
    }

    func testRemoveCardDropsCount() throws {
        let store = try makeStore()
        try store.upsert([card("a", "Alpha"), card("b", "Bravo")])
        let list = try store.createList(name: "Deck")
        try store.addCard(cardID: "a", toList: list.id)
        try store.addCard(cardID: "b", toList: list.id)

        try store.removeCard(cardID: "a", fromList: list.id)
        XCTAssertEqual(try store.listItems(listID: list.id).map(\.id), ["b"])
        XCTAssertEqual(try store.loadLists().first?.itemCount, 1)
    }

    func testRenameList() throws {
        let store = try makeStore()
        let list = try store.createList(name: "Old")
        try store.renameList(id: list.id, name: "New")
        XCTAssertEqual(try store.loadLists().first?.name, "New")
    }

    func testDeleteListCascadesItems() throws {
        let store = try makeStore()
        try store.upsert([card("a", "Alpha")])
        let list = try store.createList(name: "Doomed")
        try store.addCard(cardID: "a", toList: list.id)

        try store.deleteList(id: list.id)
        XCTAssertTrue(try store.loadLists().isEmpty)
        // Membership rows are gone too — listItems on a deleted list returns nothing.
        XCTAssertTrue(try store.listItems(listID: list.id).isEmpty)
    }

    func testItemsScopedPerList() throws {
        let store = try makeStore()
        try store.upsert([card("a", "Alpha"), card("b", "Bravo")])
        let one = try store.createList(name: "One")
        let two = try store.createList(name: "Two")
        try store.addCard(cardID: "a", toList: one.id)
        try store.addCard(cardID: "b", toList: two.id)

        XCTAssertEqual(try store.listItems(listID: one.id).map(\.id), ["a"])
        XCTAssertEqual(try store.listItems(listID: two.id).map(\.id), ["b"])
    }
}
