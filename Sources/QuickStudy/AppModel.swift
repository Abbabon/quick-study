import Foundation
import SwiftUI
import AppKit
import Shared

/// Single observable source of truth for the panel UI.
@MainActor
final class AppModel: ObservableObject {
    @Published var query: String = ""
    @Published var results: [Card.Mini] = []
    @Published var selectedID: String?
    @Published var selectedCard: Card?
    @Published var pinned: [Card.Mini] = []
    @Published var recentlyAdded: [Card.Recent] = []
    /// Session UI state for the Recently Added column (not persisted).
    @Published var recentlyAddedExpanded: Bool = true
    /// The recent card currently shown via the column, driving the preview meta strip.
    @Published var selectedRecent: Card.Recent?
    @Published var refreshState: RefreshState = .idle
    @Published var dbState: DBState = .unknown
    @Published var totalCards: Int = 0
    @Published var lastRefresh: String?
    @Published var imageCacheSizeFormatted: String = "—"
    /// True when Scryfall has card data newer than what we last ingested.
    @Published var updateAvailable: Bool = false
    /// The remote `oracle_cards.updated_at` behind `updateAvailable`, for display.
    @Published var availableUpdateStamp: String?
    /// State of the app self-update flow (separate from the card-data update above).
    @Published var appUpdateState: AppUpdateState = .none

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

    /// Lifecycle of the app self-update. Manual installs auto-download then wait at
    /// `.readyToRelaunch`; Homebrew installs sit at `.available` until the user clicks Update.
    enum AppUpdateState: Equatable {
        case none
        case available(version: String, kind: AppUpdater.InstallKind)
        case downloading(version: String)
        case readyToRelaunch(version: String)
        case installing
        case failed(String)

        /// The version this state refers to, for notifications, dismissal, and display.
        var version: String? {
            switch self {
            case let .available(version, _), let .downloading(version),
                 let .readyToRelaunch(version):
                return version
            case .none, .installing, .failed:
                return nil
            }
        }

        /// True when there's something the user can act on (update or relaunch).
        var isActionable: Bool {
            switch self {
            case .available, .readyToRelaunch: return true
            case .none, .downloading, .installing, .failed: return false
            }
        }
    }

    private final class CachedCard { let card: Card; init(_ c: Card) { self.card = c } }

    /// Cards added within this many days get the accent "new" treatment.
    static let newWindowDays = 7

