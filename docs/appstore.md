# Mac App Store distribution

QuickStudy ships on **two tracks** from one source tree:

| Track | Build | Signing | Self-update |
|-------|-------|---------|-------------|
| Direct / Homebrew | `scripts/build-app.sh`, `scripts/release.sh` | ad-hoc (local) / Developer ID (release) | yes (`AppUpdater`) |
| Mac App Store | `scripts/build-appstore.sh` | distribution cert + entitlements, sandboxed | no (App Store delivers updates) |

The only code difference is the `APPSTORE` compilation flag (`swift build -Xswiftc -DAPPSTORE`), which compiles out the self-updater. Everything else — search engine, fetcher subprocess, DB, `Paths` — is shared and unchanged.

## Why the sandbox "just works" for data

`Paths` (`Sources/Shared/Paths.swift`) uses `FileManager.urls(for: .applicationSupportDirectory…)` and `.libraryDirectory`. Under the sandbox these automatically resolve into the app's container:

```
~/Library/Containers/com.abbabon.quickstudy/Data/Library/Application Support/QuickStudy/
~/Library/Containers/com.abbabon.quickstudy/Data/Library/Logs/QuickStudy/
```

No code change is needed. (Existing direct-install users' data under the real `~/Library/...` is not migrated into the container — a fresh App Store install starts clean.)

## Entitlements

- `Resources/QuickStudy.entitlements` — `app-sandbox` + `network.client` (Scryfall bulk-data API + image/art CDN).
- `Resources/mtg-fetcher.entitlements` — `app-sandbox` + `inherit`. The bundled `mtg-fetcher` helper inherits the app's sandbox and network grant at spawn time, so it can download from Scryfall and write into the container. `FetcherProcess.resolveFetcherPath()` already finds the helper next to the main executable in `Contents/MacOS/`.

## What was compiled out for the App Store build

The self-update subsystem spawns `ditto`/`codesign`/`xattr`/`brew`/`open` — all blocked by the sandbox and forbidden/redundant on the App Store. Under `APPSTORE`:

- `AppUpdater` collapses to a stub (only `InstallKind`, which the shared `AppUpdateState` enum needs).
- `AppModel.checkForAppUpdate` / `installOrRelaunch` become no-ops → `appUpdateState` stays `.none`, so every UI reading it renders inert.
- The Settings "Updates" card and "Check for updates automatically" toggle are hidden.

## Remaining manual steps (require an Apple Developer account)

1. **Enrol** in the Apple Developer Program ($99/yr).
2. In **App Store Connect**: create the app record for bundle id `com.abbabon.quickstudy`, set the price to **Free**, fill metadata.
   - In the review notes, explain the MTG/Scryfall content: unofficial Fan Content under WotC's Fan Content Policy, card data/images from Scryfall, cached locally. This is the most likely review snag (Guideline 5.2 — Intellectual Property).
3. Generate the **distribution certificate(s)** and a **Mac App Store provisioning profile** for the bundle id.
4. Build + package + upload:
   ```sh
   QS_APP_IDENTITY="Apple Distribution: … (TEAMID)" \
   QS_INSTALLER_IDENTITY="3rd Party Mac Developer Installer: … (TEAMID)" \
   QS_PROVISION_PROFILE=/path/to/QuickStudy.provisionprofile \
   ./scripts/build-appstore.sh
   # then upload dist-appstore/QuickStudy.pkg with Apple's Transporter app
   # (or QS_UPLOAD=1 QS_APPLE_ID=… QS_APP_PASSWORD=… for the deprecated altool path).
   ```
   The script reads the Team ID out of the provisioning profile and merges
   `com.apple.application-identifier` / `com.apple.developer.team-identifier`
   into the app's signing entitlements — required for App Store validation
   when a profile is embedded.

## Sandbox runtime verification (do before submitting)

Ad-hoc signing **with** the entitlements enforces the sandbox locally, so you can test without an upload:

```sh
./scripts/build-appstore.sh --adhoc
open dist-appstore/QuickStudy.app
```

Then exercise the app and confirm:
- **Refresh Database** runs the fetcher, downloads from Scryfall, and writes into `~/Library/Containers/com.abbabon.quickstudy/Data/Library/Application Support/QuickStudy/` (`cards.sqlite` + `images/` appear there).
- Search returns results; the global hotkey opens the panel; the login-item toggle works.
- `~/Library/Containers/com.abbabon.quickstudy/Data/Library/Logs/QuickStudy/fetcher.log` and Console.app show **no** sandbox `deny` messages.
