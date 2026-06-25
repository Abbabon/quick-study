import XCTest
@testable import Fetcher
import Shared

final class ScryfallPrintingParseTests: XCTestCase {
    /// Minimal default_cards-shaped fixture: one English paper printing, one MTGO-only
    /// digital printing, one Japanese row (skipped), one token layout (skipped), one row
    /// missing oracle_id (skipped).
    private let fixture = """
    [
      {"id":"p1","oracle_id":"o1","set":"m21","set_name":"Core Set 2021","collector_number":"148",
       "released_at":"2020-07-03","rarity":"uncommon","digital":false,"games":["paper","mtgo"],"lang":"en","layout":"normal"},
      {"id":"p2","oracle_id":"o1","set":"pmtg1","set_name":"Magic Online Promos","collector_number":"1",
       "released_at":"2019-01-01","rarity":"rare","digital":true,"games":["mtgo"],"lang":"en","layout":"normal"},
      {"id":"p3","oracle_id":"o1","set":"m21","set_name":"Core Set 2021","collector_number":"148",
       "released_at":"2020-07-03","rarity":"uncommon","digital":false,"games":["paper"],"lang":"ja","layout":"normal"},
      {"id":"p4","oracle_id":"o2","set":"tm21","set_name":"Core 2021 Tokens","collector_number":"1",
       "released_at":"2020-07-03","rarity":"common","digital":false,"games":["paper"],"lang":"en","layout":"token"},
      {"id":"p5","set":"m21","set_name":"Core Set 2021","collector_number":"X",
       "released_at":"2020-07-03","rarity":"common","digital":false,"games":["paper"],"lang":"en","layout":"normal"}
    ]
    """

    private func writeFixture() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prints-\(UUID().uuidString).json")
        try fixture.data(using: .utf8)!.write(to: url)
        return url
    }

    func testParsePrintingsFiltersAndMaps() throws {
        let client = ScryfallClient()
        let prints = try client.parsePrintings(at: writeFixture())
        // p1 (en paper) and p2 (en mtgo) kept; p3 (ja), p4 (token), p5 (no oracle_id) dropped.
        XCTAssertEqual(prints.map(\.printingID), ["p1", "p2"])
        XCTAssertEqual(prints[0].setCode, "M21")              // uppercased
        XCTAssertEqual(prints[0].games, ["paper", "mtgo"])
        XCTAssertFalse(prints[0].isMTGOOnly)
        XCTAssertTrue(prints[1].isMTGOOnly)                   // p2 digital + ["mtgo"]
    }
}
