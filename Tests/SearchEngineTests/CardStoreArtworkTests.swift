import XCTest
import Shared

final class CardStoreArtworkTests: XCTestCase {
    private func makeStore() throws -> CardStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qs-test-\(UUID().uuidString).sqlite")
        return try CardStore(url: url)
    }

    private func art(_ id: String, name: String, artist: String, colors: [String] = []) -> Artwork {
        Artwork(illustrationID: id, cardID: "card-\(id)", cardName: name,
                artist: artist, artCropURL: "https://example/\(id).jpg",
                colors: colors, setCode: "SET")
    }

    func testUpsertAndCount() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.artworkCount(), 0)
        try store.upsertArtworks([
            art("a", name: "Shock", artist: "Artist One", colors: ["R"]),
            art("b", name: "Counterspell", artist: "Artist Two", colors: ["U"]),
        ])
        XCTAssertEqual(try store.artworkCount(), 2)
    }

    func testUpsertConflictUpdatesByIllustrationID() throws {
        let store = try makeStore()
        try store.upsertArtworks([art("a", name: "Old Name", artist: "Old Artist")])
        try store.upsertArtworks([art("a", name: "New Name", artist: "New Artist")])
        XCTAssertEqual(try store.artworkCount(), 1)
        let loaded = try store.loadArtworks()
        XCTAssertEqual(loaded.first?.cardName, "New Name")
        XCTAssertEqual(loaded.first?.artist, "New Artist")
    }

    func testLoadArtworksRoundTripsColors() throws {
        let store = try makeStore()
        try store.upsertArtworks([art("a", name: "Helix", artist: "X", colors: ["R", "W"])])
        let loaded = try store.loadArtworks()
        XCTAssertEqual(loaded.first?.colors, ["R", "W"])
        XCTAssertEqual(loaded.first?.identity, .multicolor)
    }

    func testDistinctArtists() throws {
        let store = try makeStore()
        try store.upsertArtworks([
            art("a", name: "A", artist: "Rebecca Guay"),
            art("b", name: "B", artist: "Rebecca Guay"),
            art("c", name: "C", artist: "John Avon"),
        ])
        XCTAssertEqual(try store.distinctArtists(), ["John Avon", "Rebecca Guay"])
    }
}
