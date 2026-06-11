import Foundation
import SwiftUI
import Shared

/// Single observable source of truth for the panel UI.
@MainActor
final class AppModel: ObservableObject {
    @Published var query: String = ""
    @Published var results: [Card.Mini] = []
    @Published var selectedID: String?
    @Published var selectedCard: Card?
    @Published var pinned: [Card.Mini] = []
    @Published var refreshState: RefreshState = .idle
    @Published var dbState: DBState = .unknown
    @Published var totalCards: Int = 0
    @Published var lastRefresh: String?
    @Published var imageCacheSizeFormatted: String = "—"
    /// True when Scryfall has card data newer than what we last ingested.
    @Published var updateAvailable: Bool = false
    /// The remote `oracle_cards.updated_at` behind `updateAvailable`, for display.
    @Published var availableUpdateStamp: String?

    let engine = SearchEngine()
    let fetcher = FetcherProcess()
    private var store: CardStore?
    private let detailCache = NSCache<NSString, CachedCard>()

    /// Invoked (on the main actor) whenever the pinned set changes, so the panel
    /// can resize to fit/free the pinned row without compromising the preview.
    var onPinnedChange: (() -> Void)?

    enum DBState: Equatable {
        case unknown, empty, ready
    }

    enum RefreshState: Equatable {
        case idle
        case running(phase: String, done: Int, total: Int)
        case error(String)
    }

    private final class CachedCard { let card: Card; init(_ c: Card) { self.card = c } }

    init() {
        self.store = try? CardStore()
        loadPins()
        refreshDBState()
    }

    func refreshDBState() {
        guard let store = store else { dbState = .unknown; return }
        do {
            let n = try store.count()
            totalCards = n
            lastRefresh = try? store.meta("last_refresh")
            if n == 0 {
                dbState = .empty
            } else {
                dbState = .ready
                engine.load(try store.loadMinis())
            }
            refreshImageCacheSize()
        } catch {
            dbState = .unknown
        }
    }

    func runSearch() {
        results = engine.search(query)
        if let first = results.first, selectedID == nil || !results.contains(where: { $0.id == selectedID }) {
            select(first.id)
        } else if results.isEmpty {
            selectedID = nil
            selectedCard = nil
        }
    }

    /// Clears all transient search UI state so the next show is a fresh session.
    func resetSearchState() {
        query = ""
        selectedID = nil
        selectedCard = nil
        results = []
    }

    func select(_ id: String) {
        selectedID = id
        if let cached = detailCache.object(forKey: id as NSString) {
            selectedCard = cached.card
            return
        }
        guard let store = store else { return }
        if let card = try? store.card(id: id) {
            selectedCard = card
            detailCache.setObject(CachedCard(card), forKey: id as NSString)
        }
    }

    func selectNext() {
        guard !results.isEmpty else { return }
        let idx = results.firstIndex(where: { $0.id == selectedID }) ?? -1
        let next = min(idx + 1, results.count - 1)
        select(results[next].id)
    }

    func selectPrev() {
        guard !results.isEmpty else { return }
        let idx = results.firstIndex(where: { $0.id == selectedID }) ?? results.count
        let prev = max(idx - 1, 0)
        select(results[prev].id)
    }

    // MARK: - Pins

    private static let pinsDefaultsKey = "pinnedCards"

    /// Persisted shape for a pinned card. `Card.Mini` isn't `Codable`, and storing
    /// the name avoids a store read just to draw the pinned row.
    private struct PinnedRef: Codable {
        let id: String
        let name: String
    }

    func isPinned(_ id: String) -> Bool {
        pinned.contains { $0.id == id }
    }

    /// Toggles a card's pinned state, preserving insertion order, then persists.
    func togglePin(_ mini: Card.Mini) {
        if let idx = pinned.firstIndex(where: { $0.id == mini.id }) {
            pinned.remove(at: idx)
        } else {
            pinned.append(mini)
        }
        persistPins()
        onPinnedChange?()
    }

    /// Toggles the currently-previewed card. No-op when nothing is selected.
    func togglePinSelected() {
        guard let card = selectedCard else { return }
        togglePin(Card.Mini(id: card.id, name: card.name))
    }

