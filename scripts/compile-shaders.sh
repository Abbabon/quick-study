#!/usr/bin/env bash
# Compile Resources/Foil.metal (SwiftUI stitchable foil shaders) into Foil.metallib inside the
# given Resources dir. Needs the Metal toolchain: `xcodebuild -downloadComponent MetalToolchain`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$1"
xcrun metal -std=metal3.1 -mmacosx-version-min=14.0 -O3 "$ROOT/Resources/Foil.metal" -o "$OUT/Foil.metallib"
