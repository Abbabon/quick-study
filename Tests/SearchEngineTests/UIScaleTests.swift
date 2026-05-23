import XCTest
import SwiftUI
@testable import QuickStudy

final class UIScaleTests: XCTestCase {
    func testIdentityScaleReturnsInputValues() {
        let scale = UIScale(value: 1.0)
        XCTAssertEqual(scale.pad(10), 10, accuracy: 0.0001)
        XCTAssertEqual(scale.size(14), 14, accuracy: 0.0001)
    }

    func testGreaterThanOneScalesUp() {
        let scale = UIScale(value: 1.5)
        XCTAssertEqual(scale.pad(10), 15, accuracy: 0.0001)
        XCTAssertEqual(scale.size(14), 21, accuracy: 0.0001)
    }

    func testLessThanOneScalesDown() {
        let scale = UIScale(value: 0.8)
        XCTAssertEqual(scale.pad(10), 8, accuracy: 0.0001)
        XCTAssertEqual(scale.size(20), 16, accuracy: 0.0001)
    }

    func testFromDefaultsClampsToValidRange() {
        XCTAssertEqual(UIScale.clamp(0.5), 0.75, accuracy: 0.0001)
        XCTAssertEqual(UIScale.clamp(3.0), 2.0, accuracy: 0.0001)
        XCTAssertEqual(UIScale.clamp(1.25), 1.25, accuracy: 0.0001)
    }

    func testDefaultValueIsOne() {
        XCTAssertEqual(UIScale.defaultValue, 1.0, accuracy: 0.0001)
    }
}
