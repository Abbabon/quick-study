# App Store submission checklist

Step-by-step from a paid Apple Developer account to a live Mac App Store listing.
Background and design notes live in [appstore.md](appstore.md). Work happens in the
`feat/appstore` worktree (`../quick-study-appstore`).

## 1. Test the sandboxed build locally

```sh
./scripts/build-appstore.sh --adhoc
open dist-appstore/QuickStudy.app
```

Confirm:

- **Refresh Database** downloads and writes into
  `~/Library/Containers/com.abbabon.quickstudy/Data/Library/Application Support/QuickStudy/`
  (`cards.sqlite` + `images/` appear there).
- Search returns results; the global hotkey opens the panel; the login-item toggle works.
- Console.app shows no sandbox `deny` messages.

The sandboxed build starts with an **empty database** — the container is separate
from direct-install data under the real `~/Library`. That's expected.

## 2. Apple Developer portal setup ([developer.apple.com/account](https://developer.apple.com/account))

1. **Certificates** — easiest via Xcode: *Settings → Accounts → your Apple ID →
   Manage Certificates → +* and create both **Apple Distribution** and
   **Mac Installer Distribution**. (Or via the web portal with a CSR from Keychain Access.)
2. **Identifier** — *Identifiers → + → App IDs → App*, bundle ID **explicit**
   `com.abbabon.quickstudy`, no extra capabilities needed.
3. **Provisioning profile** — *Profiles → + → Distribution → Mac App Store Connect*,
   select the App ID and the Apple Distribution cert, download as
   `QuickStudy.provisionprofile`.

## 3. App Store Connect record ([appstoreconnect.apple.com](https://appstoreconnect.apple.com))

*My Apps → + → New App*: platform macOS, name "Quick Study", bundle ID
`com.abbabon.quickstudy`, any SKU (e.g. `quickstudy`). Then:

- **Pricing**: Free.
- **Privacy policy URL** — required. The app collects nothing, so a one-paragraph
  page (GitHub Pages on the repo works fine) is enough; set the privacy labels to
  "Data Not Collected".
- **Screenshots** — macOS requires one of: 1280×800, 1440×900, 2560×1600, or
  2880×1800. Capture the Spotlight-style panel with results showing.
- **App Review notes** — the most likely rejection point (Guideline 5.2,
  intellectual property). Suggested text:

  > Quick Study is unofficial Fan Content permitted under the Wizards of the Coast
  > Fan Content Policy. Card data and images are fetched by the user from Scryfall's
  > public API and cached locally; no WotC assets ship inside the binary.

## 4. Build, package, upload

```sh
cd ../quick-study-appstore
security find-identity -v | grep -E "Apple Distribution|Installer"   # exact identity names

QS_APP_IDENTITY="Apple Distribution: Your Name (TEAMID)" \
QS_INSTALLER_IDENTITY="3rd Party Mac Developer Installer: Your Name (TEAMID)" \
QS_PROVISION_PROFILE=~/Downloads/QuickStudy.provisionprofile \
./scripts/build-appstore.sh
```

Upload `dist-appstore/QuickStudy.pkg` with Apple's **Transporter** app (free on the
Mac App Store — sign in, drag the pkg, Deliver). The script's `QS_UPLOAD=1` altool
path exists but altool is deprecated; Transporter is the reliable route.

## 5. Submit

In App Store Connect, wait for the build to finish processing (~15–30 min; watch for
an email if it's rejected during processing), attach it to the version, and
*Submit for Review*. Mac review typically takes 1–3 days.

## Every future upload

- Bump `CFBundleVersion` in `Resources/Info.plist` — App Store Connect rejects
  duplicate build numbers. (`CFBundleShortVersionString` only changes per release.)
