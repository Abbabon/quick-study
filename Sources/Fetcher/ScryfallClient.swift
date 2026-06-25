import Foundation
import Shared

/// Thin client for Scryfall's bulk-data API and individual card JSON.
/// Docs: https://scryfall.com/docs/api/bulk-data
public final class ScryfallClient {
    public static let bulkIndexURL = URL(string: "https://api.scryfall.com/bulk-data")!
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// The bulk-data index contract lives in `Shared` so the app's update checker
    /// can read the same `updated_at` timestamp without importing the fetcher.
    public typealias BulkInfo = ScryfallBulk.Info

    /// Fetches the bulk-data index and returns the info entry of the given type.
    /// `type` defaults to "oracle_cards" — one row per unique card name.
    public func bulkInfo(type: String = "oracle_cards") async throws -> BulkInfo {
        try await ScryfallBulk.info(type: type, session: session)
    }

    /// Downloads the bulk JSON blob to a local file and returns its path.
    public func downloadBulkJSON(from info: BulkInfo, to destination: URL) async throws {
        guard let url = URL(string: info.download_uri) else {
            throw NSError(domain: "ScryfallClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "bad download_uri"])
        }
        let (tmp, _) = try await session.download(from: url)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tmp, to: destination)
    }

    /// Streaming decode of the Scryfall bulk JSON into `Card` records.
    /// The bulk file is a single JSON array; we decode it whole then yield records.
    /// At ~50–100 MB this is acceptable; if it grows we can switch to a streaming parser.
    public func parseBulk(at url: URL) throws -> [Card] {
        let data = try Data(contentsOf: url)
        let raws = try JSONDecoder().decode([ScryfallCard].self, from: data)
        return raws.compactMap { $0.toCard() }
    }

    /// Decode the `unique_artwork` bulk JSON into `Artwork` records. Each card object can
    /// yield multiple arts (double-faced cards carry one illustration per face), so we
    /// flatten them; the DB upsert dedups by `illustration_id`.
    public func parseArtworks(at url: URL) throws -> [Artwork] {
        let data = try Data(contentsOf: url)
        let raws = try JSONDecoder().decode([ScryfallArtwork].self, from: data)
        return raws.flatMap { $0.toArtworks() }
    }
}

// MARK: - Scryfall raw JSON shape (unique_artwork)

/// Minimal projection of a Scryfall card object as it appears in the `unique_artwork`
/// bulk file — only the fields the art games need.
private struct ScryfallArtwork: Decodable {
    let id: String
    let name: String
    let artist: String?
    let illustration_id: String?
    let image_uris: ArtImageURIs?
    let card_faces: [Face]?
    let colors: [String]?
    let color_identity: [String]?
    let layout: String?
    let set: String?

    struct ArtImageURIs: Decodable {
        let art_crop: String?
    }

    struct Face: Decodable {
        let name: String?
        let artist: String?
        let illustration_id: String?
        let image_uris: ArtImageURIs?
        let colors: [String]?
    }

    func toArtworks() -> [Artwork] {
        // Skip the same junk layouts as the card ingest.
        if let l = layout, ["token", "double_faced_token", "art_series", "emblem"].contains(l) {
            return []
        }
        let fallbackColors = colors ?? color_identity ?? []
        var result: [Artwork] = []

        func make(illustrationID: String?, artCrop: String?, artist: String?, name: String?, colors: [String]?) {
            guard let illustrationID, let artCrop, let artist else { return }
            result.append(Artwork(
                illustrationID: illustrationID,
                cardID: id,
                cardName: name ?? self.name,
                artist: artist,
                artCropURL: artCrop,
                colors: colors ?? fallbackColors,
                setCode: set?.uppercased()
            ))
        }

        // Single-faced (or cards that expose art at the top level).
        make(illustrationID: illustration_id, artCrop: image_uris?.art_crop,
             artist: artist, name: name, colors: fallbackColors)

        // Double-faced cards: one distinct illustration per face.
        for face in card_faces ?? [] {
            make(illustrationID: face.illustration_id, artCrop: face.image_uris?.art_crop,
                 artist: face.artist ?? artist, name: face.name, colors: face.colors)
        }
        return result
    }
}

/// A pair of (illustration-id, art_crop-url) for the optional bulk art download.
public struct ArtImageRef: Sendable {
    public let illustrationID: String
    public let imageURL: String

