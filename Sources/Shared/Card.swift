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
    /// The representative printing's rarity ("common"/"uncommon"/"rare"/"mythic"/…),
    /// shown as an at-a-glance badge. NULL on rows ingested before this column existed.
    public let rarity: String?
    /// Scryfall mana value (converted mana cost). Drives the `mv:`/`cmc:` search filter.
    public let cmc: Double?

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
        dateAdded: String? = nil,
        rarity: String? = nil,
        cmc: Double? = nil
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
        self.rarity = rarity
        self.cmc = cmc
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
        /// Representative rarity for the at-a-glance badge. nil when unknown (un-refreshed rows).
        public let rarity: String?

        /// Legacy init for callers with no colors data; identity will be .colorless.
        public init(id: String, name: String) {
            self.init(id: id, name: name, identity: .colorless)
        }

        public init(id: String, name: String, colors: [String],
                    setCode: String? = nil, setName: String? = nil, rarity: String? = nil) {
            self.init(id: id, name: name, identity: ColorIdentity(colors: colors),
                      setCode: setCode, setName: setName, rarity: rarity)
        }

        /// Direct init for callers that already know the identity (e.g. pin deserialization).
        public init(id: String, name: String, identity: ColorIdentity,
                    setCode: String? = nil, setName: String? = nil, rarity: String? = nil) {
            self.id = id
            self.name = name
            self.nameLower = name.lowercased()
            self.identity = identity
            self.setCodeLower = setCode?.lowercased()
            self.setNameLower = setName?.lowercased()
            self.rarity = rarity
        }
    }

    /// Per-card metadata loaded into memory for inline search filters (`r:`/`c:`/`t:`/
    /// `mv:`/`o:`). Kept separate from `Card.Mini` (which stays lean for name ranking) and
    /// keyed by card `id` in `SearchEngine`. `rarities` is the set of every rarity the card
    /// has ever been printed at (from the `printings` table, unioned with the representative
    /// `rarity` as a fallback) — this is what makes `r:common` mean "ever printed common".
    public struct FilterFields: Sendable, Equatable {
        public let colors: [String]
        public let typeLineLower: String?
        public let oracleTextLower: String?
        public let cmc: Double?
        public let rarities: Set<String>

        public init(colors: [String], typeLineLower: String?, oracleTextLower: String?,
                    cmc: Double?, rarities: Set<String>) {
            self.colors = colors
            self.typeLineLower = typeLineLower
            self.oracleTextLower = oracleTextLower
            self.cmc = cmc
            self.rarities = rarities
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
        /// Scryfall web page for this exact printing (`/card/{set}/{collector}`).
        /// Falls back to the set's card list when the collector number is unknown.
        public var scryfallURL: URL? {
            let set = setCode.lowercased()
            if let number = collectorNumber, !number.isEmpty,
               let encoded = number.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                return URL(string: "https://scryfall.com/card/\(set)/\(encoded)")
            }
            return URL(string: "https://scryfall.com/sets/\(set)")
        }

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
