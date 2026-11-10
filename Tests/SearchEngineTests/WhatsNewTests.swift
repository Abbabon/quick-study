import XCTest
@testable import QuickStudy

final class WhatsNewTests: XCTestCase {
    func testParse() {
        let n = WhatsNew.parse("version: 1.2.3\n\n- one\n- two\n")
        XCTAssertEqual(n, WhatsNew(version: "1.2.3", items: ["one", "two"]))
        XCTAssertNil(WhatsNew.parse("- no version"))
        XCTAssertNil(WhatsNew.parse("version: 1.0"))
    }

    func testBundledFileParses() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/WhatsNew.md")
        XCTAssertNotNil(WhatsNew.parse(try String(contentsOf: url, encoding: .utf8)))
    }

    func testShowOnceUntilDismissed() {
        let n = WhatsNew(version: "1.0", items: ["x"])
        XCTAssertTrue(WhatsNew.isPending(notes: n, running: "1.0", dismissed: nil))
        XCTAssertTrue(WhatsNew.isPending(notes: n, running: "1.0", dismissed: "0.9"))
        XCTAssertFalse(WhatsNew.isPending(notes: n, running: "1.0", dismissed: "1.0"))
        XCTAssertFalse(WhatsNew.isPending(notes: n, running: "1.1", dismissed: nil), "stale notes")
        XCTAssertFalse(WhatsNew.isPending(notes: nil, running: "1.0", dismissed: nil))
    }
}
