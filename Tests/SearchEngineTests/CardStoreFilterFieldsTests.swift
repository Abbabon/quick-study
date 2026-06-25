import XCTest
import Shared

final class CardStoreFilterFieldsTests: XCTestCase {
    private func makeStore() throws -> CardStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qs-filterfields-\(UUID().uuidString).sqlite")
        return try CardStore(url: url)
    }

    func testRarityAndCmcRoundTrip() throws {
        let store = try makeStore()
        let card = Card(id: "c1", name: "Lightning Bolt", manaCost: "{R}", typeLine: "Instant",
                        oracleText: "Deal 3 damage.", power: nil, toughness: nil, colors: ["R"],
                        imagePath: nil, scryfallURI: "", setCode: "LEA", setName: "Alpha",
                        oracleID: "oracle-bolt", dateAdded: nil, rarity: "uncommon", cmc: 1)
        try store.upsert([card])
        let loaded = try store.card(id: "c1")
        XCTAssertEqual(loaded?.rarity, "uncommon")
        XCTAssertEqual(loaded?.cmc, 1)
        // Representative rarity also rides the mini projection (for the result-row badge).
        XCTAssertEqual(try store.loadMinis().first(where: { $0.id == "c1" })?.rarity, "uncommon")
    }

    func testLoadFilterFieldsUnionsPrintingRarities() throws {
        let store = try makeStore()
        // Card's representative rarity is "uncommon"; printings add "common" — so the card's
        // rarity set must include BOTH (this is what makes `r:common` mean "ever common").
        try store.upsert([
            Card(id: "c1", name: "Lightning Bolt", manaCost: "{R}", typeLine: "Instant",
                 oracleText: "Deal 3 damage to any target.", power: nil, toughness: nil, colors: ["R"],
                 imagePath: nil, scryfallURI: "", setCode: "M21", setName: "Core 2021",
                 oracleID: "oracle-bolt", dateAdded: nil, rarity: "uncommon", cmc: 1),
        ])
        try store.upsertPrintings([
            Card.Printing(printingID: "p1", oracleID: "oracle-bolt", setCode: "LEA", setName: "Alpha",
                          collectorNumber: "161", releasedAt: "1993-08-05", rarity: "common",
                          digital: false, games: ["paper"]),
            Card.Printing(printingID: "p2", oracleID: "oracle-bolt", setCode: "M21", setName: "Core 2021",
                          collectorNumber: "148", releasedAt: "2020-07-03", rarity: "uncommon",
                          digital: false, games: ["paper"]),
        ])

        let fields = try store.loadFilterFields()
        let f = try XCTUnwrap(fields["c1"])
        XCTAssertEqual(f.rarities, ["common", "uncommon"])
        XCTAssertEqual(f.colors, ["R"])
        XCTAssertEqual(f.typeLineLower, "instant")
        XCTAssertEqual(f.oracleTextLower, "deal 3 damage to any target.")
        XCTAssertEqual(f.cmc, 1)
    }

    func testFilterFieldsFallBackToRepresentativeRarityWithoutPrintings() throws {
        // Before a --printings run, the printings table is empty; the rarity set should still
        // carry the representative rarity so basic `r:` filtering works.
        let store = try makeStore()
        try store.upsert([
            Card(id: "c1", name: "Shock", manaCost: "{R}", typeLine: "Instant", oracleText: nil,
                 power: nil, toughness: nil, colors: ["R"], imagePath: nil, scryfallURI: "",
                 setCode: "M21", setName: "Core 2021", oracleID: "oracle-shock", dateAdded: nil,
                 rarity: "common", cmc: 1),
        ])
        let f = try XCTUnwrap(try store.loadFilterFields()["c1"])
        XCTAssertEqual(f.rarities, ["common"])
    }
}
