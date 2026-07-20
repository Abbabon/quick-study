#!/bin/bash
# Build a sandboxed Mac App Store build of QuickStudy: assemble the .app, sign it
# (inside-out) with a distribution identity + entitlements, embed the provisioning
# profile, wrap it in a signed installer .pkg, and (optionally) upload to App Store
# Connect.
#
# This is the App Store track. The direct/Homebrew track is unchanged — see
# build-app.sh / release.sh. The two differ in:
#   - this build defines APPSTORE (compiles out the self-updater), and
#   - it uses real distribution signing + the sandbox entitlements instead of ad-hoc.
#
# Requires an Apple Developer Program membership. Provide identities + profile via env:
#   QS_APP_IDENTITY        e.g. "Apple Distribution: Your Name (TEAMID)"
#                          (or "3rd Party Mac Developer Application: Your Name (TEAMID)")
#   QS_INSTALLER_IDENTITY  e.g. "3rd Party Mac Developer Installer: Your Name (TEAMID)"
#   QS_PROVISION_PROFILE   path to the Mac App Store provisioning profile for
#                          com.abbabon.quickstudy (a .provisionprofile file)
# Optional:
#   QS_UPLOAD=1            after building, upload the pkg with `xcrun altool`
#   QS_APPLE_ID / QS_APP_PASSWORD   credentials for the upload (app-specific password)
#
# Usage: ./scripts/build-appstore.sh
#        ./scripts/build-appstore.sh --adhoc
#
# --adhoc builds the same sandboxed APPSTORE binary but signs it ad-hoc (no
# identities, profile, or pkg needed) so the sandbox can be exercised locally
# before submitting — see docs/appstore.md "Sandbox runtime verification".

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="QuickStudy"
BUNDLE_ID="com.abbabon.quickstudy"
DIST="$ROOT/dist-appstore"
APP="$DIST/$APP_NAME.app"
PKG="$DIST/$APP_NAME.pkg"
CONFIG="release"
ADHOC=0
[[ "${1:-}" == "--adhoc" ]] && ADHOC=1

require() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        echo "ERROR: \$$name is not set." >&2
        echo "       See the header of this script for the required signing identities" >&2
        echo "       and provisioning profile (needs an Apple Developer Program account)." >&2
        exit 1
    fi
}

if [[ "$ADHOC" == "0" ]]; then
    require QS_APP_IDENTITY
    require QS_INSTALLER_IDENTITY
    require QS_PROVISION_PROFILE

    if [[ ! -f "$QS_PROVISION_PROFILE" ]]; then
        echo "ERROR: provisioning profile not found at $QS_PROVISION_PROFILE" >&2
        exit 1
    fi
fi

echo "==> Building Swift package ($CONFIG, -DAPPSTORE)…"
cd "$ROOT"
swift build -c "$CONFIG" -Xswiftc -DAPPSTORE

BIN_DIR="$(swift build -c "$CONFIG" -Xswiftc -DAPPSTORE --show-bin-path)"

echo "==> Assembling app bundle at $APP"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN_DIR/QuickStudy"   "$APP/Contents/MacOS/QuickStudy"
cp "$BIN_DIR/mtg-fetcher"  "$APP/Contents/MacOS/mtg-fetcher"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "    (note: Resources/AppIcon.icns not found — run scripts/generate-icon.py)"
fi

APP_ENTITLEMENTS="$ROOT/Resources/QuickStudy.entitlements"

if [[ "$ADHOC" == "0" ]]; then
    echo "==> Embedding provisioning profile"
    cp "$QS_PROVISION_PROFILE" "$APP/Contents/embedded.provisionprofile"

    # App Store validation requires the app signature to carry the
    # com.apple.application-identifier / com.apple.developer.team-identifier
    # entitlements matching the embedded profile. Pull the team id from the
    # profile itself and merge them into the sandbox entitlements.
    TEAM_ID="$(security cms -D -i "$QS_PROVISION_PROFILE" 2>/dev/null \
        | plutil -extract TeamIdentifier.0 raw -o - -)"
    if [[ -z "$TEAM_ID" ]]; then
        echo "ERROR: could not read TeamIdentifier from $QS_PROVISION_PROFILE" >&2
        exit 1
    fi
    echo "==> Team ID from profile: $TEAM_ID"

    APP_ENTITLEMENTS="$DIST/QuickStudy-signed.entitlements"
    cp "$ROOT/Resources/QuickStudy.entitlements" "$APP_ENTITLEMENTS"
    plutil -insert "com.apple.application-identifier" \
        -string "$TEAM_ID.$BUNDLE_ID" "$APP_ENTITLEMENTS"
    plutil -insert "com.apple.developer.team-identifier" \
        -string "$TEAM_ID" "$APP_ENTITLEMENTS"

    SIGN_IDENTITY="$QS_APP_IDENTITY"
else
    SIGN_IDENTITY="-"
    echo "==> Ad-hoc mode: signing with '-' (sandbox still enforced locally)"
fi

# Sign inside-out: the bundled helper first (with inherit entitlements), then the app.
# The helper must carry ONLY app-sandbox + inherit — extra entitlements break
# sandbox inheritance — so it never gets the identifier entitlements.
echo "==> Signing helper (mtg-fetcher)"
codesign --force --options runtime \
    --entitlements "$ROOT/Resources/mtg-fetcher.entitlements" \
    --sign "$SIGN_IDENTITY" \
    "$APP/Contents/MacOS/mtg-fetcher"

echo "==> Signing app (QuickStudy)"
codesign --force --options runtime \
    --entitlements "$APP_ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP"

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP"

if [[ "$ADHOC" == "1" ]]; then
    echo "==> Done (ad-hoc sandbox build)."
    echo "    open '$APP'   # then follow docs/appstore.md sandbox verification"
    exit 0
fi

echo "==> Building installer package"
productbuild --component "$APP" /Applications \
    --sign "$QS_INSTALLER_IDENTITY" \
    "$PKG"

echo "==> Done."
echo "    $PKG"

if [[ "${QS_UPLOAD:-0}" == "1" ]]; then
    require QS_APPLE_ID
    require QS_APP_PASSWORD
    echo "==> Validating with altool…"
    xcrun altool --validate-app -f "$PKG" -t macos \
        -u "$QS_APPLE_ID" -p "$QS_APP_PASSWORD"
    echo "==> Uploading to App Store Connect…"
    xcrun altool --upload-app -f "$PKG" -t macos \
        -u "$QS_APPLE_ID" -p "$QS_APP_PASSWORD"
    echo "==> Uploaded. Finish the submission in App Store Connect."
else
    echo "    To upload: drop the pkg into Apple's Transporter app (recommended;"
    echo "    free on the Mac App Store), or set QS_UPLOAD=1 with QS_APPLE_ID /"
    echo "    QS_APP_PASSWORD to try the deprecated altool path."
fi
