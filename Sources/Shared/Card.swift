import Foundation

/// Magic color identity used for frame/thumbnail/badge tints.
/// Two or more colors collapse to `.multicolor` (gold) — never a blend.
public enum ColorIdentity: String, Sendable, Equatable, Codable {
    case white, blue, black, red, green, colorless, multicolor

    public init(colors: [String]) {
        if colors.count >= 2 {
            self = .multicolor
            return
        }
        switch colors.first {
        case "W": self = .white
        case "U": self = .blue
        case "B": self = .black
        case "R": self = .red
        case "G": self = .green
        default:  self = .colorless
        }
    }
}

public struct Card: Codable, Equatable, Sendable {
    public let id: String          // Scryfall UUID, primary key
    public let name: String
    public let manaCost: String?
    public let typeLine: String?
    public let oracleText: String?
    public let power: String?
    public let toughness: String?
    public let colors: [String]    // e.g. ["R"], ["W","U"]
    public let imagePath: String?  // relative to Paths.imagesDir, nil if not downloaded
    public let scryfallURI: String
    public let setCode: String?
    public let setName: String?
    /// Stable Scryfall oracle identity (`oracle_id`). The join key to the `printings`
    /// table. Distinct from `id`, which is one representative printing's UUID. NULL on
    /// rows ingested before this column existed (backfilled by the next ingest).
    public let oracleID: String?
    public let dateAdded: String?  // "YYYY-MM-DD" (Scryfall released_at), nil if unknown

    public init(
        id: String,
        name: String,
        manaCost: String?,
        typeLine: String?,
        oracleText: String?,
        power: String?,
        toughness: String?,
        colors: [String],
        imagePath: String?,
        scryfallURI: String,
        setCode: String? = nil,
        setName: String? = nil,
        oracleID: String? = nil,
        dateAdded: String? = nil
    ) {
        self.id = id
        self.name = name
        self.manaCost = manaCost
        self.typeLine = typeLine
        self.oracleText = oracleText
        self.power = power
        self.toughness = toughness
        self.colors = colors
        self.imagePath = imagePath
        self.scryfallURI = scryfallURI
        self.setCode = setCode
        self.setName = setName
        self.oracleID = oracleID
        self.dateAdded = dateAdded
    }

    public var identity: ColorIdentity { ColorIdentity(colors: colors) }

    /// Minimal projection loaded into memory for fast search ranking.
    public struct Mini: Sendable, Equatable {
        public let id: String
        public let name: String
        public let nameLower: String
        public let identity: ColorIdentity
        /// Lowercased set abbreviation (e.g. "msc"); set codes are stored uppercase in the DB.
        public let setCodeLower: String?
        /// Lowercased full set name (e.g. "modern horizons").
        public let setNameLower: String?

        /// Legacy init for callers with no colors data; identity will be .colorless.
        public init(id: String, name: String) {
            self.init(id: id, name: name, identity: .colorless)
        }

        public init(id: String, name: String, colors: [String],
                    setCode: String? = nil, setName: String? = nil) {
            self.init(id: id, name: name, identity: ColorIdentity(colors: colors),
                      setCode: setCode, setName: setName)
        }

        /// Direct init for callers that already know the identity (e.g. pin deserialization).
        public init(id: String, name: String, identity: ColorIdentity,
                    setCode: String? = nil, setName: String? = nil) {
            self.id = id
            self.name = name
            self.nameLower = name.lowercased()
            self.identity = identity
            self.setCodeLower = setCode?.lowercased()
            self.setNameLower = setName?.lowercased()
        }
    }

    /// Projection for the Recently Added column: identity for the thumbnail tint,
    /// set label, and `firstSeen` — the date the card first appeared in our DB —
    /// driving newest-first ordering, relative-time, and the ≤7-day "new" flag.
    public struct Recent: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let identity: ColorIdentity
        public let setCode: String?
        public let setName: String?
        public let firstSeen: Date

        public init(id: String, name: String, colors: [String],
                    setCode: String?, setName: String?, firstSeen: Date) {
            self.id = id
            self.name = name
            self.identity = ColorIdentity(colors: colors)
            self.setCode = setCode
            self.setName = setName
            self.firstSeen = firstSeen
        }
    }

    /// One printing of a card (a card+set row from Scryfall's `default_cards`). Drives the
    /// preview Printings list. `oracleID` links it back to the oracle `Card`. `digital` +
    /// `games` distinguish MTGO/Arena-only printings for the display toggles. `printing_id`
    /// is reserved for a future "download this specific version" flow.
    public struct Printing: Sendable, Equatable, Identifiable {
        public let printingID: String
        public let oracleID: String?
        public let setCode: String
        public let setName: String
        public let collectorNumber: String?
        public let releasedAt: String?   // "YYYY-MM-DD"
        public let rarity: String?
        public let digital: Bool
        public let games: [String]       // e.g. ["paper","mtgo"], ["arena"]

        public var id: String { printingID }
        /// Four-digit year of `releasedAt`, if present.
        public var year: String? { releasedAt.map { String($0.prefix(4)) } }
        /// A digital printing that exists only on Magic Online.
        public var isMTGOOnly: Bool { digital && games == ["mtgo"] }
        /// A digital printing that exists only on Arena.
        public var isArenaOnly: Bool { digital && games == ["arena"] }

        public init(printingID: String, oracleID: String?, setCode: String, setName: String,
                    collectorNumber: String?, releasedAt: String?, rarity: String?,
                    digital: Bool, games: [String]) {
            self.printingID = printingID
            self.oracleID = oracleID
            self.setCode = setCode
            self.setName = setName
            self.collectorNumber = collectorNumber
            self.releasedAt = releasedAt
            self.rarity = rarity
            self.digital = digital
            self.games = games
        }
    }

    /// A set and the IDs of the cards printed in it. Built by `CardStore.loadSetIndex()`
    /// and consumed by `SearchEngine` so a set query expands to all its member cards.
    public struct SetGroup: Sendable, Equatable {
        public let code: String
        public let name: String
        public let memberIDs: [String]

        public init(code: String, name: String, memberIDs: [String]) {
            self.code = code
            self.name = name
            self.memberIDs = memberIDs
        }
    }
}
