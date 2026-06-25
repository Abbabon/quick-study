---
name: release
description: Cut a QuickStudy release with auto-generated, curated release notes. Use when the user wants to publish a new version (e.g. "release 0.4.0", "cut a release"). Gathers commits since the last tag, drafts grouped user-facing notes, gets approval, then runs scripts/release.sh.
---

# Release QuickStudy

Drive a release end-to-end: analyze what changed, write good release notes, get
approval, then hand off to `scripts/release.sh` for all the mechanics (build,
tag, GitHub release, Homebrew tap, dev-version bump).

You own the *notes*. The script owns the *mechanics*. Do not duplicate the
script's git tagging/pushing yourself.

## Inputs

- `<version>` — semver `X.Y.Z`. If the user didn't give one, ask. It must be
  strictly greater than the latest `vX.Y.Z` tag.

## Steps

Create a todo per step and work through them in order.

### 1. Preflight

Run these and stop with a clear message if any fails:

- Working tree clean: `git status --porcelain` is empty. (If only unrelated
  files are dirty, tell the user — the script requires a clean tree to publish.)
- Latest tag: `git tag --sort=-v:refname | head -1`. Confirm `<version>` is valid
  semver and strictly greater.
- Tag not already used: `git rev-parse "v<version>"` must fail.
- `gh` authed as Abbabon: `gh auth status` shows the `Abbabon` account.

### 2. Gather changes

- `LAST=$(git tag --sort=-v:refname | head -1)`
- `git log --oneline "$LAST"..HEAD`
- For merge commits referencing a PR, run `gh pr view <n> --json title,body` when
  the squashed subject alone is unclear. Don't over-fetch — most subjects are
  self-explanatory.

### 3. Curate the notes

Group into **Features / Fixes / Other**. For each entry:

- Rewrite the conventional-commit subject into plain, user-facing language
  (a user of the app, not a contributor). Drop the `feat(scope):` prefixes.
- Squash multiple commits that ship one feature into a single bullet.
- Omit pure-internal noise (`docs:`, `chore:`, mechanical refactors) unless it
  matters to users.
- Append the PR number where known, e.g. `(#16)`.
- End the file with the install footer:

  ```
  ---
  Install:
  ```sh
  brew install --cask Abbabon/quick-study/quick-study
  ```
  ```

  (Use real triple-backticks; the spaces above are only to show them here.)

Title the body `## QuickStudy <version>`.

### 4. Preview and approve

- Write the body to `dist/release-notes-<version>.md` (create `dist/` if needed;
  it is gitignored — never commit it).
- Show the rendered markdown to the user and ask for approval or edits. Do not
  proceed until they approve. Revise and re-show if they request changes.

### 5. Publish

- Offer a dry run first:
  `./scripts/release.sh <version> --dry-run --notes-file dist/release-notes-<version>.md`
  (build + zip + sha only, no publish).
- On approval, publish:
  `./scripts/release.sh <version> --notes-file dist/release-notes-<version>.md`
- Report the resulting release URL and the `brew install --cask
  Abbabon/quick-study/quick-study` command.

## Notes

- The script bumps `Info.plist` to the next dev patch and pushes it after
  publishing — that's expected, not an error.
- If the script aborts on its own preflight (dirty tree, existing tag), surface
  the message; don't try to work around it.
