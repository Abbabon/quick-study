#!/bin/bash
# Build QuickStudy.app bundle from `swift build` artifacts.
# Usage: ./scripts/build-app.sh [debug|release]   (default: release)

set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="QuickStudy"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "==> Building Rust engine (XCFramework + mtg-fetcher, $CONFIG)…"
cd "$ROOT"
FETCHER="$("$ROOT/scripts/build-engine.sh" "$CONFIG")"

echo "==> Building Swift package ($CONFIG)…"
cd "$ROOT"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Assembling app bundle at $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN_DIR/QuickStudy"   "$APP/Contents/MacOS/QuickStudy"
cp "$FETCHER"              "$APP/Contents/MacOS/mtg-fetcher"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

cp "$ROOT/Resources/HeaderWordmark.png" "$APP/Contents/Resources/HeaderWordmark.png"
cp "$ROOT/Resources/HeaderWordmark-Light.png" "$APP/Contents/Resources/HeaderWordmark-Light.png"
cp "$ROOT/Resources/WhatsNew.md" "$APP/Contents/Resources/WhatsNew.md"

"$ROOT/scripts/compile-icon.sh" "$APP/Contents/Resources"

# Ad-hoc sign so the system trusts it locally.
codesign --force --deep --sign - "$APP" >/dev/null

echo "==> Done."
echo "    open $APP"
