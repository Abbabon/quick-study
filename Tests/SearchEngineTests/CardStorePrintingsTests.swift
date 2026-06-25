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

    func testPrintingsRoundTripAndSetIndex() throws {
        let store = try makeStore()
        // Two cards sharing nothing but both present so the set-index join resolves.
        try store.upsert([
            Card(id: "c1", name: "Lightning Bolt", manaCost: nil, typeLine: nil, oracleText: nil,
                 power: nil, toughness: nil, colors: ["R"], imagePath: nil, scryfallURI: "",
                 setCode: "LEA", setName: "Alpha", oracleID: "oracle-bolt", dateAdded: nil),
            Card(id: "c2", name: "Counterspell", manaCost: nil, typeLine: nil, oracleText: nil,
                 power: nil, toughness: nil, colors: ["U"], imagePath: nil, scryfallURI: "",
                 setCode: "LEA", setName: "Alpha", oracleID: "oracle-cs", dateAdded: nil),
        ])
        try store.upsertSets([
            SetInfo(code: "LEA", name: "Limited Edition Alpha", releasedAt: "1993-08-05",
                    setType: "core", cardCount: 295, iconSVGURI: "https://x/lea.svg"),
            SetInfo(code: "M21", name: "Core Set 2021", releasedAt: "2020-07-03",
                    setType: "core", cardCount: 397, iconSVGURI: nil),
        ])
        try store.upsertPrintings([
            Card.Printing(printingID: "p1", oracleID: "oracle-bolt", setCode: "LEA", setName: "Limited Edition Alpha",
                          collectorNumber: "161", releasedAt: "1993-08-05", rarity: "common",
                          digital: false, games: ["paper"]),
            Card.Printing(printingID: "p2", oracleID: "oracle-bolt", setCode: "M21", setName: "Core Set 2021",
                          collectorNumber: "148", releasedAt: "2020-07-03", rarity: "uncommon",
                          digital: false, games: ["paper", "mtgo"]),
            Card.Printing(printingID: "p3", oracleID: "oracle-cs", setCode: "LEA", setName: "Limited Edition Alpha",
                          collectorNumber: "54", releasedAt: "1993-08-05", rarity: "uncommon",
                          digital: false, games: ["paper"]),
        ])

        XCTAssertEqual(try store.setsCount(), 2)
        XCTAssertEqual(try store.printingsCount(), 3)

        // Bolt has two printings, newest first.
        let boltPrints = try store.printings(forOracleID: "oracle-bolt")
        XCTAssertEqual(boltPrints.map(\.setCode), ["M21", "LEA"])

        // The set index groups LEA's two member cards.
        let index = try store.loadSetIndex()
        let lea = index.first { $0.code == "LEA" }
        XCTAssertNotNil(lea)
        XCTAssertEqual(Set(lea!.memberIDs), Set(["c1", "c2"]))
        let m21 = index.first { $0.code == "M21" }
        XCTAssertEqual(m21?.memberIDs, ["c1"])
    }
}
