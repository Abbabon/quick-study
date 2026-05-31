# Homebrew Tap Distribution for QuickStudy — Design

**Date:** 2026-05-31
**Status:** Approved (design), pending spec review

## Goal

Enable a one-line install of QuickStudy on another (same-arch, Apple Silicon)
Mac without requiring a developer toolchain on the target machine:

```sh
brew install --cask --no-quarantine Abbabon/quick-study/quick-study
```

Plus the unavoidable manual step of granting Accessibility permission on first
run for the global hotkey.

## Constraints & decisions

- **arm64 only.** No universal binary. Target test Macs are Apple Silicon.
- **Manual releases.** A `scripts/release.sh` run from the dev Mac; no CI.
- **Ad-hoc signed, not notarized.** Personal-testing distribution. Gatekeeper
  is sidestepped by installing with `--no-quarantine`.
- **GitHub auth as Abbabon.** The maintainer runs `gh auth switch` to the
  `Abbabon` account before any GitHub-side step (releases attach to
  `Abbabon/quick-study`; the tap lives at `Abbabon/homebrew-quick-study`).
- **Bundle ID change:** `com.user.QuickStudy` → `com.abbabon.quickstudy`.

## Components

### 1. Tap repo: `Abbabon/homebrew-quick-study`

A Homebrew tap is a Git repo named `homebrew-*`. Contents:

```
Casks/quick-study.rb
README.md
```

`Casks/quick-study.rb`:

```ruby
cask "quick-study" do
  version "0.1.0"
  sha256 "<computed at release>"
  url "https://github.com/Abbabon/quick-study/releases/download/v#{version}/QuickStudy-#{version}.zip"
  name "Quick Study"
  desc "Spotlight-style Magic: The Gathering card lookup"
  homepage "https://github.com/Abbabon/quick-study"
  depends_on macos: ">= :sonoma"   # macOS 14
  app "QuickStudy.app"
  zap trash: [
    "~/Library/Application Support/QuickStudy",
    "~/Library/Logs/QuickStudy",
    "~/Library/Preferences/com.abbabon.quickstudy.plist",
  ]
end
```

### 2. `scripts/release.sh` (new, in main repo)

Usage: `./scripts/release.sh <version>` (e.g. `0.1.0`).

Steps:

1. Validate: clean working tree, version arg is semver, tag `v<version>` does
   not already exist.
2. Patch `Resources/Info.plist`: `CFBundleShortVersionString = <version>`, bump
   `CFBundleVersion` (read current integer, +1).
3. `scripts/build-app.sh release` (arm64 host build).
4. Zip with `ditto -c -k --keepParent dist/QuickStudy.app dist/QuickStudy-<version>.zip`.
   **Use `ditto`, not `zip`** — ditto preserves the bundle's code signature.
5. Compute `shasum -a 256` of the zip.
6. Commit the version bump; create and push tag `v<version>` (the existing
   `origin` remote already uses Abbabon credentials).
7. `gh release create v<version>` with the zip attached.
8. Update `Casks/quick-study.rb` in the tap checkout (version + sha256), commit,
   push.

Tap location resolved via `TAP_DIR` env var, default `../homebrew-quick-study`;
if the directory is absent, clone it from `Abbabon/homebrew-quick-study`.

### 3. Bundle ID change

- `Resources/Info.plist:9` — `CFBundleIdentifier` → `com.abbabon.quickstudy`.
- Rename `Resources/com.user.QuickStudy.refresh.plist` →
  `Resources/com.abbabon.quickstudy.refresh.plist`; update its `Label` to
  `com.abbabon.quickstudy.refresh`.
- `README.md` — update the project-layout tree reference to the new filename.

No Swift code references the bundle ID (verified via grep), so the change is
confined to the two resource files and the README.

### 4. Documentation

- Tap `README.md`: the install one-liner + Accessibility-permission note.
- Main `README.md`: add a "Install via Homebrew" section alongside the existing
  build-from-source instructions.

## One-time bootstrap (manual, after `gh auth switch` to Abbabon)

1. `gh repo create Abbabon/homebrew-quick-study --public`.
2. Seed it with `Casks/quick-study.rb` + `README.md`, push.

## Sequence to ship 0.1.0

1. Maintainer: `gh auth switch` → Abbabon.
2. Bootstrap the tap repo.
3. Run `scripts/release.sh 0.1.0`.
4. Test on the other Mac:
   `brew install --cask --no-quarantine Abbabon/quick-study/quick-study`.

## Out of scope (YAGNI)

- Notarization (covered by `--no-quarantine` for personal testing).
- Universal (arm64 + x86_64) binary.
- CI / tag-triggered automated releases.
- Auto-update mechanism (Sparkle, etc.).
