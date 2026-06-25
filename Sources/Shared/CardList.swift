import Foundation

/// A named, persistent collection of cards. Unlike pins (an ephemeral `UserDefaults`
/// scratch set), lists are durable and ordered, so they live in SQLite — see the
/// `card_lists` / `card_list_items` tables in `CardStore`.
public struct CardList: Sendable, Equatable, Identifiable {
    public let id: String            // UUID
    public var name: String
    /// "yyyy-MM-dd HH:mm:ss" in UTC — stable creation order key.
    public let createdAt: String
    /// "yyyy-MM-dd HH:mm:ss" in UTC — bumped on rename / membership change.
    public var updatedAt: String
    /// Number of cards in the list (populated by `CardStore.loadLists`).
    public var itemCount: Int

    public init(id: String, name: String, createdAt: String, updatedAt: String, itemCount: Int) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.itemCount = itemCount
    }
}
