#!/bin/bash
# Build QuickStudy.app bundle from `swift build` artifacts.
# Usage: ./scripts/build-app.sh [debug|release]   (default: release)

set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="QuickStudy"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "==> Building Swift package ($CONFIG)…"
cd "$ROOT"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Assembling app bundle at $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN_DIR/QuickStudy"   "$APP/Contents/MacOS/QuickStudy"
cp "$BIN_DIR/mtg-fetcher"  "$APP/Contents/MacOS/mtg-fetcher"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "    (note: Resources/AppIcon.icns not found — bundling without an icon. Run scripts/generate-icon.py)"
fi

# Ad-hoc sign so the system trusts it locally.
codesign --force --deep --sign - "$APP" >/dev/null

echo "==> Done."
echo "    open $APP"
