import XCTest
import Shared

/// Reconciliation removes `cards` rows the latest ingest no longer produces — stale
/// orphans left behind when Scryfall changes an oracle card's representative printing
/// id, plus junk layouts an older fetcher ingested before they were filtered. These
/// rows accumulate with NULL oracle_id and surface in search with no image/set/printings.
final class CardStoreReconcileTests: XCTestCase {
    private func makeStore() throws -> CardStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qs-reconcile-\(UUID().uuidString).sqlite")
        return try CardStore(url: url)
    }

    private func card(_ id: String, _ name: String) -> Card {
        Card(id: id, name: name, manaCost: nil, typeLine: nil, oracleText: nil,
             power: nil, toughness: nil, colors: [], imagePath: nil, scryfallURI: "",
             setCode: "TST", setName: "Test Set", dateAdded: nil)
    }

    func testRemovesStaleRowsNotInKeepSet() throws {
        let store = try makeStore()
        try store.upsert([card("a", "Alpha"), card("b", "Bravo"), card("c", "Charlie")])

        let removed = try store.reconcileCards(keepingIDs: ["a", "b"])

        XCTAssertEqual(removed, 1)
        XCTAssertNotNil(try store.card(id: "a"))
        XCTAssertNotNil(try store.card(id: "b"))
        XCTAssertNil(try store.card(id: "c"))
    }

    func testNoOpWhenNothingStale() throws {
        let store = try makeStore()
        try store.upsert([card("a", "Alpha"), card("b", "Bravo")])

        let removed = try store.reconcileCards(keepingIDs: ["a", "b"])

        XCTAssertEqual(removed, 0)
        XCTAssertEqual(try store.count(), 2)
    }

    /// The Doomsday case: a list points at the old representative id; after a refresh
    /// the card's id changes. Reconcile must move the list entry onto the surviving
    /// same-name row, not silently drop the card from the user's wishlist.
    func testRemapsListEntryToSurvivingSameNameCard() throws {
        let store = try makeStore()
        try store.upsert([card("old", "Doomsday")])
        let list = try store.createList(name: "Wishlist")
        try store.addCard(cardID: "old", toList: list.id)

        // A later ingest introduces the new representative id alongside the stale one.
        try store.upsert([card("new", "Doomsday")])
        let removed = try store.reconcileCards(keepingIDs: ["new"])

        XCTAssertEqual(removed, 1)
        XCTAssertNil(try store.card(id: "old"))
        XCTAssertNotNil(try store.card(id: "new"))
        XCTAssertEqual(try store.listItems(listID: list.id).map(\.id), ["new"])
    }

    /// If the survivor is already in the same list, the remap must not create a
    /// duplicate — the stale entry is just dropped.
    func testRemapDoesNotDuplicateWhenSurvivorAlreadyInList() throws {
        let store = try makeStore()
        try store.upsert([card("old", "Doomsday"), card("new", "Doomsday")])
        let list = try store.createList(name: "Wishlist")
        try store.addCard(cardID: "new", toList: list.id)
        try store.addCard(cardID: "old", toList: list.id)

        try store.reconcileCards(keepingIDs: ["new"])

        XCTAssertEqual(try store.listItems(listID: list.id).map(\.id), ["new"])
    }

    /// A stale card with no surviving same-name twin (genuinely gone from Scryfall)
    /// is removed, and its dangling list entry is cleaned up rather than left behind.
    func testDropsDanglingListEntryWhenNoSurvivor() throws {
        let store = try makeStore()
        try store.upsert([card("a", "Alpha"), card("x", "Lonely")])
        let list = try store.createList(name: "Wishlist")
        try store.addCard(cardID: "x", toList: list.id)

        try store.reconcileCards(keepingIDs: ["a"])

        XCTAssertNil(try store.card(id: "x"))
        XCTAssertTrue(try store.listItems(listID: list.id).isEmpty)
    }
}
