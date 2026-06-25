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
        XCTAssertEqual(ManaCost.pips(from: "{T}"), [ManaPip(glyph: "↺", identity: .colorless)])
    }

    func testGuildHybridSplitsIntoTwoColoredHalves() {
        XCTAssertEqual(ManaCost.pips(from: "{B/R}"), [
            ManaPip(glyph: "B/R", identity: .multicolor, halves: [
                ManaPip.Half(glyph: "B", identity: .black),
                ManaPip.Half(glyph: "R", identity: .red),
            ]),
        ])
    }

    func testTwobridSplitsGenericAndColor() {
        XCTAssertEqual(ManaCost.pips(from: "{2/W}"), [
            ManaPip(glyph: "2/W", identity: .multicolor, halves: [
                ManaPip.Half(glyph: "2", identity: .colorless),
                ManaPip.Half(glyph: "W", identity: .white),
            ]),
        ])
    }

    func testPhyrexianHybridUsesPhiGlyph() {
        XCTAssertEqual(ManaCost.pips(from: "{W/P}"), [
            ManaPip(glyph: "W/P", identity: .multicolor, halves: [
                ManaPip.Half(glyph: "W", identity: .white),
                ManaPip.Half(glyph: "Φ", identity: .colorless),
            ]),
        ])
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