    public init(illustrationID: String, imageURL: String) {
        self.illustrationID = illustrationID
        self.imageURL = imageURL
    }
}

public extension ScryfallClient {
    /// Extract (illustration_id, art_crop) pairs for the optional "download all art" pass.
    /// Reuses `parseArtworks` so the same flattening/skip rules apply.
    func extractArtRefs(at url: URL) throws -> [ArtImageRef] {
        try parseArtworks(at: url).map {
            ArtImageRef(illustrationID: $0.illustrationID, imageURL: $0.artCropURL)
        }
    }
}

// MARK: - Scryfall raw JSON shape

/// Minimal projection of a Scryfall card object — only the fields we need.
private struct ScryfallCard: Decodable {
    let id: String
    let name: String
    let mana_cost: String?
    let type_line: String?
    let oracle_text: String?
    let power: String?
    let toughness: String?
    let colors: [String]?
    let image_uris: ImageURIs?
    let card_faces: [Face]?
    let scryfall_uri: String?
    let layout: String?
    let released_at: String?
    let set: String?
    let set_name: String?
    let oracle_id: String?
    let rarity: String?
    let cmc: Double?
    let preview: Preview?

    struct Preview: Decodable {
        /// The date the card was first previewed/spoiled — earlier than `released_at`
        /// during preview season, and the closest thing Scryfall exposes to "first
        /// appeared on Scryfall". Only present on cards that went through a preview.
        let previewed_at: String?
    }

    struct ImageURIs: Decodable {
        let small: String?
        let normal: String?
        let large: String?
        let png: String?
    }

    struct Face: Decodable {
        let name: String?
        let mana_cost: String?
        let type_line: String?
        let oracle_text: String?
        let power: String?
        let toughness: String?
        let colors: [String]?
        let image_uris: ImageURIs?
    }

    /// The Scryfall image URL we want to download — prefer normal-size JPG.
    var imageDownloadURL: String? {
        if let n = image_uris?.normal { return n }
        if let n = card_faces?.first?.image_uris?.normal { return n }
        return nil
    }

    func toCard() -> Card? {
        // Skip tokens, art series, planar cards, etc.
        if let l = layout, ["token", "double_faced_token", "art_series", "emblem"].contains(l) {
            return nil
        }
        // Use the image URL as a stable handle on the scryfall_uri field — the app
        // uses it both for image download and "Open Scryfall page" action.
        let scryfallPage = scryfall_uri ?? "https://scryfall.com/card/\(id)"
        // For double-faced cards, fall back to face[0] for stats so search has something.
        let manaCost = mana_cost ?? card_faces?.first?.mana_cost
        let typeLine = type_line ?? card_faces?.first?.type_line
        let oracleText = oracle_text ?? card_faces.map {
            $0.compactMap { $0.oracle_text }.joined(separator: "\n//\n")
        }
        let power = self.power ?? card_faces?.first?.power
        let toughness = self.toughness ?? card_faces?.first?.toughness
        let colors = self.colors ?? card_faces?.first?.colors ?? []
        return Card(
            id: id,
            name: name,
            manaCost: manaCost,
            typeLine: typeLine,
            oracleText: (oracleText?.isEmpty == false) ? oracleText : nil,
            power: power,
            toughness: toughness,
            colors: colors,
            imagePath: nil,
            // Encode the desired image download URL in scryfall_uri? No — keep that
            // semantically correct. Image URL is resolved at download time below.
            scryfallURI: scryfallPage,
            setCode: set?.uppercased(),
            setName: set_name,
            oracleID: oracle_id,
            // "Date added to Scryfall": prefer the preview/spoiler date (when present),
            // fall back to the set release date, then today (rare, no dates at all).
            dateAdded: preview?.previewed_at ?? released_at ?? Self.todayString,
            // Representative rarity for the badge; mana value (cmc) for the `mv:` filter.
            // Both are top-level on every oracle-card object (no face fallback needed).
            rarity: rarity,
            cmc: cmc
        )
    }

