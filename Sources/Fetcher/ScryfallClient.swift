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

    public struct BulkInfo: Decodable {
        let object: String
        let type: String
        let download_uri: String
        let updated_at: String
        let size: Int
    }

    private struct BulkIndex: Decodable {
        let data: [BulkInfo]
    }

    /// Fetches the bulk-data index and returns the info entry of the given type.
    /// `type` defaults to "oracle_cards" — one row per unique card name.
    public func bulkInfo(type: String = "oracle_cards") async throws -> BulkInfo {
        let (data, _) = try await session.data(from: Self.bulkIndexURL)
        let index = try JSONDecoder().decode(BulkIndex.self, from: data)
        guard let entry = index.data.first(where: { $0.type == type }) else {
            throw NSError(domain: "ScryfallClient", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "bulk type \(type) not found"])
        }
        return entry
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
            scryfallURI: scryfallPage
        )
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
