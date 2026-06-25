import XCTest
@testable import QuickStudy
import Shared

/// Golden cases for inline-filter application. The corpus carries `Card.FilterFields` so the
/// engine can filter ranked name matches (and filters-only queries) by rarity/color/type/
/// mana value/oracle text.
final class SearchEngineFilterTests: XCTestCase {
    // Five cards with deliberately varied metadata.
    private let minis: [Card.Mini] = [
        Card.Mini(id: "bolt", name: "Lightning Bolt", colors: ["R"], setCode: "LEA", setName: "Limited Edition Alpha", rarity: "common"),
        Card.Mini(id: "shock", name: "Shock", colors: ["R"], setCode: "M21", setName: "Core 2021", rarity: "common"),
        Card.Mini(id: "jace", name: "Jace, the Mind Sculptor", colors: ["U"], setCode: "WWK", setName: "Worldwake", rarity: "mythic"),
        Card.Mini(id: "bear", name: "Grizzly Bears", colors: ["G"], setCode: "M21", setName: "Core 2021", rarity: "common"),
        Card.Mini(id: "drake", name: "Storm Crow", colors: ["U"], setCode: "9ED", setName: "Ninth Edition", rarity: "uncommon"),
    ]

    private let fields: [String: Card.FilterFields] = [
        "bolt": Card.FilterFields(colors: ["R"], typeLineLower: "instant", oracleTextLower: "lightning bolt deals 3 damage to any target", cmc: 1, rarities: ["common"]),
        "shock": Card.FilterFields(colors: ["R"], typeLineLower: "instant", oracleTextLower: "shock deals 2 damage to any target", cmc: 1, rarities: ["common", "uncommon"]),
        "jace": Card.FilterFields(colors: ["U"], typeLineLower: "legendary planeswalker — jace", oracleTextLower: "brainstorm: draw three cards", cmc: 4, rarities: ["mythic"]),
        "bear": Card.FilterFields(colors: ["G"], typeLineLower: "creature — bear", oracleTextLower: "", cmc: 2, rarities: ["common"]),
        "drake": Card.FilterFields(colors: ["U"], typeLineLower: "creature — bird", oracleTextLower: "flying", cmc: 2, rarities: ["uncommon"]),
    ]

    private let setGroups: [Card.SetGroup] = [
        Card.SetGroup(code: "M21", name: "Core 2021", memberIDs: ["shock", "bear"]),
    ]

    private func engine() -> SearchEngine {
        SearchEngine(minis: minis, sets: setGroups, filterFields: fields)
    }

    func testRarityFilterNarrowsNameMatches() {
        // "s" matches Shock and Storm Crow by name; r:uncommon keeps only those ever uncommon.
        let names = engine().search(name: "s", filters: [Filter(field: .rarity, op: .eq, value: "uncommon", negated: false)]).map(\.name)
        XCTAssertTrue(names.contains("Storm Crow"))
        XCTAssertTrue(names.contains("Shock"))         // shock was printed uncommon too
        XCTAssertFalse(names.contains("Grizzly Bears"))
    }

    func testPauperFilterEverPrintedCommon() {
        // Filters-only: every card ever printed common.
        let names = Set(engine().search(name: "", filters: [Filter(field: .rarity, op: .eq, value: "common", negated: false)]).map(\.name))
        XCTAssertEqual(names, ["Lightning Bolt", "Shock", "Grizzly Bears"])
    }

    func testRarityComparisonGreaterEqual() {
        let names = Set(engine().search(name: "", filters: [Filter(field: .rarity, op: .ge, value: "rare", negated: false)]).map(\.name))
        XCTAssertEqual(names, ["Jace, the Mind Sculptor"])
    }

    func testColorFilter() {
        let names = Set(engine().search(name: "", filters: [Filter(field: .color, op: .eq, value: "r", negated: false)]).map(\.name))
        XCTAssertEqual(names, ["Lightning Bolt", "Shock"])
    }

    func testTypeFilterIsSubstring() {
        let names = Set(engine().search(name: "", filters: [Filter(field: .type, op: .eq, value: "creature", negated: false)]).map(\.name))
        XCTAssertEqual(names, ["Grizzly Bears", "Storm Crow"])
    }

    func testManaValueComparison() {
        let geThree = Set(engine().search(name: "", filters: [Filter(field: .manaValue, op: .ge, value: "3", negated: false)]).map(\.name))
        XCTAssertEqual(geThree, ["Jace, the Mind Sculptor"])
        let eqOne = Set(engine().search(name: "", filters: [Filter(field: .manaValue, op: .eq, value: "1", negated: false)]).map(\.name))
        XCTAssertEqual(eqOne, ["Lightning Bolt", "Shock"])
    }

    func testOracleTextFilter() {
        let names = Set(engine().search(name: "", filters: [Filter(field: .oracle, op: .eq, value: "draw", negated: false)]).map(\.name))
        XCTAssertEqual(names, ["Jace, the Mind Sculptor"])
    }

    func testNegationExcludes() {
        let names = Set(engine().search(name: "", filters: [Filter(field: .type, op: .eq, value: "creature", negated: true)]).map(\.name))
        XCTAssertFalse(names.contains("Grizzly Bears"))
        XCTAssertTrue(names.contains("Lightning Bolt"))
    }

    func testSetFilterUsesMembership() {
        let names = Set(engine().search(name: "", filters: [Filter(field: .set, op: .eq, value: "m21", negated: false)]).map(\.name))
        XCTAssertEqual(names, ["Shock", "Grizzly Bears"])
    }

    func testNameAndFilterIntersect() {
        // Name "bolt" + r:common still returns Lightning Bolt; + r:mythic returns nothing.
        XCTAssertEqual(engine().search(name: "bolt", filters: [Filter(field: .rarity, op: .eq, value: "common", negated: false)]).map(\.name), ["Lightning Bolt"])
        XCTAssertTrue(engine().search(name: "bolt", filters: [Filter(field: .rarity, op: .eq, value: "mythic", negated: false)]).isEmpty)
    }

    func testNoFiltersMatchesLegacyBehavior() {
        XCTAssertEqual(engine().search("bolt").first?.name, "Lightning Bolt")
        XCTAssertEqual(engine().search(name: "", filters: []).count, 0)
    }
}