    /// Today in the UTC "YYYY-MM-DD" form used for `date_added`.
    static var todayString: String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// Exposed for the image-download path so the fetcher can recover the image URL
    /// without storing it in the DB.
    static func imageURL(forBulkRow raw: [String: Any]) -> String? {
        if let uris = raw["image_uris"] as? [String: Any],
           let normal = uris["normal"] as? String {
            return normal
        }
        if let faces = raw["card_faces"] as? [[String: Any]],
           let first = faces.first,
           let uris = first["image_uris"] as? [String: Any],
           let normal = uris["normal"] as? String {
            return normal
        }
        return nil
    }
}

/// A pair of (card-id, image-url) extracted from the raw bulk JSON, used by the
/// image download phase. We extract these alongside `parseBulk` so we don't have
/// to store image URLs in SQLite.
public struct CardImageRef: Sendable {
    public let id: String
    public let imageURL: String
}

public extension ScryfallClient {
    /// Walk the bulk JSON a second time to extract image URLs.
    /// We do this rather than carrying image URLs through `Card` because they're
    /// only relevant during the fetch phase.
    func extractImageRefs(at url: URL) throws -> [CardImageRef] {
        let data = try Data(contentsOf: url)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        var refs: [CardImageRef] = []
        refs.reserveCapacity(arr.count)
        for raw in arr {
            guard let id = raw["id"] as? String else { continue }
            if let layout = raw["layout"] as? String,
               ["token", "double_faced_token", "art_series", "emblem"].contains(layout) {
                continue
            }
            if let imgURL = ScryfallCard.imageURL(forBulkRow: raw) {
                refs.append(CardImageRef(id: id, imageURL: imgURL))
            }
        }
        return refs
    }
}

// MARK: - Scryfall raw JSON shape (default_cards printing)

/// Minimal projection of a Scryfall card object as it appears in the `default_cards`
/// bulk file — one row per printing (card+set).
private struct ScryfallPrinting: Decodable {
    let id: String
    let oracle_id: String?
    let set: String
    let set_name: String
    let collector_number: String?
    let released_at: String?
    let rarity: String?
    let digital: Bool?
    let games: [String]?
    let lang: String?
    let layout: String?

    func toPrinting() -> Card.Printing? {
        // Skip the same junk layouts as the card ingest.
        if let l = layout, ["token", "double_faced_token", "art_series", "emblem"].contains(l) {
            return nil
        }
        // English only — default_cards still carries some non-English rows; filtering keeps
        // one printing per set instead of one per language.
        if let lang, lang != "en" { return nil }
        // No oracle_id ⇒ can't link to a card (rare split/reversible rows); skip.
        guard let oracle_id else { return nil }
        return Card.Printing(
            printingID: id, oracleID: oracle_id,
            setCode: set.uppercased(), setName: set_name,
            collectorNumber: collector_number, releasedAt: released_at, rarity: rarity,
            digital: digital ?? false, games: games ?? [])
    }
}

// MARK: - Scryfall raw JSON shape (/sets)

private struct ScryfallSet: Decodable {
    let code: String
    let name: String
    let released_at: String?
    let set_type: String?
    let card_count: Int?
    let icon_svg_uri: String?
}

private struct ScryfallSetList: Decodable { let data: [ScryfallSet] }

public extension ScryfallClient {
    /// Decode the `default_cards` bulk JSON into `Card.Printing` records, filtered to English
    /// non-token printings with an oracle_id. Whole-file decode like `parseBulk`; the fetcher
    /// is a short-lived process so transient memory for the ~150 MB blob is acceptable.
    func parsePrintings(at url: URL) throws -> [Card.Printing] {
        let data = try Data(contentsOf: url)
        let raws = try JSONDecoder().decode([ScryfallPrinting].self, from: data)
        return raws.compactMap { $0.toPrinting() }
    }

    /// Fetches the full set catalog from `https://api.scryfall.com/sets`.
    func fetchSets() async throws -> [SetInfo] {
        var request = URLRequest(url: URL(string: "https://api.scryfall.com/sets")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("QuickStudy/1.0 (+https://github.com/Abbabon/quick-study)",
                         forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        let list = try JSONDecoder().decode(ScryfallSetList.self, from: data)
        return list.data.map {
            SetInfo(code: $0.code.uppercased(), name: $0.name, releasedAt: $0.released_at,
                    setType: $0.set_type, cardCount: $0.card_count, iconSVGURI: $0.icon_svg_uri)
        }
    }
}
