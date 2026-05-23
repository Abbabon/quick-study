import Foundation

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

    /// Minimal projection loaded into memory for fast search ranking.
    public struct Mini: Sendable, Equatable {
        public let id: String
        public let name: String
        public let nameLower: String
        public init(id: String, name: String) {
            self.id = id
            self.name = name
            self.nameLower = name.lowercased()
        }
    }
}
