#!/bin/bash
# Build QuickStudy.app and install it to /Applications, replacing any existing copy.
# Usage: ./scripts/install-local.sh [debug|release]   (default: release)

set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="QuickStudy"
SRC_APP="$ROOT/dist/$APP_NAME.app"
DST_APP="/Applications/$APP_NAME.app"

"$ROOT/scripts/build-app.sh" "$CONFIG"

echo "==> Stopping any running $APP_NAME..."
pkill -x "$APP_NAME" 2>/dev/null || true
# Give it a moment to release file handles before we overwrite the bundle.
sleep 1

echo "==> Installing to $DST_APP"
rm -rf "$DST_APP"
cp -R "$SRC_APP" "$DST_APP"

echo "==> Re-signing in place (ad-hoc)..."
codesign --force --deep --sign - "$DST_APP" >/dev/null

echo "==> Relaunching $APP_NAME"
open -a "$APP_NAME"

echo "==> Done."
