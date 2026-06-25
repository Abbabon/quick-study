# Release Notes Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hardcoded GitHub Release notes in `scripts/release.sh` with curated, user-facing notes produced by a new `/release` Claude Code skill.

**Architecture:** Two halves with one interface (a markdown notes-file path). `release.sh` gains an order-independent arg parser and a `--notes-file` flag (backward compatible — falls back to today's inline notes when absent). A new project skill `.claude/skills/release/SKILL.md` drives Claude to gather commits since the last tag, curate grouped prose notes, preview them for approval, write them to `dist/release-notes-<version>.md`, then invoke the script.

**Tech Stack:** Bash, `gh` CLI, git, Claude Code skill markdown.

## Global Constraints

- Repo: `Abbabon/quick-study`; tap install ref: `Abbabon/quick-study/quick-study`.
- Releases are tagged `vX.Y.Z`; version must be valid semver and strictly greater than the latest tag.
- `gh` must be authenticated as the `Abbabon` account with push access to both `Abbabon/quick-study` and `Abbabon/homebrew-quick-study`.
- `dist/` is gitignored build output — the notes file lives there and must not be committed.
- The script must remain runnable standalone (no skill required) for backward compatibility.
- Branch in use: `feat/release-notes-skill` (already created; spec already committed there).

---

### Task 1: `release.sh` — `--notes-file` flag + arg parsing

**Files:**
- Modify: `scripts/release.sh:31-33` (positional arg handling) and `scripts/release.sh:48-57` (preflight) and `scripts/release.sh:96-104` (gh release create)

**Interfaces:**
- Produces: CLI contract `./scripts/release.sh <version> [--dry-run] [--notes-file <path>]`. Flags are order-independent after the required first positional `<version>`. When `--notes-file <path>` is set, the GitHub release body is read from that file; when absent, the existing inline notes are used.

- [ ] **Step 1: Replace positional flag handling with an arg loop**

In `scripts/release.sh`, replace these lines (currently around 31-33):

```bash
VERSION="${1:-}"
DRY_RUN=0
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=1
```

with:

```bash
VERSION="${1:-}"
shift || true
DRY_RUN=0
NOTES_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            ;;
        --notes-file)
            NOTES_FILE="${2:-}"
            if [[ -z "$NOTES_FILE" ]]; then
                echo "error: --notes-file requires a path argument" >&2
                exit 1
            fi
            shift
            ;;
        *)
            echo "error: unknown argument '$1'" >&2
            exit 1
            ;;
    esac
    shift
done
```

Also update the usage string (line ~36) to:

```bash
    echo "usage: $0 <version> [--dry-run] [--notes-file <path>]" >&2
```

- [ ] **Step 2: Validate the notes file exists during preflight**

In the preflight section, after the existing semver check and before/within the `if [[ $DRY_RUN -eq 0 ]]` block is fine, but the file check should run for BOTH dry-run and publish. Add this immediately after the semver validation block (after the `fi` that closes the `=~ ^[0-9]...` check, around line 42):

```bash
if [[ -n "$NOTES_FILE" && ! -f "$NOTES_FILE" ]]; then
    echo "error: --notes-file '$NOTES_FILE' not found" >&2
    exit 1
fi
```

- [ ] **Step 3: Use the notes file in `gh release create` when provided**

Replace the GitHub-release block (currently lines ~95-104):

```bash
echo "==> Creating GitHub release $TAG"
gh release create "$TAG" "$ZIP" \
    --repo "$REPO" \
    --title "$APP_NAME $VERSION" \
    --notes "QuickStudy $VERSION

Install:
\`\`\`sh
brew install --cask $TAP_REF
\`\`\`"
```

with:

```bash
echo "==> Creating GitHub release $TAG"
if [[ -n "$NOTES_FILE" ]]; then
    gh release create "$TAG" "$ZIP" \
        --repo "$REPO" \
        --title "$APP_NAME $VERSION" \
        --notes-file "$NOTES_FILE"
else
    gh release create "$TAG" "$ZIP" \
        --repo "$REPO" \
        --title "$APP_NAME $VERSION" \
        --notes "QuickStudy $VERSION

Install:
\`\`\`sh
brew install --cask $TAP_REF
\`\`\`"
fi
```

- [ ] **Step 4: Verify arg parsing with a syntax check and an unknown-arg test**

Run: `bash -n scripts/release.sh`
Expected: no output, exit 0 (script is syntactically valid).

Run: `./scripts/release.sh 9.9.9 --bogus 2>&1; echo "exit=$?"`
Expected: `error: unknown argument '--bogus'` and `exit=1`.

Run: `./scripts/release.sh 9.9.9 --notes-file 2>&1; echo "exit=$?"`
Expected: `error: --notes-file requires a path argument` and `exit=1`.

Run: `./scripts/release.sh 9.9.9 --notes-file /no/such/file 2>&1; echo "exit=$?"`
Expected: `error: --notes-file '/no/such/file' not found` and `exit=1`.

- [ ] **Step 5: Verify a real dry-run accepts the notes file (builds, no publish)**

Run:
```bash
printf '## QuickStudy 9.9.9\n\ntest notes\n' > /tmp/qs-notes.md
./scripts/release.sh 9.9.9 --dry-run --notes-file /tmp/qs-notes.md
```
Expected: builds + zips, prints the sha256, prints `==> dry-run: skipping ...`, exits 0, and leaves `Info.plist` unchanged (`git status --porcelain Resources/Info.plist` is empty afterward).

> Note: this performs a real `swift build`/zip via `build-app.sh` and may take a minute. If a sandbox blocks the build, the parsing checks in Step 4 are the authoritative gate; record that the dry-run was skipped.

- [ ] **Step 6: Commit**

```bash
git add scripts/release.sh
git commit -m "feat(release): accept --notes-file for GitHub release body

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `/release` skill

**Files:**
- Create: `.claude/skills/release/SKILL.md`

**Interfaces:**
- Consumes: the `release.sh` CLI contract from Task 1 (`<version> [--dry-run] [--notes-file <path>]`).
- Produces: a user-invocable `/release <version>` skill. No code consumes this; it is the human entry point.

- [ ] **Step 1: Write the skill file**

Create `.claude/skills/release/SKILL.md` with exactly this content:

````markdown
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
  ` ` `sh
  brew install --cask Abbabon/quick-study/quick-study
  ` ` `
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
````

- [ ] **Step 2: Verify the skill is well-formed**

Run: `head -5 .claude/skills/release/SKILL.md`
Expected: shows the YAML frontmatter with `name: release` and a `description:` line.

Run: `grep -c '^### ' .claude/skills/release/SKILL.md`
Expected: `5` (the five numbered step sections).

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/release/SKILL.md
git commit -m "feat(release): add /release skill for curated release notes

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review notes

- **Spec coverage:** Component 1 (script `--notes-file` + arg loop + fallback) → Task 1. Component 2 (skill with preflight/gather/curate/preview/publish steps) → Task 2. Notes format example → embedded in the skill's step 3. Error handling (missing notes file, rejected preview, script safeguards) → Task 1 step 2 + Task 2 steps 1/4. All covered.
- **Interface consistency:** Both tasks reference the same CLI contract `<version> [--dry-run] [--notes-file <path>]`. The notes path `dist/release-notes-<version>.md` is identical in both.
- **Out of scope (per spec):** no CHANGELOG, no CI, no tap-notes — none added.
