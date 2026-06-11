import XCTest
@testable import QuickStudy

final class AppUpdateCheckerTests: XCTestCase {
    // MARK: - isNewer

    func testNewerPatch() {
        XCTAssertTrue(AppUpdateChecker.isNewer("0.2.1", than: "0.2.0"))
    }

    func testNewerMinor() {
        XCTAssertTrue(AppUpdateChecker.isNewer("0.3.0", than: "0.2.9"))
    }

    func testNewerMajor() {
        XCTAssertTrue(AppUpdateChecker.isNewer("1.0.0", than: "0.99.99"))
    }

    func testEqualIsNotNewer() {
        XCTAssertFalse(AppUpdateChecker.isNewer("0.2.0", than: "0.2.0"))
    }

    func testOlderIsNotNewer() {
        XCTAssertFalse(AppUpdateChecker.isNewer("0.1.9", than: "0.2.0"))
    }

    func testLeadingVIgnored() {
        XCTAssertTrue(AppUpdateChecker.isNewer("v0.3.0", than: "v0.2.0"))
        XCTAssertTrue(AppUpdateChecker.isNewer("0.3.0", than: "v0.2.0"))
    }

    func testDifferingComponentCounts() {
        XCTAssertTrue(AppUpdateChecker.isNewer("0.3", than: "0.2.9"))
        XCTAssertFalse(AppUpdateChecker.isNewer("0.2", than: "0.2.0"))
    }

    func testMalformedIsNotNewer() {
        XCTAssertFalse(AppUpdateChecker.isNewer("not-a-version", than: "0.2.0"))
        XCTAssertFalse(AppUpdateChecker.isNewer("0.3.0", than: "garbage"))
    }

    // MARK: - shouldPrompt

    func testRemoteNewerThanCurrentPrompts() {
        XCTAssertTrue(AppUpdateChecker.shouldPrompt(remote: "0.3.0", current: "0.2.0", dismissed: nil))
    }

    func testRemoteEqualToCurrentDoesNotPrompt() {
        XCTAssertFalse(AppUpdateChecker.shouldPrompt(remote: "0.2.0", current: "0.2.0", dismissed: nil))
    }

    func testRemoteOlderThanCurrentDoesNotPrompt() {
        XCTAssertFalse(AppUpdateChecker.shouldPrompt(remote: "0.1.0", current: "0.2.0", dismissed: nil))
    }

    func testDismissedSameVersionSuppresses() {
        XCTAssertFalse(AppUpdateChecker.shouldPrompt(remote: "0.3.0", current: "0.2.0", dismissed: "0.3.0"))
    }

    func testDismissedOlderThanRemoteStillPrompts() {
        // User dismissed an earlier release; a strictly newer one should re-prompt.
        XCTAssertTrue(AppUpdateChecker.shouldPrompt(remote: "0.4.0", current: "0.2.0", dismissed: "0.3.0"))
    }

    func testMalformedRemoteDoesNotPrompt() {
        XCTAssertFalse(AppUpdateChecker.shouldPrompt(remote: "bogus", current: "0.2.0", dismissed: nil))
    }
}
