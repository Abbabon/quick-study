import XCTest
import Shared

final class CardPrintingTests: XCTestCase {
    private func printing(digital: Bool, games: [String], released: String? = "2019-06-14") -> Card.Printing {
        Card.Printing(printingID: "p", oracleID: "o", setCode: "TST", setName: "Test",
                      collectorNumber: "1", releasedAt: released, rarity: "rare",
                      digital: digital, games: games)
    }

    func testMTGOOnlyDetection() {
        let p = printing(digital: true, games: ["mtgo"])
        XCTAssertTrue(p.isMTGOOnly)
        XCTAssertFalse(p.isArenaOnly)
    }

    func testArenaOnlyDetection() {
        let p = printing(digital: true, games: ["arena"])
        XCTAssertTrue(p.isArenaOnly)
        XCTAssertFalse(p.isMTGOOnly)
    }

    func testPaperPrintingIsNeitherDigitalOnly() {
        let p = printing(digital: false, games: ["paper", "mtgo"])
        XCTAssertFalse(p.isMTGOOnly)
        XCTAssertFalse(p.isArenaOnly)
    }

    func testYearFromReleaseDate() {
        XCTAssertEqual(printing(digital: false, games: ["paper"]).year, "2019")
        XCTAssertNil(printing(digital: false, games: ["paper"], released: nil).year)
    }
}