    func unpin(_ id: String) {
        guard let idx = pinned.firstIndex(where: { $0.id == id }) else { return }
        pinned.remove(at: idx)
        persistPins()
        onPinnedChange?()
    }

    private func persistPins() {
        let refs = pinned.map { PinnedRef(id: $0.id, name: $0.name) }
        guard let data = try? JSONEncoder().encode(refs) else { return }
        UserDefaults.standard.set(data, forKey: Self.pinsDefaultsKey)
    }

    private func loadPins() {
        guard let data = UserDefaults.standard.data(forKey: Self.pinsDefaultsKey),
              let refs = try? JSONDecoder().decode([PinnedRef].self, from: data) else { return }
        pinned = refs.map { Card.Mini(id: $0.id, name: $0.name) }
    }

    // MARK: - Image cache

    func refreshImageCacheSize() {
        let bytes = (try? ImageCache.size(at: Paths.imagesDir)) ?? 0
        imageCacheSizeFormatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Returns bytes freed. Refreshes the published formatted size.
    @discardableResult
    func clearImageCache() -> Int64 {
        let freed = (try? ImageCache.clear(at: Paths.imagesDir)) ?? 0
        refreshImageCacheSize()
        return freed
    }

    // MARK: - Update check

    private enum UpdateKeys {
        static let lastCheck = "lastUpdateCheck"
        static let dismissedStamp = "dismissedUpdateStamp"
    }
    /// Soft throttle for the network call so repeated panel toggles don't hammer Scryfall.
    private static let checkThrottle: TimeInterval = 60 * 60 // 1 hour

    /// Checks Scryfall for newer card data and updates `updateAvailable`. Safe to call on
    /// launch, on panel show, and on a daily timer — the network call is throttled and the
    /// notification (driven off `updateAvailable` by the AppDelegate) is deduped by stamp.
    /// Pass `force` to bypass the throttle (e.g. the first check at launch).
    func checkForUpdates(force: Bool = false) {
        guard dbState == .ready else { return }
        let defaults = UserDefaults.standard
        let now = Date()
        if !force, let last = defaults.object(forKey: UpdateKeys.lastCheck) as? Date,
           now.timeIntervalSince(last) < Self.checkThrottle { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let remote = await UpdateChecker.fetchLatestStamp() else { return }
            defaults.set(now, forKey: UpdateKeys.lastCheck)
            let ingested = try? self.store?.meta("bulk_updated_at")
            let dismissed = defaults.string(forKey: UpdateKeys.dismissedStamp)
            if UpdateChecker.shouldPrompt(remote: remote,
                                          ingested: ingested ?? nil,
                                          dismissed: dismissed) {
                self.availableUpdateStamp = remote
                self.updateAvailable = true
            } else {
                self.updateAvailable = false
            }
        }
    }

    /// User dismissed the prompt — suppress it until a strictly newer stamp appears.
    func dismissUpdate() {
        if let stamp = availableUpdateStamp {
            UserDefaults.standard.set(stamp, forKey: UpdateKeys.dismissedStamp)
        }
        updateAvailable = false
    }

    /// Human-friendly form of `availableUpdateStamp` for banners/Settings.
    var availableUpdateDisplay: String? {
        guard let stamp = availableUpdateStamp, let date = UpdateChecker.parse(stamp) else { return nil }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }

    // MARK: - Refresh

    func startRefresh(skipImages: Bool = false) {
        guard case .idle = refreshState else { return }
        refreshState = .running(phase: "starting", done: 0, total: 0)
        Task { [weak self] in
            await self?.fetcher.run(skipImages: skipImages) { event in
                Task { @MainActor [weak self] in
                    self?.applyFetcherEvent(event)
                }
            }
        }
    }

    private func applyFetcherEvent(_ event: FetcherProcess.Event) {
        switch event.phase {
        case "done":
            refreshState = .idle
            refreshDBState()
            // Baseline (`bulk_updated_at`) is now current, so any pending prompt is stale.
            updateAvailable = false
        case "error":
            refreshState = .error(event.message ?? "unknown error")
        case "exit":
            refreshState = .idle
            refreshDBState()
        default:
            refreshState = .running(phase: event.phase, done: event.done ?? 0, total: event.total ?? 0)
        }
    }
}
