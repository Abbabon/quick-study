#!/bin/bash
# Cut a release of QuickStudy: build, zip, tag, create a GitHub Release, and
# update the Homebrew cask in the tap.
#
# Usage:
#   ./scripts/release.sh <version> [--dry-run]
#     <version>   semver, e.g. 0.1.0
#     --dry-run   build + zip + sha256 only; no version commit, no git tag,
#                 no GitHub release, no tap push. Leaves Info.plist untouched.
#
# Requires (for a real publish): `gh` authenticated as the Abbabon account and
# push access to both Abbabon/quick-study and Abbabon/homebrew-quick-study.
#
# Tap location is resolved from $TAP_DIR (default ../homebrew-quick-study). If
# the directory is absent it is cloned. Run scripts/bootstrap-tap.sh once first.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="QuickStudy"
REPO="Abbabon/quick-study"
TAP_REPO="Abbabon/homebrew-quick-study"
TAP_REF="Abbabon/quick-study/quick-study"   # what end users type for `brew install`
TAP_DIR="${TAP_DIR:-$ROOT/../homebrew-quick-study}"
PLIST="$ROOT/Resources/Info.plist"

VERSION="${1:-}"
DRY_RUN=0
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=1

if [[ -z "$VERSION" ]]; then
    echo "usage: $0 <version> [--dry-run]" >&2
    exit 1
fi
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: version '$VERSION' is not semver (X.Y.Z)" >&2
    exit 1
fi

TAG="v$VERSION"
ZIP="$ROOT/dist/$APP_NAME-$VERSION.zip"

# --- preflight (publish only) ---
if [[ $DRY_RUN -eq 0 ]]; then
    if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
        echo "error: working tree not clean; commit or stash first" >&2
        exit 1
    fi
    if git -C "$ROOT" rev-parse "$TAG" >/dev/null 2>&1; then
        echo "error: tag $TAG already exists" >&2
        exit 1
    fi
fi

# --- version bump ---
echo "==> Setting version $VERSION in Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
CUR_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")"
NEW_BUILD=$(( CUR_BUILD + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"
echo "    CFBundleShortVersionString=$VERSION  CFBundleVersion=$NEW_BUILD"

# --- build ---
"$ROOT/scripts/build-app.sh" release

# --- zip (ditto preserves the bundle's code signature; plain `zip` does not) ---
echo "==> Zipping bundle -> $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$ROOT/dist/$APP_NAME.app" "$ZIP"

SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "==> sha256: $SHA"

if [[ $DRY_RUN -eq 1 ]]; then
    echo "==> dry-run: skipping version commit, git tag, GitHub release, tap update."
    echo "    artifact: $ZIP"
    # Leave the tree as we found it.
    git -C "$ROOT" checkout -- "$PLIST" 2>/dev/null || true
    exit 0
fi

# --- commit version bump + tag ---
echo "==> Committing version bump and tagging $TAG"
git -C "$ROOT" add "$PLIST"
git -C "$ROOT" commit -m "Release $VERSION"
git -C "$ROOT" tag "$TAG"
git -C "$ROOT" push origin HEAD
git -C "$ROOT" push origin "$TAG"

# --- GitHub release ---
echo "==> Creating GitHub release $TAG"
gh release create "$TAG" "$ZIP" \
    --repo "$REPO" \
    --title "$APP_NAME $VERSION" \
    --notes "QuickStudy $VERSION

Install:
\`\`\`sh
brew install --cask $TAP_REF
\`\`\`"

# --- update tap ---
if [[ ! -d "$TAP_DIR" ]]; then
    echo "==> Cloning tap $TAP_REPO -> $TAP_DIR"
    git clone "https://github.com/$TAP_REPO.git" "$TAP_DIR"
fi
mkdir -p "$TAP_DIR/Casks"

echo "==> Writing cask"
cat > "$TAP_DIR/Casks/quick-study.rb" <<EOF
cask "quick-study" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/$APP_NAME-#{version}.zip"
  name "Quick Study"
  desc "Spotlight-style Magic: The Gathering card lookup"
  homepage "https://github.com/$REPO"

  depends_on macos: ">= :sonoma"

  app "$APP_NAME.app"

  # The app is ad-hoc signed (not notarized). Homebrew quarantines downloads and
  # no longer offers --no-quarantine, so strip the quarantine attribute here or
  # Gatekeeper would refuse to open it. must_succeed: false because xattr exits
  # non-zero for nested files that never had the attribute.
  postflight do
    system_command "/usr/bin/xattr",
                   args:         ["-dr", "com.apple.quarantine", "#{appdir}/$APP_NAME.app"],
                   must_succeed: false
  end

  zap trash: [
    "~/Library/Application Support/QuickStudy",
    "~/Library/Logs/QuickStudy",
    "~/Library/Preferences/com.abbabon.quickstudy.plist",
  ]
end
EOF

git -C "$TAP_DIR" add Casks/quick-study.rb
git -C "$TAP_DIR" commit -m "quick-study $VERSION"
git -C "$TAP_DIR" push origin HEAD

echo "==> Done. Install with:"
echo "    brew install --cask $TAP_REF"
