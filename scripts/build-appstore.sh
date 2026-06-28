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

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="QuickStudy"
DIST="$ROOT/dist-appstore"
APP="$DIST/$APP_NAME.app"
PKG="$DIST/$APP_NAME.pkg"
CONFIG="release"

require() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        echo "ERROR: \$$name is not set." >&2
        echo "       See the header of this script for the required signing identities" >&2
        echo "       and provisioning profile (needs an Apple Developer Program account)." >&2
        exit 1
    fi
}

require QS_APP_IDENTITY
require QS_INSTALLER_IDENTITY
require QS_PROVISION_PROFILE

if [[ ! -f "$QS_PROVISION_PROFILE" ]]; then
    echo "ERROR: provisioning profile not found at $QS_PROVISION_PROFILE" >&2
    exit 1
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

echo "==> Embedding provisioning profile"
cp "$QS_PROVISION_PROFILE" "$APP/Contents/embedded.provisionprofile"

# Sign inside-out: the bundled helper first (with inherit entitlements), then the app.
echo "==> Signing helper (mtg-fetcher)"
codesign --force --options runtime \
    --entitlements "$ROOT/Resources/mtg-fetcher.entitlements" \
    --sign "$QS_APP_IDENTITY" \
    "$APP/Contents/MacOS/mtg-fetcher"

echo "==> Signing app (QuickStudy)"
codesign --force --options runtime \
    --entitlements "$ROOT/Resources/QuickStudy.entitlements" \
    --sign "$QS_APP_IDENTITY" \
    "$APP"

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP"

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
    echo "    To upload: set QS_UPLOAD=1 (plus QS_APPLE_ID / QS_APP_PASSWORD),"
    echo "    or drop the pkg into Apple's Transporter app."
fi