    /// Count of recently-added cards that landed within the "new" window.
    var newCount: Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.newWindowDays, to: Date()) ?? Date()
        return recentlyAdded.filter { $0.dateAdded >= cutoff }.count
    }

    func isNew(_ recent: Card.Recent) -> Bool {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.newWindowDays, to: Date()) ?? Date()
        return recent.dateAdded >= cutoff
    }

    /// Whether the column should appear at all: enabled in settings AND non-empty.
    var showsRecentColumn: Bool {
        let enabled = UserDefaults.standard.object(forKey: "showRecentlyAdded") as? Bool ?? true
        return enabled && !recentlyAdded.isEmpty
    }

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
                recentlyAdded = (try? store.recentlyAdded()) ?? []
            }
            refreshImageCacheSize()
        } catch {
            dbState = .unknown
        }
    }

    func runSearch() {
        // Empty query → browse mode. Preserve a card opened from the Recently Added
        // column (this also guards the deferred onChange that `selectRecent` triggers
        // when it clears the query); otherwise fall back to the placeholder.
        guard !query.isEmpty else {
            results = []
            if selectedRecent == nil {
                selectedID = nil
                selectedCard = nil
            }
            return
        }
        selectedRecent = nil
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

    func deselect() {
        selectedID = nil
        selectedCard = nil
        selectedRecent = nil
    }

    /// Opens a card from the Recently Added column: selects it, records it for the
    /// preview meta strip, and clears the query so the panel enters browse mode.
    func selectRecent(_ recent: Card.Recent) {
        query = ""
        results = []
        select(recent.id)
        selectedRecent = recent
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
        let identity: ColorIdentity

        enum CodingKeys: String, CodingKey { case id, name, identity }

        init(id: String, name: String, identity: ColorIdentity) {
            self.id = id
            self.name = name
            self.identity = identity
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            // Older persisted pins predate `identity`; default to colorless.
            identity = try c.decodeIfPresent(ColorIdentity.self, forKey: .identity) ?? .colorless
        }
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
        togglePin(Card.Mini(id: card.id, name: card.name, colors: card.colors))
    }

    func unpin(_ id: String) {
        guard let idx = pinned.firstIndex(where: { $0.id == id }) else { return }
        pinned.remove(at: idx)
        persistPins()
        onPinnedChange?()
    }

    private func persistPins() {
        let refs = pinned.map { PinnedRef(id: $0.id, name: $0.name, identity: $0.identity) }
        guard let data = try? JSONEncoder().encode(refs) else { return }
        UserDefaults.standard.set(data, forKey: Self.pinsDefaultsKey)
    }

    private func loadPins() {
        guard let data = UserDefaults.standard.data(forKey: Self.pinsDefaultsKey),
              let refs = try? JSONDecoder().decode([PinnedRef].self, from: data) else { return }
        pinned = refs.map { Card.Mini(id: $0.id, name: $0.name, identity: $0.identity) }
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

    // MARK: - App self-update

    private enum AppUpdateKeys {
        static let lastCheck = "lastAppUpdateCheck"
        static let dismissedVersion = "dismissedAppVersion"
        static let autoCheck = "appUpdateAutoCheck"
    }
    /// The most recent release fetched, kept so `installOrRelaunch` can open the release page
    /// as a fallback when a manual install has no downloadable zip asset.
    private var latestRelease: AppUpdateChecker.ReleaseInfo?
    /// The verified, staged `.app` awaiting swap-in (manual install path only).
    private var stagedAppURL: URL?

    /// The running app version, for display in Settings.
    var currentAppVersion: String { AppUpdateChecker.currentVersion() ?? "—" }

    /// Checks GitHub for a newer app release and drives `appUpdateState`. Safe to call on
    /// launch, panel show, and a daily timer — the network call is throttled and the
    /// notification (driven off `appUpdateState` by the AppDelegate) is deduped by version.
    /// Pass `force` to bypass both the auto-check toggle and the throttle (e.g. the Settings
    /// "Check for updates" button and the first check at launch).
    func checkForAppUpdate(force: Bool = false) {
        guard AppUpdater.isRunningFromAppBundle else { return } // no bundle under `swift run`
        guard let current = AppUpdateChecker.currentVersion() else { return }
        let defaults = UserDefaults.standard
        if !force {
            if defaults.object(forKey: AppUpdateKeys.autoCheck) != nil,
               !defaults.bool(forKey: AppUpdateKeys.autoCheck) { return }
            if let last = defaults.object(forKey: AppUpdateKeys.lastCheck) as? Date,
               Date().timeIntervalSince(last) < Self.checkThrottle { return }
        }
        // Don't clobber an in-progress download or a staged-and-ready update.
        switch appUpdateState {
        case .downloading, .readyToRelaunch: return
        default: break
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let release = await AppUpdateChecker.fetchLatest() else { return }
            defaults.set(Date(), forKey: AppUpdateKeys.lastCheck)
            self.latestRelease = release
            let dismissed = defaults.string(forKey: AppUpdateKeys.dismissedVersion)
            guard AppUpdateChecker.shouldPrompt(remote: release.version,
                                                current: current,
                                                dismissed: dismissed) else {
                if case .failed = self.appUpdateState {} else { self.appUpdateState = .none }
                return
            }
            let kind = AppUpdater.detect()
            if kind == .manual, let zipURL = release.zipURL {
                self.appUpdateState = .downloading(version: release.version)
                do {
                    let staged = try await AppUpdater.downloadAndStage(zipURL: zipURL,
                                                                       expectedVersion: release.version)
                    self.stagedAppURL = staged
                    self.appUpdateState = .readyToRelaunch(version: release.version)
                } catch {
                    self.appUpdateState = .failed(error.localizedDescription)
                }
            } else {
                self.appUpdateState = .available(version: release.version, kind: kind)
            }
        }
    }

    /// Acts on the current `appUpdateState`: relaunch into the staged build (manual),
    /// run `brew upgrade` (Homebrew), or open the release page (manual with no zip asset).
    /// On success the app terminates and a detached helper completes the install.
    func installOrRelaunch() {
        do {
            switch appUpdateState {
            case .readyToRelaunch:
                guard let staged = stagedAppURL else { return }
                try AppUpdater.installStagedAndRelaunch(stagedApp: staged)
            case let .available(_, kind):
                switch kind {
                case .homebrew:
                    appUpdateState = .installing
                    try AppUpdater.brewUpgradeAndRelaunch()
                case .manual:
                    // No downloadable asset — open the release page for a manual download.
                    if let page = latestRelease?.pageURL { NSWorkspace.shared.open(page) }
                }
            default:
                break
            }
        } catch {
            appUpdateState = .failed(error.localizedDescription)
        }
    }

    /// User dismissed the app-update prompt — suppress it until a strictly newer version.
    func dismissAppUpdate() {
        if let version = appUpdateState.version {
            UserDefaults.standard.set(version, forKey: AppUpdateKeys.dismissedVersion)
        }
        appUpdateState = .none
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
