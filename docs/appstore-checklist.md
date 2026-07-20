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

## 2. Apple Developer portal setup — web browser path

Everything happens at
[developer.apple.com/account/resources](https://developer.apple.com/account/resources)
(Certificates, Identifiers & Profiles). One local prerequisite: a Certificate
Signing Request, because the web portal can't generate the private key for you.

### 2a. Create a CSR in Keychain Access (once — reused for both certificates)

1. Open **Keychain Access** (Spotlight → "Keychain Access").
2. Menu bar: *Keychain Access → Certificate Assistant → Request a Certificate
   From a Certificate Authority…*
3. Fill in: **User Email Address** = your Apple ID email; **Common Name** = your
   name; **CA Email** = leave empty; select **"Saved to disk"**.
4. Save `CertificateSigningRequest.certSigningRequest` to `~/Downloads`.

This silently creates the matching private key in your login keychain — the
downloaded certificates only become usable identities on this Mac because that
key is here. Don't delete it, and export a backup later if you switch machines.

### 2b. Certificates (sidebar: *Certificates* → blue **+**)

Create **two**, same CSR for both:

1. **Apple Distribution** (under "Software") — signs the `.app`.
   Continue → upload the CSR → Continue → **Download** `distribution.cer` →
   double-click it to install into the keychain.
2. **+** again → **Mac Installer Distribution** — signs the `.pkg`.
   Same CSR → Download `macinstaller.cer` → double-click to install.

Verify both landed as usable identities:

```sh
security find-identity -v | grep -E "Apple Distribution|Installer"
```

Both lines must appear; if a cert shows in Keychain Access but not here, the
private key is missing (wrong Mac / wrong keychain — redo the CSR on this Mac).

### 2c. App ID (sidebar: *Identifiers* → **+**)

1. Select **App IDs** → Continue → type **App** → Continue.
2. **Description**: `QuickStudy` (portal-only label).
3. **Bundle ID**: select **Explicit**, enter `com.abbabon.quickstudy` — must
   match `Resources/Info.plist` exactly.
4. **Capabilities**: tick nothing (App Sandbox isn't a portal capability; the
   entitlements files handle it). Continue → **Register**.

### 2d. Provisioning profile (sidebar: *Profiles* → **+**)

1. Under **Distribution**, select **Mac App Store Connect** (older portal UI
   calls it "Mac App Store") → Continue.
2. If asked for profile type, pick **Mac** (not Mac Catalyst).
3. **App ID**: `QuickStudy (com.abbabon.quickstudy)` → Continue.
4. **Certificate**: select the Apple Distribution cert from 2b → Continue.
5. **Provisioning Profile Name**: `QuickStudy Mac App Store` → **Generate** →
   **Download**; it saves as something like `QuickStudy_Mac_App_Store.provisionprofile`.

Sanity-check the profile matches the bundle ID and your team:

```sh
security cms -D -i ~/Downloads/QuickStudy_Mac_App_Store.provisionprofile \
  | grep -E -A1 "TeamIdentifier|application-identifier"
```

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
