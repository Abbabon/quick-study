#!/usr/bin/env bash
# Compile Resources/AppIcon.icon (Icon Composer, needs Xcode 26+ actool) into
# Assets.car + fallback AppIcon.icns inside the given Resources dir.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$1"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
xcrun actool "$ROOT/Resources/AppIcon.icon" --compile "$TMP" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon AppIcon \
    --output-partial-info-plist "$TMP/partial.plist" >/dev/null
cp "$TMP/Assets.car" "$TMP/AppIcon.icns" "$OUT/"
