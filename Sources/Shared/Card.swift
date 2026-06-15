import Foundation

/// Magic color identity used for frame/thumbnail/badge tints.
/// Two or more colors collapse to `.multicolor` (gold) — never a blend.
public enum ColorIdentity: Sendable, Equatable {
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
        scryfallURI: String
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
    }

    public var identity: ColorIdentity { ColorIdentity(colors: colors) }

    /// Minimal projection loaded into memory for fast search ranking.
    public struct Mini: Sendable, Equatable {
        public let id: String
        public let name: String
        public let nameLower: String
        public let identity: ColorIdentity

        /// Kept for callers (and tests) that don't need identity; defaults to colorless.
        public init(id: String, name: String) {
            self.init(id: id, name: name, colors: [])
        }

        public init(id: String, name: String, colors: [String]) {
            self.id = id
            self.name = name
            self.nameLower = name.lowercased()
            self.identity = ColorIdentity(colors: colors)
        }
    }
}
