import XCTest
@testable import QuickStudy

final class UpdateCheckerTests: XCTestCase {
    // Scryfall stamps: ISO-8601 with offset, usually with fractional seconds.
    private let older = "2024-06-01T09:00:00.000+00:00"
    private let newer = "2024-06-10T09:00:31.443+00:00"

    func testRemoteNewerThanIngestedPrompts() {
        XCTAssertTrue(UpdateChecker.shouldPrompt(remote: newer, ingested: older, dismissed: nil))
    }

    func testRemoteEqualToIngestedDoesNotPrompt() {
        XCTAssertFalse(UpdateChecker.shouldPrompt(remote: newer, ingested: newer, dismissed: nil))
    }

    func testRemoteOlderThanIngestedDoesNotPrompt() {
        XCTAssertFalse(UpdateChecker.shouldPrompt(remote: older, ingested: newer, dismissed: nil))
    }

    func testDismissedSameStampSuppresses() {
        XCTAssertFalse(UpdateChecker.shouldPrompt(remote: newer, ingested: older, dismissed: newer))
    }

    func testDismissedOlderThanRemoteStillPrompts() {
        // User dismissed an earlier update; a strictly newer one should re-prompt.
        let newest = "2024-06-20T12:00:00.000+00:00"
        XCTAssertTrue(UpdateChecker.shouldPrompt(remote: newest, ingested: older, dismissed: newer))
    }

    func testNoBaselineDoesNotPrompt() {
        // First-run (empty DB) is handled by the download prompt, not the update prompt.
        XCTAssertFalse(UpdateChecker.shouldPrompt(remote: newer, ingested: nil, dismissed: nil))
    }

    func testMalformedRemoteDoesNotPrompt() {
        XCTAssertFalse(UpdateChecker.shouldPrompt(remote: "not-a-date", ingested: older, dismissed: nil))
    }

    func testParseHandlesStampWithoutFractionalSeconds() {
        XCTAssertNotNil(UpdateChecker.parse("2024-06-10T09:00:31+00:00"))
        XCTAssertNotNil(UpdateChecker.parse(newer))
    }
}
