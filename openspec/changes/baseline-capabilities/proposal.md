## Why

QuickStudy has shipped real features (search, fetch, panel, cache) without any
written behavior contracts. Future changes have nothing to diff against, and the
only sources of truth for invariants like "search ranks exact above prefix" or
"fetcher is idempotent and resumable" are scattered across CLAUDE.md, golden
tests, and code comments. Adopting spec-driven development from this point
requires a baseline: a one-time retroactive capture of current behavior so every
subsequent change is a real delta against a real spec.

## What Changes

- Document the five existing user-visible capabilities as new specs in
  `openspec/specs/`.
- Each spec captures observed current behavior — not aspirational redesign.
  Drift discovered between spec and code during this exercise is logged as a
  follow-up, not fixed in this change.
- `tasks.md` contains **verification** work only (run golden tests, exercise
  the fetcher subprocess, observe panel behavior). No source code is modified.
- No breaking changes. No dependency or API changes.

## Capabilities

### New Capabilities
- `card-search`: In-memory layered fuzzy ranker over loaded `Card.Mini` rows,
  with sub-millisecond target latency and stable ordering protected by golden
  tests.
- `card-detail`: On-demand full-row fetch from SQLite for the highlighted
  result, cached via `NSCache`, with image rendering from the local image
  directory.
- `card-data-refresh`: Subprocess-driven bulk data refresh via the `mtg-fetcher`
  CLI using a four-phase NDJSON progress protocol, idempotent and resumable.
- `panel-session`: Borderless non-activating HUD `NSPanel` shown via a global
  hotkey, with screen-edge clamping and a session lifecycle (resign-key
  auto-dismiss, Esc close). Aligned with the same capability name used by the
  in-flight `clear-search-on-timeout` change so its idle-clear requirements
  layer on this baseline rather than forking.
- `image-cache`: Local image directory under Application Support with helpers
  for measuring on-disk size and clearing contents, gated on idle.

### Modified Capabilities
<!-- None. This is a baseline; nothing pre-existing in openspec/specs/. -->

## Impact

- **Code**: none. This change is documentation-only.
- **Tests**: existing `SearchEngineTests` golden cases are treated as the
  authoritative reference for `card-search` scenarios.
- **Process**: from this change forward, modifications to any of the five
  capabilities should be proposed as deltas against these specs rather than
  authored ad-hoc.
- **Follow-ups**: any drift between documented behavior and observed behavior
  surfaced during verification is captured as a separate change proposal, not
  silently corrected here.
