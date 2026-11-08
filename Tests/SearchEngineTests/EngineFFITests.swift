import XCTest
import SQLite3
import EngineBindings
@testable import Shared
@testable import QuickStudy

/// Thin smoke tests through the UniFFI boundary. The golden ranking, query-parser and store cases
/// live in Rust (`engine/tests/`, `engine/src/query.rs`); this checks the Swift side wires up.
final class EngineFFITests: XCTestCase {
    /// A migrated scratch DB with two cards (rows inserted with the system SQLite).
    private func seededDB() throws -> (Database, String, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qs-ffi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("cards.sqlite").path
        let db = try Database.open(dbPath: path)
        var h: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &h), SQLITE_OK)
        defer { sqlite3_close(h) }
        for (id, name) in [("bolt", "Lightning Bolt"), ("shock", "Shock")] {
            let sql = """
                INSERT INTO cards (id, name, name_lower, colors, scryfall_uri, type_line, set_code, set_name, oracle_id, rarity, cmc, first_seen)
                VALUES ('\(id)', '\(name)', '\(name.lowercased())', '["R"]', 'u', 'Instant', 'LEA', 'Alpha', 'o-\(id)', 'common', 1, date('now'))
                """
            XCTAssertEqual(sqlite3_exec(h, sql, nil, nil, nil), SQLITE_OK)
        }
        return (db, path, dir)
    }

    func testSearchesTheDatabaseAndMarshalsHits() throws {
        let (_, path, dir) = try seededDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = try SearchIndex.open(dbPath: path)
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

    func testDatabaseReadsAndListsThroughFFI() throws {
        let (db, _, dir) = try seededDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(try db.cardCount(), 2)
        let card = try XCTUnwrap(try db.card(id: "bolt")).card
        XCTAssertEqual(card.name, "Lightning Bolt")
        XCTAssertEqual(card.colors, ["R"])
        XCTAssertNil(try db.card(id: "nope"))
        XCTAssertEqual(try db.recentlyAdded(lookbackDays: 30, limit: 10).compactMap(\.recent).count, 2)

        let list = try db.createList(name: "Deck")
        try db.addCard(cardId: "bolt", listId: list.id)
        try db.addCard(cardId: "shock", listId: list.id)
        try db.setListOrder(listId: list.id, orderedCardIds: ["shock", "bolt"])
        XCTAssertEqual(try db.listItems(listId: list.id).map(\.id), ["shock", "bolt"])
        try db.renameList(id: list.id, name: "Burn")
        XCTAssertEqual(try db.loadLists().map(\.name), ["Burn"])
        XCTAssertEqual(try db.loadLists().first?.itemCount, 2)
        try db.deleteList(id: list.id)
        XCTAssertTrue(try db.loadLists().isEmpty)
    }

    func testStampHelpers() {
        XCTAssertTrue(isNewerThanIngested(remote: "2024-06-10T09:00:31.443+00:00", ingested: "2024-06-01T09:00:00.000+00:00"))
        XCTAssertFalse(isNewerThanIngested(remote: "2024-06-10T09:00:31.443+00:00", ingested: nil))
        XCTAssertNotNil(stampDate("2024-06-10T09:00:31+00:00"))
        XCTAssertNil(stampDate("garbage"))
    }

    /// Opt-in (skips without a local DB): opens a copy of the real DB with no migration re-run
    /// and exercises list edits on it.
    func testRealDatabaseCopyKeepsListsAndIsEditable() throws {
        let src = Paths.databaseURL
        guard FileManager.default.fileExists(atPath: src.path) else { throw XCTSkip("No local QuickStudy DB") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qs-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dst = dir.appendingPathComponent("cards.sqlite")
        for suffix in ["", "-wal"] {
            let s = URL(fileURLWithPath: src.path + suffix)
            if FileManager.default.fileExists(atPath: s.path) { try FileManager.default.copyItem(at: s, to: URL(fileURLWithPath: dst.path + suffix)) }
        }
        let db = try Database.open(dbPath: dst.path)
        let before = try db.loadLists()
        let items = try before.map { try db.listItems(listId: $0.id).count }
        XCTAssertEqual(items, before.map { Int($0.itemCount) }.map { $0 }, "listItems joins cards; counts match unless a card vanished")
        let l = try db.createList(name: "scratch")
        try db.renameList(id: l.id, name: "scratch2")
        if let c = try db.recentlyAdded(lookbackDays: 3650, limit: 1).first { try db.addCard(cardId: c.id, listId: l.id) }
        try db.deleteList(id: l.id)
        XCTAssertEqual(try db.loadLists().map(\.id), before.map(\.id))
    }
}
