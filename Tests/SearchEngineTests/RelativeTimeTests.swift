import XCTest
@testable import QuickStudy

final class RelativeTimeTests: XCTestCase {
    private func date(daysAgo: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
    }

    func testBuckets() {
        XCTAssertEqual(RelativeTime.string(for: date(daysAgo: 0)), "today")
        XCTAssertEqual(RelativeTime.string(for: date(daysAgo: 1)), "1 day ago")
        XCTAssertEqual(RelativeTime.string(for: date(daysAgo: 3)), "3 days ago")
        XCTAssertEqual(RelativeTime.string(for: date(daysAgo: 7)), "1 week ago")
        XCTAssertEqual(RelativeTime.string(for: date(daysAgo: 21)), "3 weeks ago")
    }
}
