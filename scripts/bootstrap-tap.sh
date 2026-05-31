#!/bin/bash
# One-time setup of the Homebrew tap repo Abbabon/homebrew-quick-study.
# Creates the repo (if missing) and seeds it with a README. The cask itself is
# written by scripts/release.sh on the first release.
#
# Requires `gh` authenticated as the Abbabon account. Idempotent: safe to re-run.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAP_REPO="Abbabon/homebrew-quick-study"
TAP_DIR="${TAP_DIR:-$ROOT/../homebrew-quick-study}"

if gh repo view "$TAP_REPO" >/dev/null 2>&1; then
    echo "==> $TAP_REPO already exists"
else
    echo "==> Creating $TAP_REPO"
    gh repo create "$TAP_REPO" --public \
        --description "Homebrew tap for Quick Study" --add-readme
fi

if [[ ! -d "$TAP_DIR" ]]; then
    echo "==> Cloning $TAP_REPO -> $TAP_DIR"
    git clone "https://github.com/$TAP_REPO.git" "$TAP_DIR"
fi
mkdir -p "$TAP_DIR/Casks"

cat > "$TAP_DIR/README.md" <<'EOF'
# Homebrew Tap — Quick Study

A Homebrew tap for [Quick Study](https://github.com/Abbabon/quick-study), a
Spotlight-style Magic: The Gathering card lookup for macOS.

## Install

```sh
brew install --cask Abbabon/quick-study/quick-study
```

The app is ad-hoc signed (not notarized); the cask strips the macOS quarantine
attribute on install (in a `postflight` step) so Gatekeeper allows it to open.

After installing, launch Quick Study and grant **Accessibility** permission when
prompted (System Settings → Privacy & Security → Accessibility) so the global
hotkey works.

> Apple Silicon (arm64) only.

## Update

```sh
brew upgrade --cask quick-study
```

## Uninstall

```sh
brew uninstall --cask quick-study           # remove the app
brew uninstall --zap --cask quick-study     # also remove cached data & images
```
EOF

cd "$TAP_DIR"
git add README.md Casks 2>/dev/null || git add README.md
if [[ -n "$(git status --porcelain)" ]]; then
    git commit -m "Seed tap README"
    git push origin HEAD
    echo "==> Pushed seed commit"
else
    echo "==> Nothing to commit"
fi

echo "==> Tap ready at $TAP_DIR"
