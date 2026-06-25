# Build Status

All planned implementation tasks complete. See `docs/plan.md` for the spec and `docs/architecture.md` for the shipped design.

## Done

- [x] **Task 1** Scaffold Swift Package & directory layout — `Package.swift`, `.gitignore`, source tree.
- [x] **Task 2** Shared module — `Paths.swift`, `Card.swift`, `CardStore.swift` (GRDB + migrations).
- [x] **Task 3** `mtg-fetcher` CLI — `Fetcher.swift` (@main), `ScryfallClient.swift`, `ImageDownloader.swift`, `ProgressEmitter.swift`.
- [x] **Task 4** SearchEngine + tests — layered fuzzy ranker, `SearchEngineTests.swift`.
- [x] **Task 5** App — `QuickStudyApp.swift`, `PanelController.swift`, `AppModel.swift`, `FetcherProcess.swift`, four SwiftUI views, `SettingsView.swift`, `Info.plist`, LaunchAgent template.
- [x] **Task 6** Scripts + docs — `scripts/build-app.sh`, `README.md`, `docs/architecture.md`.

## How to run

```sh
./scripts/build-app.sh
open ./dist/QuickStudy.app
```

For dev iteration:

```sh
swift test                                      # unit tests
swift run mtg-fetcher --no-images               # cards only, fast
MTG_FETCHER_PATH="$(swift build --show-bin-path)/mtg-fetcher" swift run QuickStudy
```

## Open items / known caveats (good first issues)

- **First build will pull `GRDB.swift` and `KeyboardShortcuts`** from SPM — needs network.
- **Accessibility permission** is requested by `KeyboardShortcuts` on first hotkey use. Grant it under System Settings.
- **`swift build` of the app target may need `-Xswiftc -enable-experimental-feature -Xswiftc StrictConcurrency` adjustment** depending on Swift toolchain; if you hit Sendable warnings, lower strict-concurrency mode in `Package.swift`.
- **`onKeyPress`** (used in `SearchPanel.swift`) requires macOS 14. If you need to support macOS 13, replace with an `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` in `PanelController`.
- **Image rendering of mana symbols** is plain-text for now — `{R}`, `{U}` etc. appear as text. Subtask D in `architecture.md` covers replacing with images.
- **No app icon yet** — status-bar uses an SF Symbol. Subtask F.
- **Rarity / mana-value backfill** — migration v9 adds `cards.rarity` and `cards.cmc`, populated by the next normal `mtg-fetcher` ingest. Rows ingested before v9 stay NULL until a refresh, so the rarity badge is hidden and `r:`/`mv:` filters skip them. The "any printing" sense of `r:` (e.g. pauper) is only complete after a `--printings` run populates the printings table; without it, `r:` falls back to each card's single representative rarity.
- **Launch at login** is wired via `SMAppService.mainApp` (subtask G) — a "General" toggle in Settings registers/unregisters the app as a login item, surfacing in System Settings → Login Items. Off by default. See `Sources/QuickStudy/LoginItem.swift`.
