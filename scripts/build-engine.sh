#!/bin/bash
# Build the Rust engine (engine/) for arm64. The one entry point every other script calls.
#   1. the UniFFI static library -> engine/EngineFFI.xcframework (+ Sources/EngineBindings/engine.swift),
#      consumed by SwiftPM as a local binaryTarget. Both are gitignored: run this once on a fresh
#      clone before `swift build` / `swift test`.
#   2. the mtg-fetcher binary; its path is printed on stdout (cargo output goes to stderr).
# Usage: path="$(./scripts/build-engine.sh [debug|release])"   (default: release; the
#        static library is always built release so search performance never depends on CONFIG)

set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="aarch64-apple-darwin"
ENGINE="$ROOT/engine"
OUT="$ENGINE/target/$TARGET"
XCF="$ENGINE/EngineFFI.xcframework"
BINDINGS="$ROOT/Sources/EngineBindings"

# Cargo may not be on PATH in non-interactive shells (rustup installs to ~/.cargo/bin).
export PATH="$HOME/.cargo/bin:$PATH"
# Make any bundled C code target the app's macOS 14 instead of the SDK's, or the
# SwiftPM link warns. Not MACOSX_DEPLOYMENT_TARGET: that breaks fresh builds of proc-macro crates
# ("can't find crate for time_macros") with the macOS 27 toolchain.
export CFLAGS_aarch64_apple_darwin="-mmacosx-version-min=14.0"
command -v cargo >/dev/null || { echo "ERROR: cargo not found — install Rust via https://rustup.rs" >&2; exit 1; }

cargo_() { cargo "$@" --manifest-path "$ENGINE/Cargo.toml" --target "$TARGET" >&2; }

# --- UniFFI static library + bindings -> XCFramework -------------------------------------
cargo_ build --release --lib --features ffi
cargo_ build --release --bin uniffi-bindgen --features bindgen

GEN="$(mktemp -d)"
trap 'rm -rf "$GEN"' EXIT
(cd "$ENGINE" && "$OUT/release/uniffi-bindgen" generate --library "$OUT/release/libengine.a" --language swift --out-dir "$GEN/out" >&2)

mkdir -p "$GEN/headers" "$BINDINGS"
cp "$GEN/out/engineFFI.h" "$GEN/headers/"
cp "$GEN/out/engineFFI.modulemap" "$GEN/headers/module.modulemap"
# Only touch the Swift file when it changed, so SwiftPM doesn't recompile for nothing.
cmp -s "$GEN/out/engine.swift" "$BINDINGS/engine.swift" || cp "$GEN/out/engine.swift" "$BINDINGS/engine.swift"

rm -rf "$XCF"
xcodebuild -create-xcframework -library "$OUT/release/libengine.a" -headers "$GEN/headers" -output "$XCF" >&2

# --- mtg-fetcher ---------------------------------------------------------------------------
FLAGS=(build --bin mtg-fetcher)
[[ "$CONFIG" == "release" ]] && FLAGS+=(--release)
cargo_ "${FLAGS[@]}"

echo "$OUT/$CONFIG/mtg-fetcher"
