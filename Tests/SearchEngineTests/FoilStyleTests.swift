import XCTest
@testable import QuickStudy

final class FoilStyleTests: XCTestCase {
    func testStoredValuesResolve() {
        XCTAssertEqual(FoilStyle(stored: "gilded"), .surge)   // removed style migrates
        XCTAssertEqual(FoilStyle(stored: "holo"), .holo)
        XCTAssertEqual(FoilStyle(stored: "bogus"), FoilStyle.none)
    }
}
