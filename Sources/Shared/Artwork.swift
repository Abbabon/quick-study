import Foundation

/// A single distinct Magic illustration, sourced from Scryfall's `unique_artwork`
/// bulk dataset (one row per `illustration_id`). Lives in `Shared` so the fetcher
/// (writer) and the app/game engine (readers) use the same contract — mirrors `Card`.
///
/// `art_crop` images are NOT stored in the DB: presence on disk under `Paths.artDir`
/// is the only state (same convention `Card.imagePath`/`images/` follows).
public struct Artwork: Codable, Equatable, Sendable {
    public let illustrationID: String  // Scryfall illustration_id, stable per artwork — primary key
    public let cardID: String          // a Scryfall print id bearing this art (for "open on Scryfall" etc.)
    public let cardName: String
    public let artist: String
    public let artCropURL: String      // image_uris.art_crop — streamed + cached on demand
    public let colors: [String]        // e.g. ["R"], ["W","U"] — for identity tint / optional filtering
    public let setCode: String?

    public init(
        illustrationID: String,
        cardID: String,
        cardName: String,
        artist: String,
        artCropURL: String,
        colors: [String],
        setCode: String? = nil
    ) {
        self.illustrationID = illustrationID
        self.cardID = cardID
        self.cardName = cardName
        self.artist = artist
        self.artCropURL = artCropURL
        self.colors = colors
        self.setCode = setCode
    }

    public var identity: ColorIdentity { ColorIdentity(colors: colors) }
}
