import XCTest
@testable import Shared

final class PathsTests: XCTestCase {
    func testBackImagePathConvention() {
        XCTAssertEqual(Paths.backImageURL(forCardID: "abc").lastPathComponent, "abc_back.jpg")
        XCTAssertEqual(Paths.backImageURL(forCardID: "abc").deletingLastPathComponent(), Paths.imagesDir)
    }
}
