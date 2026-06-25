import XCTest
import Shared

final class CardStorePrintingsTests: XCTestCase {
    func makeStore() throws -> CardStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qs-printings-\(UUID().uuidString).sqlite")
        return try CardStore(url: url)
    }

    func testOracleIDRoundTrips() throws {
        let store = try makeStore()
        let card = Card(id: "c1", name: "Lightning Bolt", manaCost: "{R}", typeLine: "Instant",
                        oracleText: nil, power: nil, toughness: nil, colors: ["R"],
                        imagePath: nil, scryfallURI: "", setCode: "LEA", setName: "Limited Edition Alpha",
                        oracleID: "oracle-bolt", dateAdded: "1993-08-05")
        try store.upsert([card])
        XCTAssertEqual(try store.card(id: "c1")?.oracleID, "oracle-bolt")
    }
}
