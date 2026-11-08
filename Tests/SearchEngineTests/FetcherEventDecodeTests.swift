import XCTest
@testable import QuickStudy

/// Lines captured verbatim from the Rust `mtg-fetcher` (engine/) — the app must decode them.
final class FetcherEventDecodeTests: XCTestCase {
    private let captured = """
    {"phase":"start","message":"mtg-fetcher starting (imagesOnly=false skipImages=true artwork=false downloadArt=false printings=true)"}
    {"phase":"json","message":"bulk size 25410597 updated_at 2026-11-08T10:03:16.679+00:00"}
    {"phase":"ingest","done":0,"total":35769}
    {"phase":"ingest","done":35769,"total":35769,"message":"removed 2 stale cards"}
    {"phase":"printings","done":111142,"total":111142}
    {"phase":"done","message":"skipping images","newCards":35769}
    {"phase":"error","message":"GET /sets -> HTTP 503 Service Unavailable"}
    """

    func testDecodesCapturedRustOutput() throws {
        let events = captured.split(separator: "\n").map { FetcherProcess.decodeEvent(Data($0.utf8)) }
        XCTAssertFalse(events.contains { $0 == nil })
        let e = events.compactMap { $0 }
        XCTAssertEqual(e[0].phase, "start")
        XCTAssertEqual(e[2].done, 0); XCTAssertEqual(e[2].total, 35769)
        XCTAssertEqual(e[3].message, "removed 2 stale cards")
        XCTAssertEqual(e[5].phase, "done"); XCTAssertEqual(e[5].newCards, 35769)
        XCTAssertEqual(e[6].phase, "error")
    }
}
