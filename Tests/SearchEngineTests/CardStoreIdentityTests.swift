import XCTest
import Shared

final class CardStoreIdentityTests: XCTestCase {
    private func makeStore() throws -> CardStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qs-test-\(UUID().uuidString).sqlite")
        return try CardStore(url: url)
    }

    func testLoadMinisDerivesIdentityFromColors() throws {
        let store = try makeStore()
        try store.upsert([
            Card(id: "mono", name: "Shock", manaCost: "{R}", typeLine: "Instant",
                 oracleText: nil, power: nil, toughness: nil, colors: ["R"],
                 imagePath: nil, scryfallURI: ""),
            Card(id: "multi", name: "Lightning Helix", manaCost: "{R}{W}", typeLine: "Instant",
                 oracleText: nil, power: nil, toughness: nil, colors: ["R", "W"],
                 imagePath: nil, scryfallURI: ""),
            Card(id: "colorless", name: "Sol Ring", manaCost: "{1}", typeLine: "Artifact",
                 oracleText: nil, power: nil, toughness: nil, colors: [],
                 imagePath: nil, scryfallURI: ""),
        ])

        let minis = try store.loadMinis()
        let byID = Dictionary(uniqueKeysWithValues: minis.map { ($0.id, $0.identity) })
        XCTAssertEqual(byID["mono"], .red)
        XCTAssertEqual(byID["multi"], .multicolor)
        XCTAssertEqual(byID["colorless"], .colorless)
    }
}
