#!/bin/bash
# Build the Rust mtg-fetcher (engine/) for arm64 and print the binary's path on stdout.
# Usage: path="$(./scripts/build-fetcher.sh [debug|release])"   (default: release)
# Cargo output goes to stderr so callers can capture just the path.

set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="aarch64-apple-darwin"

# Cargo may not be on PATH in non-interactive shells (rustup installs to ~/.cargo/bin).
export PATH="$HOME/.cargo/bin:$PATH"
command -v cargo >/dev/null || { echo "ERROR: cargo not found — install Rust via https://rustup.rs" >&2; exit 1; }

FLAGS=(--manifest-path "$ROOT/engine/Cargo.toml" --target "$TARGET" --bin mtg-fetcher)
[[ "$CONFIG" == "release" ]] && FLAGS+=(--release)
cargo build "${FLAGS[@]}" >&2

echo "$ROOT/engine/target/$TARGET/$CONFIG/mtg-fetcher"
