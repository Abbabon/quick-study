import XCTest
@testable import Shared

final class PathsTests: XCTestCase {
    func testBackImagePathConvention() {
        XCTAssertEqual(Paths.backImageURL(forCardID: "abc").lastPathComponent, "abc_back.jpg")
        XCTAssertEqual(Paths.backImageURL(forCardID: "abc").deletingLastPathComponent(), Paths.imagesDir)
    }

    func testRemoteImageURLMatchesScryfallCDNLayout() {
        XCTAssertEqual(Paths.remoteImageURL(forCardID: "cd456")?.absoluteString,
                       "https://cards.scryfall.io/normal/front/c/d/cd456.jpg")
        XCTAssertNil(Paths.remoteImageURL(forCardID: "x"))
    }
}
