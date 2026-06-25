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
    /// Printings of the selected card, for the preview's Printings list. Loaded lazily on
    /// selection from `CardStore.printings(forOracleID:)`.
    @Published var selectedPrintings: [Card.Printing] = []
    @Published var pinned: [Card.Mini] = []
    /// User-curated lists (durable, SQLite-backed). `activeListID` is the "current" list
    /// for add-to-current and the one whose cards are shown expanded in the column.
    @Published var lists: [CardList] = []
    @Published var activeListID: String?
    @Published var activeListCards: [Card.Mini] = []
    /// Session toggle for the right-side Lists column, persisted like other UI prefs.
    @Published var listsColumnVisible: Bool = UserDefaults.standard.bool(forKey: "showLists")
    /// Set when a list should open in inline-rename mode (just-created lists). The column
    /// clears it once it has taken focus.
    @Published var renamingListID: String?
    @Published var recentlyAdded: [Card.Recent] = []
    /// Open/closed state for the Recently Added column, persisted across launches.
    /// Defaults to expanded for first-time users (no stored value yet).
    @Published var recentlyAddedExpanded: Bool =
        UserDefaults.standard.object(forKey: "showRecentlyAddedColumn") as? Bool ?? true
    {
        didSet { UserDefaults.standard.set(recentlyAddedExpanded, forKey: "showRecentlyAddedColumn") }
    }
    /// The recent card currently shown via the column, driving the preview meta strip.
    @Published var selectedRecent: Card.Recent?
    @Published var refreshState: RefreshState = .idle
    @Published var dbState: DBState = .unknown
    @Published var totalCards: Int = 0
    @Published var lastRefresh: String?
    @Published var imageCacheSizeFormatted: String = "—"
    /// Number of distinct artworks ingested for the game modes (0 = not downloaded yet).
    @Published var artworkCount: Int = 0
    @Published var artCacheSizeFormatted: String = "—"
    /// Number of brand-new cards ingested in the background whose images are not yet
    /// downloaded. Drives the menu-bar dot, dropdown item, and notification.
    @Published var newCardsPendingImages: Int = 0
    /// Back-compat alias for existing view bindings: true while images are pending.
    var updateAvailable: Bool { newCardsPendingImages > 0 }
    /// Set while a background silent ingest is running, so the cheap check doesn't
    /// launch a second fetcher and `startRefresh`/`startImageDownload` can defer.
    private var backgroundSyncing = false
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

    /// Invoked (on the main actor) whenever the Lists column is shown/hidden, so the
    /// panel can grow/shrink its width to fit the column (mirrors `onPinnedChange`).
    var onListsColumnChange: (() -> Void)?

    /// Invoked (on the main actor) to open the Settings window — wired by
    /// `AppDelegate` so the in-panel gear button can reach it without the menu bar.
    var onOpenSettings: (() -> Void)?

    /// Invoked (on the main actor) to open the game window — wired by `AppDelegate`
    /// so the in-panel play button can reach it without the menu bar.
    var onOpenGame: (() -> Void)?

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

        /// True when a downloaded update is staged and only a relaunch is left.
        var isReadyToRelaunch: Bool {
            if case .readyToRelaunch = self { return true }
            return false
        }
    }

    private final class CachedCard { let card: Card; init(_ c: Card) { self.card = c } }

    /// Cards added within this many days get the accent "new" treatment.
    static let newWindowDays = 7

    /// Count of recently-added cards that landed within the "new" window.
    var newCount: Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.newWindowDays, to: Date()) ?? Date()
        return recentlyAdded.filter { $0.firstSeen >= cutoff }.count
    }

    func isNew(_ recent: Card.Recent) -> Bool {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.newWindowDays, to: Date()) ?? Date()
        return recent.firstSeen >= cutoff
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
                engine.load(try store.loadMinis(), sets: (try? store.loadSetIndex()) ?? [])
                recentlyAdded = (try? store.recentlyAdded()) ?? []
                reloadLists()
            }
            refreshImageCacheSize()
            refreshArtworkState()
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
                selectedPrintings = []
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
        selectedPrintings = []
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
            loadPrintings(for: cached.card)
            return
        }
        guard let store = store else { return }
        if let card = try? store.card(id: id) {
            selectedCard = card
            detailCache.setObject(CachedCard(card), forKey: id as NSString)
            loadPrintings(for: card)
        }
    }

    /// Loads the selected card's printings (empty if it has no `oracleID`, e.g. ingested
    /// before printings existed or before the first --printings refresh).
    private func loadPrintings(for card: Card) {
        guard let store = store, let oid = card.oracleID else { selectedPrintings = []; return }
        selectedPrintings = (try? store.printings(forOracleID: oid)) ?? []
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

    // MARK: - Lists

    private static let activeListDefaultsKey = "activeListID"

    /// Reloads lists from the store, restores/repairs the active selection, and refreshes
    /// the active list's cards. Called on launch and after any mutation.
    func reloadLists() {
        guard let store = store else { return }
        lists = (try? store.loadLists()) ?? []
        // Restore the persisted active list on first load; drop it if it was deleted.
        if activeListID == nil {
            activeListID = UserDefaults.standard.string(forKey: Self.activeListDefaultsKey)
        }
        if let id = activeListID, !lists.contains(where: { $0.id == id }) {
            activeListID = lists.first?.id
        } else if activeListID == nil {
            activeListID = lists.first?.id
        }
        persistActiveList()
        reloadActiveListCards()
    }

    /// The currently active list, if any.
    var activeList: CardList? {
        lists.first { $0.id == activeListID }
    }

    func reloadActiveListCards() {
        guard let store = store, let id = activeListID else { activeListCards = []; return }
        activeListCards = (try? store.listItems(listID: id)) ?? []
    }

    func setActiveList(_ id: String?) {
        activeListID = id
        persistActiveList()
        reloadActiveListCards()
    }

    private func persistActiveList() {
        UserDefaults.standard.set(activeListID, forKey: Self.activeListDefaultsKey)
    }

    func toggleListsColumn() {
        listsColumnVisible.toggle()
        UserDefaults.standard.set(listsColumnVisible, forKey: "showLists")
        onListsColumnChange?()
    }

    /// Creates a list, makes it active, and flags it for inline rename. Returns its id.
    @discardableResult
    func createList(named name: String = "New List") -> String? {
        guard let store = store, let created = try? store.createList(name: name) else { return nil }
        reloadLists()
        setActiveList(created.id)
        renamingListID = created.id
        return created.id
    }

    func renameList(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store = store, !trimmed.isEmpty else { return }
        try? store.renameList(id: id, name: trimmed)
        reloadLists()
    }

    func deleteList(_ id: String) {
        guard let store = store else { return }
        try? store.deleteList(id: id)
        if activeListID == id { activeListID = nil }
        reloadLists()
    }

    func addCard(_ cardID: String, toList listID: String) {
        guard let store = store else { return }
        try? store.addCard(cardID: cardID, toList: listID)
        reloadLists()
    }

    /// Adds a card to the current (active) list, if one exists.
    func addToCurrentList(_ cardID: String) {
        guard let id = activeListID else { return }
        addCard(cardID, toList: id)
    }

    /// Creates a fresh list containing just this card, makes it active, and flags it for
    /// inline rename.
    func addToNewList(_ cardID: String) {
        guard let id = createList() else { return }
        addCard(cardID, toList: id)
    }

    func removeCard(_ cardID: String, fromList listID: String) {
        guard let store = store else { return }
        try? store.removeCard(cardID: cardID, fromList: listID)
        reloadLists()
    }

    /// Commits a drag-reorder of the active list's cards.
    func moveCard(in listID: String, fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let store = store else { return }
        var ordered = activeListCards
        ordered.move(fromOffsets: source, toOffset: destination)
        activeListCards = ordered   // optimistic UI update
        try? store.setListOrder(listID: listID, orderedCardIDs: ordered.map(\.id))
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

    // MARK: - Artwork / game modes

    /// Refreshes the published artwork count and art-cache size.
    func refreshArtworkState() {
        artworkCount = (try? store?.artworkCount()) ?? 0
        let bytes = (try? ImageCache.size(at: Paths.artDir)) ?? 0
        artCacheSizeFormatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// True once artwork metadata has been ingested and the games can run.
    var hasArtwork: Bool { artworkCount > 0 }

    /// All artworks for building a game (loaded fresh; ~48k tiny rows).
    func loadArtworks() -> [Artwork] {
        (try? store?.loadArtworks()) ?? []
    }

    /// Ingests `unique_artwork` metadata (optionally all art_crops for offline) via the
    /// fetcher, surfacing progress through `refreshState` like the other fetch flows.
    func startArtworkIngest(downloadAll: Bool = false) {
        guard case .idle = refreshState, !backgroundSyncing else { return }
        refreshState = .running(phase: "artwork", done: 0, total: 0)
        Task { [weak self] in
            await self?.fetcher.run(mode: downloadAll ? .downloadAllArt : .ingestArtwork) { event in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch event.phase {
                    case "done":
                        self.refreshState = .idle
                        self.refreshArtworkState()
                    case "error":
                        self.refreshState = .error(event.message ?? "unknown error")
                    case "exit":
                        if case .running = self.refreshState { self.refreshState = .idle }
                        self.refreshArtworkState()
                    default:
                        self.refreshState = .running(phase: event.phase,
                                                     done: event.done ?? 0,
                                                     total: event.total ?? 0)
                    }
                }
            }
        }
    }

    /// Returns bytes freed from the per-round art cache. Refreshes the published size.
    @discardableResult
    func clearArtCache() -> Int64 {
        let freed = (try? ImageCache.clear(at: Paths.artDir)) ?? 0
        refreshArtworkState()
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
            let ingested = (try? self.store?.meta("bulk_updated_at")) ?? nil
            // Newer bulk → silently ingest card text so search stays current. The dot
            // is decided afterward from the actual new-card count.
            if UpdateChecker.isNewerThanIngested(remote: remote, ingested: ingested) {
                self.runSilentIngest(stamp: remote)
            }
        }
    }

    /// Runs `mtg-fetcher --no-images` in the background (no visible progress). On
    /// completion, if brand-new cards were added and `stamp` isn't dismissed, lights
    /// the dot/notification by setting `newCardsPendingImages`.
    private func runSilentIngest(stamp: String) {
        guard !backgroundSyncing else { return }
        // Don't run two fetchers against the DB at once; a manual refresh wins.
        if case .running = refreshState { return }
        backgroundSyncing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.fetcher.run(mode: .ingestOnly) { event in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch event.phase {
                    case "done":
                        self.refreshDBState()
                        let dismissed = UserDefaults.standard.string(forKey: UpdateKeys.dismissedStamp)
                        let suppressed: Bool = {
                            guard let dismissed, let d = UpdateChecker.parse(dismissed),
                                  let r = UpdateChecker.parse(stamp) else { return false }
                            return d >= r
                        }()
                        if let added = event.newCards, added > 0, !suppressed {
                            self.availableUpdateStamp = stamp
                            self.newCardsPendingImages = added
                        }
                    case "error":
                        break // leave state unchanged; next check retries
                    default:
                        break
                    }
                }
            }
            self.backgroundSyncing = false
        }
    }

    /// Downloads images for cards already ingested (user-initiated from the dot/menu/
    /// Settings). Reuses the on-disk bulk JSON; only missing images are fetched.
    /// Shows progress via `refreshState`.
    func startImageDownload() {
        guard case .idle = refreshState, !backgroundSyncing else { return }
        refreshState = .running(phase: "images", done: 0, total: 0)
        Task { [weak self] in
            await self?.fetcher.run(mode: .imagesOnly) { event in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch event.phase {
                    case "done":
                        self.refreshState = .idle
                        self.refreshDBState()
                        self.newCardsPendingImages = 0
                    case "error":
                        self.refreshState = .error(event.message ?? "unknown error")
                    case "exit":
                        if case .running = self.refreshState { self.refreshState = .idle }
                    default:
                        self.refreshState = .running(phase: event.phase,
                                                     done: event.done ?? 0,
                                                     total: event.total ?? 0)
                    }
                }
            }
        }
    }

    /// User dismissed the prompt — suppress it until a strictly newer stamp appears.
    func dismissUpdate() {
        if let stamp = availableUpdateStamp {
            UserDefaults.standard.set(stamp, forKey: UpdateKeys.dismissedStamp)
        }
        newCardsPendingImages = 0
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
        guard case .idle = refreshState, !backgroundSyncing else { return }
        refreshState = .running(phase: "starting", done: 0, total: 0)
        Task { [weak self] in
            await self?.fetcher.run(mode: skipImages ? .ingestPrintings : .full) { event in
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
            newCardsPendingImages = 0
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
