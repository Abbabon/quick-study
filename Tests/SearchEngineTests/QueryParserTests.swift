import XCTest
@testable import QuickStudy

final class QueryParserTests: XCTestCase {
    func testPlainQueryHasNoFilters() {
        let parsed = QueryParser.parse("lightning bolt")
        XCTAssertEqual(parsed.name, "lightning bolt")
        XCTAssertTrue(parsed.filters.isEmpty)
    }

    func testNamePlusRarityFilter() {
        let parsed = QueryParser.parse("bolt r:common")
        XCTAssertEqual(parsed.name, "bolt")
        XCTAssertEqual(parsed.filters, [Filter(field: .rarity, op: .eq, value: "common", negated: false)])
    }

    func testRarityComparisonOperator() {
        let parsed = QueryParser.parse("r>=rare")
        XCTAssertEqual(parsed.name, "")
        XCTAssertEqual(parsed.filters, [Filter(field: .rarity, op: .ge, value: "rare", negated: false)])
    }

    func testAllOperatorsParse() {
        XCTAssertEqual(QueryParser.parse("mv>3").filters.first?.op, .gt)
        XCTAssertEqual(QueryParser.parse("mv<3").filters.first?.op, .lt)
        XCTAssertEqual(QueryParser.parse("mv<=3").filters.first?.op, .le)
        XCTAssertEqual(QueryParser.parse("mv=3").filters.first?.op, .eq)
        XCTAssertEqual(QueryParser.parse("cmc:3").filters.first?.field, .manaValue)
    }

    func testQuotedOracleValue() {
        let parsed = QueryParser.parse("o:\"draw a card\"")
        XCTAssertEqual(parsed.name, "")
        XCTAssertEqual(parsed.filters, [Filter(field: .oracle, op: .eq, value: "draw a card", negated: false)])
    }

    func testNegation() {
        let parsed = QueryParser.parse("elf -t:land")
        XCTAssertEqual(parsed.name, "elf")
        XCTAssertEqual(parsed.filters, [Filter(field: .type, op: .eq, value: "land", negated: true)])
    }

    func testAliasesMapToSameField() {
        XCTAssertEqual(QueryParser.parse("rarity:rare").filters.first?.field, .rarity)
        XCTAssertEqual(QueryParser.parse("color:r").filters.first?.field, .color)
        XCTAssertEqual(QueryParser.parse("type:creature").filters.first?.field, .type)
        XCTAssertEqual(QueryParser.parse("oracle:flying").filters.first?.field, .oracle)
        XCTAssertEqual(QueryParser.parse("set:m21").filters.first?.field, .set)
    }

    func testUnknownKeyFallsBackToName() {
        // "foo:bar" is not a known filter key — keep it as free text so we never silently
        // swallow a colon that happens to appear in a query.
        let parsed = QueryParser.parse("foo:bar")
        XCTAssertEqual(parsed.name, "foo:bar")
        XCTAssertTrue(parsed.filters.isEmpty)
    }

    func testMultipleFiltersAndName() {
        let parsed = QueryParser.parse("c:r t:creature mv>=3 dragon")
        XCTAssertEqual(parsed.name, "dragon")
        XCTAssertEqual(parsed.filters.count, 3)
        XCTAssertTrue(parsed.filters.contains(Filter(field: .color, op: .eq, value: "r", negated: false)))
        XCTAssertTrue(parsed.filters.contains(Filter(field: .type, op: .eq, value: "creature", negated: false)))
        XCTAssertTrue(parsed.filters.contains(Filter(field: .manaValue, op: .ge, value: "3", negated: false)))
    }

    func testValuesAreLowercased() {
        XCTAssertEqual(QueryParser.parse("R:Common").filters.first?.value, "common")
    }
}
