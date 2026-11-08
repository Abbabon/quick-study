import Foundation

/// Scryfall bulk-data index contract, shared by the fetcher (which downloads the
/// blob) and the app's update checker (which only reads the `updated_at` timestamp).
/// Docs: https://scryfall.com/docs/api/bulk-data
///
/// The index response is a small, CDN-cached JSON listing one entry per bulk file
/// (`oracle_cards`, `default_cards`, …), each with its own `updated_at` — so checking
/// for new cards never requires downloading the ~100 MB blob or counting cards.
public enum ScryfallBulk {
    public static let indexURL = URL(string: "https://api.scryfall.com/bulk-data")!

    public struct Info: Decodable, Sendable {
        public let object: String
        public let type: String
        /// Scryfall now serves gzipped JSON Lines only (the old `download_uri` is gone).
        /// Optional so an entry without a file never breaks decoding of its siblings.
        public let jsonl_download_uri: String?
        public let updated_at: String
        public let compressed_size: Int?
    }

    private struct Index: Decodable { let data: [Info] }

    static func decodeIndex(_ data: Data) throws -> [Info] {
        try JSONDecoder().decode(Index.self, from: data).data
    }

    /// Fetches the bulk-data index and returns the entry of the given type.
    /// Sends the `User-Agent` / `Accept` headers Scryfall asks API clients to set.
    public static func info(type: String = "oracle_cards",
                            session: URLSession = .shared) async throws -> Info {
        var request = URLRequest(url: indexURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("QuickStudy/1.0 (+https://github.com/Abbabon/quick-study)",
                         forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        guard let entry = try decodeIndex(data).first(where: { $0.type == type }) else {
            throw NSError(domain: "ScryfallBulk", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "bulk type \(type) not found"])
        }
        return entry
    }
}
