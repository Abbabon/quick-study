import EngineBindings
import Foundation
import Shared

// Rust returns plain records; these map them onto the UI's view types in `Shared`.

extension CardDetail {
    var card: Card {
        Card(id: id, name: name, manaCost: manaCost, typeLine: typeLine, oracleText: oracleText,
             power: power, toughness: toughness, colors: colors, imagePath: imagePath,
             scryfallURI: scryfallUri, oracleID: oracleId, rarity: rarity, cmc: cmc)
    }
}

extension PrintingRow {
    var printing: Card.Printing {
        Card.Printing(printingID: printingId, oracleID: oracleId, setCode: setCode, setName: setName,
                      collectorNumber: collectorNumber, releasedAt: releasedAt, rarity: rarity,
                      digital: digital, games: games)
    }
}

extension RecentCard {
    /// `nil` when the stored day doesn't parse (the row is then skipped).
    var recent: Card.Recent? {
        guard let seen = Self.dayFormatter.date(from: firstSeen) else { return nil }
        return Card.Recent(id: id, name: name, colors: colors, setCode: setCode, setName: setName, firstSeen: seen)
    }

    /// UTC, day-granularity, matching the stored "YYYY-MM-DD".
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

extension ArtworkRow {
    var artwork: Artwork {
        Artwork(illustrationID: illustrationId, cardID: cardId, cardName: cardName, artist: artist,
                artCropURL: artCropUrl, colors: colors, setCode: setCode)
    }
}

extension ListSummary {
    var list: CardList {
        CardList(id: id, name: name, createdAt: createdAt, updatedAt: updatedAt, itemCount: Int(itemCount))
    }
}

/// Scryfall bulk `updated_at` stamp as a `Date` (via the engine's parser).
func stampDate(_ stamp: String) -> Date? {
    stampUnixMs(stamp: stamp).map { Date(timeIntervalSince1970: Double($0) / 1000) }
}
