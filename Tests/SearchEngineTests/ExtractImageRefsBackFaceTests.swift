import XCTest
@testable import Fetcher
import Shared

/// Back-face refs are extracted only for true DFCs (per-face image_uris, e.g.
/// transform/modal_dfc) — never for split cards (top-level image only) or
/// filtered layouts like double_faced_token.
final class ExtractImageRefsBackFaceTests: XCTestCase {
    private let fixture = """
    [
      {"id":"front-only","name":"Lightning Bolt","layout":"normal",
       "image_uris":{"normal":"https://img/front-only.jpg"}},
      {"id":"dfc","name":"Sephiroth, Fabled SOLDIER // Sephiroth, One-Winged Angel","layout":"transform",
       "card_faces":[
         {"name":"Sephiroth, Fabled SOLDIER","image_uris":{"normal":"https://img/dfc-front.jpg"}},
         {"name":"Sephiroth, One-Winged Angel","image_uris":{"normal":"https://img/dfc-back.jpg"}}]},
      {"id":"split","name":"Fire // Ice","layout":"split",
       "image_uris":{"normal":"https://img/split.jpg"},
       "card_faces":[{"name":"Fire"},{"name":"Ice"}]},
      {"id":"token-dfc","name":"Some Token","layout":"double_faced_token",
       "card_faces":[
         {"name":"A","image_uris":{"normal":"https://img/t-front.jpg"}},
         {"name":"B","image_uris":{"normal":"https://img/t-back.jpg"}}]}
    ]
    """

    private func writeFixture() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cards-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try fixture.data(using: .utf8)!.write(to: url)
        return url
    }

    func testBackFaceOnlyForTrueDFCs() throws {
        let refs = try ScryfallClient().extractImageRefs(at: writeFixture())
        let byID = Dictionary(uniqueKeysWithValues: refs.map { ($0.id, $0) })
        XCTAssertEqual(byID["dfc"]?.imageURL, "https://img/dfc-front.jpg")
        XCTAssertEqual(byID["dfc"]?.backImageURL, "https://img/dfc-back.jpg")
        XCTAssertNil(byID["front-only"]?.backImageURL)
        XCTAssertNil(byID["split"]?.backImageURL)
        XCTAssertNil(byID["token-dfc"], "filtered layouts yield no ref at all")
    }

    func testBackImagePathConvention() {
        XCTAssertEqual(Paths.backImageURL(forCardID: "abc").lastPathComponent, "abc_back.jpg")
        XCTAssertEqual(Paths.backImageURL(forCardID: "abc").deletingLastPathComponent(),
                       Paths.imagesDir)
    }
}
