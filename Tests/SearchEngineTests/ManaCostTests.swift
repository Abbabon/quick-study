import XCTest
@testable import QuickStudy
import Shared

final class ManaCostTests: XCTestCase {
    func testParsesColorAndGenericPips() {
        let pips = ManaCost.pips(from: "{2}{W}{U}")
        XCTAssertEqual(pips, [
            ManaPip(glyph: "2", identity: .colorless),
            ManaPip(glyph: "W", identity: .white),
            ManaPip(glyph: "U", identity: .blue),
        ])
    }

    func testTapSymbol() {
        XCTAssertEqual(ManaCost.pips(from: "{T}"), [ManaPip(glyph: "↻", identity: .colorless)])
    }

    func testHybridFallsBackToColorlessDiscWithText() {
        XCTAssertEqual(ManaCost.pips(from: "{B/R}"), [ManaPip(glyph: "B/R", identity: .colorless)])
    }

    func testEmptyAndNoTokens() {
        XCTAssertEqual(ManaCost.pips(from: ""), [])
        XCTAssertEqual(ManaCost.pips(from: "no braces"), [])
    }

    func testXAndColorlessAreColorlessDiscs() {
        XCTAssertEqual(ManaCost.pips(from: "{X}{C}"), [
            ManaPip(glyph: "X", identity: .colorless),
            ManaPip(glyph: "C", identity: .colorless),
        ])
    }
}
