import XCTest
import Shared

final class ColorIdentityTests: XCTestCase {
    func testSingleColor() {
        XCTAssertEqual(ColorIdentity(colors: ["R"]), .red)
        XCTAssertEqual(ColorIdentity(colors: ["W"]), .white)
        XCTAssertEqual(ColorIdentity(colors: ["U"]), .blue)
        XCTAssertEqual(ColorIdentity(colors: ["B"]), .black)
        XCTAssertEqual(ColorIdentity(colors: ["G"]), .green)
    }

    func testTwoOrMoreColorsIsMulticolor() {
        XCTAssertEqual(ColorIdentity(colors: ["W", "U"]), .multicolor)
        XCTAssertEqual(ColorIdentity(colors: ["W", "U", "B", "R", "G"]), .multicolor)
    }

    func testEmptyIsColorless() {
        XCTAssertEqual(ColorIdentity(colors: []), .colorless)
    }

    func testCardIdentityComputed() {
        let card = Card(id: "x", name: "Niv-Mizzet", manaCost: "{U}{R}", typeLine: nil,
                        oracleText: nil, power: nil, toughness: nil, colors: ["U", "R"],
                        imagePath: nil, scryfallURI: "")
        XCTAssertEqual(card.identity, .multicolor)
    }

    func testMiniDefaultInitIsColorless() {
        let mini = Card.Mini(id: "1", name: "Shock")
        XCTAssertEqual(mini.identity, .colorless)
    }

    func testMiniColorsInitDerivesIdentity() {
        let mini = Card.Mini(id: "2", name: "Lightning Helix", colors: ["R", "W"])
        XCTAssertEqual(mini.identity, .multicolor)
    }
}
