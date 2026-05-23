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
    @Published var refreshState: RefreshState = .idle
    @Published var dbState: DBState = .unknown
    @Published var totalCards: Int = 0
    @Published var lastRefresh: String?
    @Published var imageCacheSizeFormatted: String = "—"

    let engine = SearchEngine()
    let fetcher = FetcherProcess()
    private var store: CardStore?
    private let detailCache = NSCache<NSString, CachedCard>()

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
