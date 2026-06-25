import Foundation

/// A Magic set ("set markings") from Scryfall's `/sets` endpoint. `iconSVGURI` is stored
/// for a future set-symbol rendering pass; today the UI shows set codes as text.
public struct SetInfo: Sendable, Equatable, Identifiable {
    public let code: String          // uppercase, primary key
    public let name: String
    public let releasedAt: String?   // "YYYY-MM-DD"
    public let setType: String?
    public let cardCount: Int?
    public let iconSVGURI: String?

    public var id: String { code }

    public init(code: String, name: String, releasedAt: String?, setType: String?,
                cardCount: Int?, iconSVGURI: String?) {
        self.code = code
        self.name = name
        self.releasedAt = releasedAt
        self.setType = setType
        self.cardCount = cardCount
        self.iconSVGURI = iconSVGURI
    }
}
