#!/bin/bash
# Validate, then upload dist-appstore/QuickStudy.pkg to App Store Connect with altool.
# The password never appears here: altool reads it from a login-keychain item that the
# human stored once (see docs/appstore-release.md):
#   xcrun altool --store-password-in-keychain-item QS_ASC --username <apple-id> --app-password <app-specific-password>
#
# Usage: ./scripts/upload-appstore.sh [path/to/QuickStudy.pkg]
# Env:   ASC_KEYCHAIN_ITEM  keychain item name (default QS_ASC)
#        QS_APPLE_APP_ID    numeric App Store Connect app id (default 6792768370)
#        ASC_USERNAME       required: Apple ID email (altool does not infer it from the keychain item)
#        ASC_PROVIDER_ID    required: provider public ID (xcrun altool --list-providers -u "$ASC_USERNAME" -p @keychain:QS_ASC)
#        QS_DRY_RUN=1       print the altool command lines and exit
#        QS_NO_WAIT=1       don't wait for server-side processing after upload
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="${1:-$ROOT/dist-appstore/QuickStudy.pkg}"
ITEM="${ASC_KEYCHAIN_ITEM:-QS_ASC}"
APPLE_ID="${QS_APPLE_APP_ID:-6792768370}"

: "${ASC_USERNAME:?set ASC_USERNAME to your Apple ID email}"
: "${ASC_PROVIDER_ID:?set ASC_PROVIDER_ID; find it with: xcrun altool --list-providers -u \"\$ASC_USERNAME\" -p @keychain:$ITEM}"
[[ -f "$PKG" ]] || { echo "ERROR: pkg not found: $PKG (run ./scripts/build-appstore.sh)" >&2; exit 1; }

# The pkg is the single source of truth: expand it and read the Info.plist inside
# (never a stale dist-appstore/QuickStudy.app).
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pkgutil --expand-full "$PKG" "$TMP/x" >/dev/null
PLIST="$(find "$TMP/x" -path '*.app/Contents/Info.plist' -maxdepth 6 | head -1)"
[[ -n "$PLIST" ]] || { echo "ERROR: no .app Info.plist inside $PKG" >&2; exit 1; }
pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"; }
BUNDLE_ID="$(pb CFBundleIdentifier)"
SHORT="$(pb CFBundleShortVersionString)"
BUILD="$(pb CFBundleVersion)"
echo "==> $BUNDLE_ID $SHORT (build $BUILD), app $APPLE_ID, keychain item $ITEM"

ARGS=(-t macos --apple-id "$APPLE_ID" --bundle-id "$BUNDLE_ID"
      --bundle-version "$BUILD" --bundle-short-version-string "$SHORT"
      -u "$ASC_USERNAME" -p "@keychain:$ITEM" --provider-public-id "$ASC_PROVIDER_ID")

fail() {
    echo "ERROR: altool $1 failed. If the message is about credentials or the keychain item '$ITEM'," >&2
    echo "       the human must store it once:" >&2
    echo "       xcrun altool --store-password-in-keychain-item $ITEM --username <apple-id> --app-password <app-specific-password>" >&2
    exit 1
}

WAIT=(--wait); [[ "${QS_NO_WAIT:-0}" == "1" ]] && WAIT=()
if [[ "${QS_DRY_RUN:-0}" == "1" ]]; then
    echo "xcrun altool --validate-app $PKG ${ARGS[*]}"
    echo "xcrun altool --upload-package $PKG ${ARGS[*]} ${WAIT[*]-}"
    exit 0
fi

echo "==> Validating…"
xcrun altool --validate-app "$PKG" "${ARGS[@]}" || fail validate

echo "==> Uploading…"
xcrun altool --upload-package "$PKG" "${ARGS[@]}" ${WAIT[@]+"${WAIT[@]}"} || fail upload
echo "==> Uploaded build $BUILD. Check state: xcrun altool --build-status --apple-id $APPLE_ID --bundle-id $BUNDLE_ID --bundle-version $BUILD --bundle-short-version-string $SHORT -u $ASC_USERNAME -p @keychain:$ITEM"
