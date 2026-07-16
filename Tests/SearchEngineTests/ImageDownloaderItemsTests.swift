import XCTest
@testable import Fetcher
import Shared

/// A ref with a back face yields two download items; the back item never records
/// image_path in the DB (recordID nil) and lands at images/{id}_back.jpg.
final class ImageDownloaderItemsTests: XCTestCase {
    func testBackFaceRefsProduceTwoItems() {
        let refs = [
            CardImageRef(id: "a", imageURL: "https://img/a.jpg", backImageURL: nil),
            CardImageRef(id: "b", imageURL: "https://img/b.jpg", backImageURL: "https://img/b-back.jpg"),
        ]
        let items = ImageDownloader.downloadItems(for: refs)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].dest.lastPathComponent, "a.jpg")
        XCTAssertEqual(items[0].recordID, "a")
        XCTAssertEqual(items[1].dest.lastPathComponent, "b.jpg")
        XCTAssertEqual(items[1].recordID, "b")
        XCTAssertEqual(items[2].url, "https://img/b-back.jpg")
        XCTAssertEqual(items[2].dest.lastPathComponent, "b_back.jpg")
        XCTAssertNil(items[2].recordID)
    }
}
