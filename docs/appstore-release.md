# Unattended Mac App Store release

Goal: an agent on this Mac ships a release (upload, wait, attach, fill required fields, submit)
without a human clicking, and without the agent ever holding a secret.

App ID `6792768370`, bundle `com.abbabon.quickstudy`, team `935DPR326H`.
Status: upload is scripted now (`scripts/upload-appstore.sh`). Steps 3-6 below are researched but not
built; the submit script is the next step. Anything marked **unverified** was not tested against Apple.

## Key findings

- **Upload + processing wait** work with an app-specific password kept in the login keychain
  (`altool -p @keychain:ITEM`). The agent only sees the item name.
- **Everything after upload** (attach build, review details, content rights, submit) is the App Store
  Connect REST API. It needs a JWT signed with a `.p8` API key. The altool keychain password does not
  work there (altool-only credential; from Apple's docs, not tested).
- **App Privacy ("data usage") is not in the public API.** Fastlane's `upload_app_privacy_details_to_app_store`
  uses Apple ID web-session auth and its docs say the API key "cannot be used at this time". Treat it as
  one-time human setup. I found no `appDataUsages` endpoint in Apple's public index (absence not proof).
- So a full unattended submit is possible, but **only if a reviewed script holds the `.p8`** and the agent runs
  that script, never touching the key.

## One-time human setup

1. Upload credential. Create an app-specific password at account.apple.com, then in Terminal (you type it):
   ```sh
   xcrun altool --store-password-in-keychain-item QS_ASC -u <apple-id> -p <app-specific-password>
   ```
   First upload may show a keychain prompt for altool: click "Always Allow" once. The agent must run in
   your logged-in GUI session with the keychain unlocked. **Unverified:** that altool then finds the item by name
   alone; if it complains, the script prints the setup command.
   If your account has several providers, `xcrun altool --list-providers` and export `QS_PROVIDER_ID`.
2. Submit credential (only for the future submit script). App Store Connect > Users and Access >
   Integrations > App Store Connect API: create a key with role **App Manager** (least that can submit; **unverified**
   whether Developer suffices for review submission). Download `AuthKey_<KEYID>.p8` once, move it to
   `~/.appstoreconnect/private_keys/` with `chmod 600`, and note the Key ID and Issuer ID. Do not put it in the repo.
3. In App Store Connect, once per app, in the web UI:
   - **App Privacy** questionnaire and privacy policy URL (not API-settable, see above).
   - Age rating, category, pricing and availability, screenshots, description, keywords, support URL.
   - Content rights declaration, review contact, and sign-in/notes can be set by the API, but doing them
     once by hand is simpler. The submit script can set them idempotently later.
4. Keep export compliance out of the loop: set `ITSAppUsesNonExemptEncryption` in `Resources/Info.plist`
   (`false` if only exempt encryption), otherwise each build waits on a compliance question. **Unverified** for this app.
5. Create the version record (e.g. 0.8.0) in App Store Connect before the first run; the API can also
   create it (`POST /v1/appStoreVersions`) but metadata is cleaner by hand the first time.

## Per-release flow (agent)

1. Bump version/build in `Resources/Info.plist`; build on a branch.
2. `./scripts/build-appstore.sh` produces `dist-appstore/QuickStudy.pkg` (needs `QS_APP_IDENTITY`,
   `QS_INSTALLER_IDENTITY`, `QS_PROVISION_PROFILE`).
3. `./scripts/upload-appstore.sh` reads bundle id, version and build from Info.plist, runs `altool --validate-app`,
   then `--upload-package ... --wait`. Do not run it twice for the same build number (Apple rejects duplicates).
4. Wait for processing. With keychain auth: `xcrun altool --build-status --apple-id 6792768370 --bundle-id
   com.abbabon.quickstudy --bundle-version <build> --bundle-short-version-string <ver> -p @keychain:QS_ASC --wait`.
   With the API: `GET /v1/builds?filter[app]=6792768370&filter[version]=<build>&filter[preReleaseVersion.version]=<ver>`
   until `attributes.processingState` is `VALID` (other values: `PROCESSING`, `FAILED`, `INVALID`).
5. *(API, planned `scripts/submit-appstore.sh`)* Attach the build:
   `PATCH /v1/appStoreVersions/{versionId}/relationships/build` with `{"data":{"type":"builds","id":"<buildId>"}}`
   (shape confirmed in Apple's docs). Find `versionId` via `GET /v1/apps/6792768370/appStoreVersions?filter[versionString]=<ver>`.
6. *(API)* Review details, if not already set: `POST /v1/appStoreReviewDetails` (or `PATCH` an existing one) with
   `contactFirstName`, `contactLastName`, `contactPhone`, `contactEmail`, `demoAccountRequired`, `notes` and the
   `appStoreVersion` relationship. Attribute names are from fastlane's model; Apple's page for the endpoint
   is a stub. Content rights: `PATCH /v1/apps/6792768370` with
   `attributes.contentRightsDeclaration` = `DOES_NOT_USE_THIRD_PARTY_CONTENT` or `USES_THIRD_PARTY_CONTENT`
   (value shown in Apple's example).
7. *(API)* Submit: `POST /v1/reviewSubmissions` (relationship `app`; platform now optional) ->
   `POST /v1/reviewSubmissionItems` (relationships `reviewSubmission` + `appStoreVersion`) ->
   `PATCH /v1/reviewSubmissions/{id}` with `attributes.submitted=true` (as fastlane does). Request bodies
   other than the build PATCH come from fastlane source, not Apple prose: **unverified** against the live API.
   Review the failure response: missing metadata (e.g. no privacy answers) shows up here.

Apple's endpoint pages are thin; the exact bodies should be checked with a real call on the first run.

## Safest pattern for the `.p8`

Only a reviewed script touches the key; the agent can run it but not read or edit it.

- `scripts/submit-appstore.sh` (future) reads the key path and IDs from env/`~/.appstoreconnect/`, mints a short-lived
  JWT (ES256, `aud: appstoreconnect-v1`, `exp` under 20 min) in-process, never prints it, calls the API.
  Prefer an allow-listed script that keeps the key's path hardcoded.
- Keep the key readable only by you, outside the repo and outside the agent's working directories.
- Deny reads of key locations and writes to the script, so the agent cannot extract the key or change what
  the script does. An allow rule cannot override a deny rule, so deny only the key paths.
- Weakness: if the agent can edit the script it can make the script print the key. Deny edits to
  `scripts/submit-appstore.sh` and `scripts/upload-appstore.sh`, or change them only in a commit you review.
  Also in auto mode, a classifier may still object to key handling.

## Claude Code permission rule

Add to `.claude/settings.json` (not done here; rules from the Claude Code permissions docs):

```json
{
  "permissions": {
    "allow": [
      "Bash(./scripts/build-appstore.sh)",
      "Bash(./scripts/upload-appstore.sh)",
      "Bash(./scripts/upload-appstore.sh *)",
      "Bash(./scripts/submit-appstore.sh *)"
    ],
    "deny": [
      "Read(~/.appstoreconnect/**)",
      "Read(~/.private_keys/**)",
      "Read(~/private_keys/**)",
      "Read(**/AuthKey_*.p8)",
      "Edit(scripts/upload-appstore.sh)",
      "Edit(scripts/submit-appstore.sh)"
    ]
  }
}
```

Syntax notes (docs): a trailing ` *` after a space also matches the bare command, but the rule text must match
what the agent types, so `./scripts/x.sh` and `scripts/x.sh` are different. Compound commands (`&&`, `;`, `|`) need every
part allowed. Bash deny rules are not a security boundary (`bash -c 'cat key'`, `/bin/cat key` bypass `Bash(cat *)`), so
file-read denies only cover the Read tool; the real protection is that the key is outside the agent's reach (file
mode, separate account, or a keychain-backed signer). **Unverified:** whether Bash `cat` of a `Read`-denied path is blocked.

## What still needs a human, and why

- Storing the app-specific password and downloading the `.p8` (secrets must be typed/downloaded by you).
- App Privacy answers (private API only) and first-time store metadata, age rating, pricing, screenshots.
- Anything Apple adds that blocks submission (new agreements to accept, account in bad standing, rejection replies).
- Choosing the release: the agent can submit, but you decide whether it should.

## Gotchas

- Apple error **91109**: `com.apple.quarantine` on the provisioning profile copied from `~/Downloads`. Fixed by
  `xattr -cr "$APP"` in `build-appstore.sh`. Run it before signing, not after.
- **Transporter** keeps a stale queue entry from an earlier build; remove it so you do not retry the old pkg.
- Each upload needs a unique, higher build number (`CFBundleVersion`).
- `build-appstore.sh` has an older `QS_UPLOAD=1` path that puts the password in env/args. Prefer `upload-appstore.sh`.
- Forum reports of altool auth timeouts on macOS pkgs; fallback is the `buildUploads` API (needs the `.p8`).
- altool here is version 27.0.5 (2.1); `--upload-package` takes `-t macos`, `--apple-id`, `--bundle-id`,
  `--bundle-version`, `--bundle-short-version-string` (checked with `man altool`).

## Sources

- Upload research: `appstore-upload-options.md` (session scratchpad), `man altool`, `xcrun altool --help`
- [Attach build to version](https://developer.apple.com/documentation/appstoreconnectapi/patch-v1-appstoreversions-_id_-relationships-build.md)
- [Modify an app (contentRightsDeclaration example)](https://developer.apple.com/documentation/appstoreconnectapi/patch-v1-apps-_id_.md)
- [Create a review submission](https://developer.apple.com/documentation/appstoreconnectapi/post-v1-reviewsubmissions.md),
  [review submission item](https://developer.apple.com/documentation/appstoreconnectapi/post-v1-reviewsubmissionitems.md),
  [app store review detail](https://developer.apple.com/documentation/appstoreconnectapi/post-v1-appstorereviewdetails.md) (stubs)
- fastlane spaceship: [review_submission.rb](https://github.com/fastlane/fastlane/blob/master/spaceship/lib/spaceship/connect_api/models/review_submission.rb),
  [build.rb](https://github.com/fastlane/fastlane/blob/master/spaceship/lib/spaceship/connect_api/models/build.rb),
  [app_store_review_detail.rb](https://github.com/fastlane/fastlane/blob/master/spaceship/lib/spaceship/connect_api/models/app_store_review_detail.rb)
- [fastlane: uploading app privacy details](https://docs.fastlane.tools/uploading-app-privacy-details/)
- [Claude Code permissions](https://code.claude.com/docs/en/permissions)
