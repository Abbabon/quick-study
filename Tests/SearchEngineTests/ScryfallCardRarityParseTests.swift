import XCTest
@testable import Fetcher
import Shared

/// Confirms the oracle-card ingest decodes the v9 fields (`rarity`, `cmc`) from a
/// Scryfall `oracle_cards`-shaped object.
final class ScryfallCardRarityParseTests: XCTestCase {
    private let fixture = """
    [
      {"id":"c1","name":"Lightning Bolt","mana_cost":"{R}","cmc":1.0,"rarity":"common",
       "type_line":"Instant","oracle_text":"Deal 3 damage.","colors":["R"],
       "scryfall_uri":"https://scryfall.com/c1","layout":"normal","set":"lea","set_name":"Limited Edition Alpha","oracle_id":"o1"},
      {"id":"c2","name":"Jace, the Mind Sculptor","cmc":4.0,"rarity":"mythic",
       "type_line":"Legendary Planeswalker — Jace","oracle_text":"...","colors":["U"],
       "scryfall_uri":"https://scryfall.com/c2","layout":"normal","set":"wwk","set_name":"Worldwake","oracle_id":"o2"}
    ]
    """

    private func writeFixture() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cards-\(UUID().uuidString).json")
        try fixture.data(using: .utf8)!.write(to: url)
        return url
    }

    func testParseDecodesRarityAndCmc() throws {
        let cards = try ScryfallClient().parseBulk(at: writeFixture())
        let byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        XCTAssertEqual(byID["c1"]?.rarity, "common")
        XCTAssertEqual(byID["c1"]?.cmc, 1.0)
        XCTAssertEqual(byID["c2"]?.rarity, "mythic")
        XCTAssertEqual(byID["c2"]?.cmc, 4.0)
    }
}
