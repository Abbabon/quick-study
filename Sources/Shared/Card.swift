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
    /// set label, and a parsed date for relative-time + the ≤7-day "new" flag.
    public struct Recent: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let identity: ColorIdentity
        public let setCode: String?
        public let setName: String?
        public let dateAdded: Date

        public init(id: String, name: String, colors: [String],
                    setCode: String?, setName: String?, dateAdded: Date) {
            self.id = id
            self.name = name
            self.identity = ColorIdentity(colors: colors)
            self.setCode = setCode
            self.setName = setName
            self.dateAdded = dateAdded
        }
    }
}
