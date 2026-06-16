import XCTest
import Shared

final class CardStoreRecentTests: XCTestCase {
    private func makeStore() throws -> CardStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qs-recent-\(UUID().uuidString).sqlite")
        return try CardStore(url: url)
    }

    private func card(_ id: String, _ name: String, daysAgo: Int) -> Card {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return Card(id: id, name: name, manaCost: nil, typeLine: nil, oracleText: nil,
                    power: nil, toughness: nil, colors: [], imagePath: nil, scryfallURI: "",
                    setCode: "TST", setName: "Test Set", dateAdded: f.string(from: date))
    }

    func testRecentlyAddedNewestFirstWithinWindow() throws {
        let store = try makeStore()
        try store.upsert([
            card("a", "Alpha", daysAgo: 1),
            card("b", "Bravo", daysAgo: 5),
            card("c", "Charlie", daysAgo: 40),   // outside 30-day window
        ])
        let recent = try store.recentlyAdded(lookbackDays: 30, limit: 200)
        XCTAssertEqual(recent.map(\.id), ["a", "b"])
        XCTAssertEqual(recent.first?.setName, "Test Set")
    }

    func testRecentlyAddedExcludesFutureDates() throws {
        let store = try makeStore()
        try store.upsert([
            card("past", "Past Card", daysAgo: 3),
            card("future", "Unreleased Set Card", daysAgo: -45),  // releases in the future
        ])
        let recent = try store.recentlyAdded(lookbackDays: 30, limit: 200)
        XCTAssertEqual(recent.map(\.id), ["past"])  // future-dated card excluded
    }

    func testRecentlyAddedRespectsLimit() throws {
        let store = try makeStore()
        try store.upsert((0..<10).map { card("id\($0)", "Card \($0)", daysAgo: $0) })
        let recent = try store.recentlyAdded(lookbackDays: 30, limit: 3)
        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(recent.map(\.id), ["id0", "id1", "id2"])
    }

    func testUpsertDoesNotOverwriteExistingDateAdded() throws {
        let store = try makeStore()
        try store.upsert([card("a", "Alpha", daysAgo: 2)])
        // Re-upsert the same id with a much older date_added — should be ignored (COALESCE).
        try store.upsert([card("a", "Alpha Renamed", daysAgo: 100)])
        let recent = try store.recentlyAdded(lookbackDays: 30, limit: 200)
        XCTAssertEqual(recent.map(\.id), ["a"])  // still within window → original date kept
        XCTAssertEqual(recent.first?.name, "Alpha Renamed")  // other fields do update
    }
}
