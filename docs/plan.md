# MTG Spotlight — Local-First Mac Card Lookup

## Context

You want a Spotlight-style Mac app for looking up Magic: The Gathering cards. Press a global hotkey, type a partial name, see a ranked list of matches with a large preview (image + full text) of the highlighted card, all served locally for sub-millisecond response. Card data and images are fetched once (and refreshed weekly) from [Scryfall](https://scryfall.com/docs/api) — the community-standard MTG API, which publishes free daily bulk JSON dumps and a free image CDN — so no scraping is needed.

The build is split into two executables in one Xcode project: a CLI fetcher (the "separate scrape/cache flow") that owns data ingestion, and a menu-bar SwiftUI app that owns the UI. They communicate only through a shared SQLite database on disk.

## Decisions locked in (from brainstorming)

| Decision | Choice |
|---|---|
| Tech stack | Swift + SwiftUI native Mac app |
| Data source | Scryfall `oracle-cards` bulk JSON (~25k unique cards) |
| Image strategy | Pre-download all images upfront (~3–5 GB, `normal` size) |
| Image download timing | Prompted on first launch (never silent); progress visible in both Settings and the search panel |
| Card scope | Unique cards only (one entry per name) |
| Global hotkey | User-configurable; default ⌥⌘M |
| Search fields | Name only, fuzzy |
| Layout | Spotlight-style: list on left, large image + text on right |
| Enter key | User-configurable in Settings — "Copy name to clipboard" OR "Open Scryfall page" |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│              ~/Library/Application Support/                 │
│                   MTGSpotlight/                             │
│                                                             │
│   cards.sqlite   ◄────────────┐    images/<uuid>.jpg        │
│        ▲                       │           ▲                │
│        │ read                  │ write     │ read           │
│        │                       │           │                │
│  ┌─────┴────────┐       ┌──────┴───────┐   │                │
│  │ MTGSpotlight │ ───▶  │  mtg-fetcher │───┘                │
│  │    .app      │spawn  │   (CLI)      │                    │
│  │ (menu bar)   │       │ scryfall API │                    │
│  └──────────────┘       └──────────────┘                    │
│        ▲                                                    │
│        │ ⌥⌘M                                                │
└────────┼────────────────────────────────────────────────────┘
        user
```

The app target spawns the fetcher as a subprocess (via `Process`) for refreshes and reports progress back over stdout. A LaunchAgent plist (optional, configurable in Settings) runs the fetcher weekly in the background.

### Component breakdown

**1. `mtg-fetcher` — CLI executable**
- Downloads `oracle-cards` bulk JSON from Scryfall's bulk-data endpoint.
- Upserts rows into SQLite. Diffs against previous snapshot; re-runs are cheap.
- Downloads `normal` PNGs into `images/<uuid>.jpg` with concurrency cap 8. Resumable — skips files already on disk.
- Emits structured progress to stdout (e.g. `{"phase":"images","done":1234,"total":25000}`) so the app can stream it into the UI.
- Logs to `~/Library/Logs/MTGSpotlight/fetcher.log`.
- Invoked: (a) by the app when DB is empty AND user confirms first-run prompt, (b) by LaunchAgent weekly, (c) manually from the menu bar "Refresh database…" item.

**2. SQLite database — `cards.sqlite`**
- Single `cards` table with the columns needed for display and ranking: `id` (Scryfall UUID, PK), `name`, `name_lower`, `mana_cost`, `type_line`, `oracle_text`, `power`, `toughness`, `colors` (JSON), `image_path`, `scryfall_uri`.
- Index on `name_lower` (not strictly needed since search runs in-memory, but keeps ad-hoc queries fast).
- A `meta` key-value table for last-refresh timestamp, fetcher version, etc.
- No FTS5 — overkill for name-only fuzzy, and in-memory ranking is faster.

**3. In-memory search engine — `SearchEngine.swift`**
- On app launch, load all `(id, name, name_lower)` triples into a flat `[Card.Mini]` array (~25k × ~80 bytes ≈ 2 MB).
- Hand-rolled scorer combining: exact prefix match (highest weight) → case-insensitive substring → subsequence/initials match (e.g. `"ljt"` → `"Lightning Jolt Token"`) → normalized by length. Return top 20.
- Target: <1 ms per keystroke. No async, no debouncing.
- Full card detail rows fetched from SQLite only when a row is highlighted (lazy, cached by `NSCache`).

**4. `MTGSpotlight.app` — menu bar SwiftUI app**
- `LSUIElement = YES` in Info.plist → no Dock icon.
- `NSStatusItem` with menu items: "Open search" (shows hotkey), "Refresh database…", "Settings…", "Quit".
- Global hotkey via the [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) Swift package (MIT, ships its own rebinder UI for Settings).
- Hotkey toggles a borderless `NSPanel` (`PanelController.swift`):
  - `.floating` level, `.nonactivatingPanel` style
  - `NSVisualEffectView` background, `.hudWindow` material → Spotlight blur/vibrancy
  - Centered on the active screen, ~720×420
  - Auto-closes on Esc or focus loss
- SwiftUI tree inside the panel:
  - `SearchField` (autofocus) → `HStack { ResultList; CardPreview }`
  - `ResultList`: rows with thumbnail + name, ↑↓ keyboard nav, scroll-into-view on selection
  - `CardPreview`: `Image(nsImage:)` from local disk + formatted oracle text section (mana cost rendered with symbol substitution, type line, P/T, oracle text)
  - Empty state when DB is unpopulated: "No card database yet. [Download now (~4 GB)]" button → kicks off fetcher and shows progress bar inside the panel itself.
  - Progress UI also shown in the panel during any in-progress refresh (not just first run).
- Enter key dispatches to user's Settings preference: copy name OR open Scryfall page in default browser.

**5. Settings window** (standard SwiftUI Settings scene)
- Hotkey rebinder (from `KeyboardShortcuts` package)
- Enter-key behavior picker: "Copy name to clipboard" / "Open Scryfall page"
- "Refresh database now" button with live progress
- "Run weekly auto-refresh" toggle → installs/removes the LaunchAgent plist
- Last-refresh timestamp + total cards in DB

### Data flow on keystroke

```
user types "lightni"
  → SearchField.text → ViewModel.query (no debounce)
  → SearchEngine scores 25k names → top 20 IDs
  → ViewModel fetches full rows for visible IDs from SQLite (NSCache by id)
  → SwiftUI re-renders list
  → Highlighted row loads image from disk (NSCache by id)
```
Cold open → first paint: ~50 ms. Keystroke → results: ~1 ms.

### Project layout

```
quick-study/
├── MTGSpotlight.xcodeproj
├── Shared/                       # Swift package, used by both targets
│   ├── CardStore.swift           # SQLite reader/writer (GRDB)
│   ├── Card.swift                # model
│   └── Paths.swift               # Application Support paths
├── App/                          # MTGSpotlight.app target
│   ├── MTGSpotlightApp.swift
│   ├── PanelController.swift
│   ├── SearchEngine.swift
│   ├── FetcherProcess.swift      # spawns/monitors mtg-fetcher
│   ├── Views/
│   │   ├── SearchPanel.swift
│   │   ├── ResultList.swift
│   │   ├── CardPreview.swift
│   │   └── DownloadPromptView.swift
│   └── SettingsView.swift
├── Fetcher/                      # mtg-fetcher CLI target
│   ├── main.swift
│   ├── ScryfallClient.swift
│   ├── ImageDownloader.swift
│   └── ProgressEmitter.swift     # structured stdout
├── Resources/
│   └── com.user.MTGSpotlight.refresh.plist  # LaunchAgent template
└── docs/
    └── architecture.md           # written at end of build for subtask decomposition
```

### Dependencies

- [`GRDB.swift`](https://github.com/groue/GRDB.swift) — SQLite wrapper.
- [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) — global hotkey + rebinder UI.
- No other third-party deps.

## Implementation phases (for later subtask split)

1. **Bootstrap project**: Xcode project, two targets, shared Swift package, `LSUIElement` config, menu bar skeleton.
2. **`mtg-fetcher` CLI**: Scryfall bulk download → SQLite ingest → image download with concurrency cap and resumability → structured progress on stdout.
3. **CardStore / DB schema**: GRDB setup, schema migrations, basic read paths.
4. **SearchEngine**: in-memory load + fuzzy ranking + unit tests on golden cases.
5. **PanelController + SearchPanel UI**: borderless `NSPanel`, blur background, autofocus, ↑↓/Esc/Enter handling.
6. **ResultList + CardPreview views**: SwiftUI list, image loading from disk, mana-symbol substitution.
7. **First-run prompt + progress UI**: `DownloadPromptView`, `FetcherProcess` spawn/monitor, live progress in panel.
8. **Settings window**: hotkey rebinder, Enter-key picker, refresh button, weekly LaunchAgent toggle.
9. **Polish**: app icon, status bar icon, About window, error states (offline, Scryfall down, disk full).
10. **Write `docs/architecture.md`** capturing the final shipped architecture for future subtasking.

## Critical files to create

- `Shared/CardStore.swift` — DB API (GRDB)
- `Shared/Card.swift` — model
- `Fetcher/main.swift` + `Fetcher/ScryfallClient.swift` + `Fetcher/ImageDownloader.swift` — ingest pipeline
- `App/SearchEngine.swift` — ranking logic (most performance-sensitive)
- `App/PanelController.swift` — NSPanel setup (most platform-specific)
- `App/Views/SearchPanel.swift` — top-level UI
- `App/FetcherProcess.swift` — subprocess + stdout streaming

## Verification

End-to-end checks once built:

1. **Fresh install path** — delete `~/Library/Application Support/MTGSpotlight/`, launch app, confirm download prompt appears in the panel; confirm progress streams; confirm completion enables search.
2. **Hotkey** — press ⌥⌘M from various apps (Chrome, Terminal, full-screen Xcode); panel must appear within ~100 ms; Esc dismisses.
3. **Search latency** — type "lig" → "lightni" → "lightning bolt"; results must update on every keystroke with no perceptible lag (eyeball test; instrument `SearchEngine.score` with `signpost` if doubt).
4. **Fuzzy correctness** — golden cases in `SearchEngineTests`:
   - `"lightni"` → top result is `"Lightning Bolt"`
   - `"ljt"` (initials) → returns at least one lightning card
   - `"BOLT"` (uppercase) → top result is `"Lightning Bolt"`
5. **Image preview** — arrow-key through 10 cards; image and text update each time; no flicker.
6. **Enter behavior** — toggle in Settings, verify both modes (clipboard / browser open).
7. **Refresh** — trigger manual refresh from menu bar; progress visible in both Settings and the panel; row count in `cards` table changes if Scryfall has updated.
8. **Weekly LaunchAgent** — enable toggle, inspect `launchctl list | grep MTGSpotlight`; disable and confirm removal.
9. **No Dock icon, no Cmd-Tab entry** — `LSUIElement` correctly applied.
10. **Architecture doc written** to `docs/architecture.md` and committed.
