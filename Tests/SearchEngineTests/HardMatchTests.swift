import XCTest
import Shared

final class HardMatchTests: XCTestCase {
    func testAcceptsCaseOnlyDifference() {
        XCTAssertTrue(hardMatch("jace beleren", "Jace Beleren"))
        XCTAssertTrue(hardMatch("LIGHTNING BOLT", "Lightning Bolt"))
    }

    func testAcceptsHyphenAndSpaceEquivalence() {
        XCTAssertTrue(hardMatch("Niv Mizzet", "Niv-Mizzet"))
        XCTAssertTrue(hardMatch("niv-mizzet", "Niv Mizzet"))
        XCTAssertTrue(hardMatch("Borrowing  100,000 Arrows", "Borrowing 100,000 Arrows"))
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertTrue(hardMatch("  Shock  ", "Shock"))
    }

    func testRejectsSpellingDifference() {
        XCTAssertFalse(hardMatch("Jace Belerne", "Jace Beleren"))
        XCTAssertFalse(hardMatch("Lightning Bot", "Lightning Bolt"))
    }

    func testRejectsPunctuationDifferenceOtherThanHyphen() {
        // Apostrophes must still match exactly.
        XCTAssertFalse(hardMatch("Gaeas Cradle", "Gaea's Cradle"))
    }

    func testNormalizeCollapsesRuns() {
        XCTAssertEqual(normalizeCardName("Niv--Mizzet,   Parun"), "niv mizzet, parun")
    }
}
