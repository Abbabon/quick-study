## Context

QuickStudy already exists and ships. This change does not modify code; it
retroactively writes behavior contracts for the five user-visible capabilities
identified in the proposal. The constraint that makes this a "design" rather
than a free-form documentation pass is that the resulting specs must integrate
with the OpenSpec workflow — meaning a separate in-flight change
(`clear-search-on-timeout`) which adds requirements to a `panel-session`
capability must layer onto whatever baseline this change produces.

## Goals / Non-Goals

**Goals:**
- Produce one spec per capability under `openspec/changes/baseline-capabilities/specs/`
  that, after archive, lands in `openspec/specs/`.
- Spec content reflects **observed current behavior**, derived from the source
  files and tests, not aspirational future behavior.
- Use the same `panel-session` capability name as the in-flight
  `clear-search-on-timeout` change so its deltas merge cleanly.
- Treat the existing `SearchEngineTests` golden cases as the authoritative
  source for `card-search` scenarios — every documented ranking scenario
  should map back to a test (or surface a missing test as a follow-up).

**Non-Goals:**
- Fixing any drift discovered between spec and code. Drift surfaces as a
  follow-up change proposal.
- Documenting Shared library internals (`CardStore`, `Paths`, `Card`) as their
  own capability. They support the five user-facing capabilities; they do not
  have user-visible behavior of their own.
- Documenting Settings UI as a capability. Settings is a surface that exposes
  configuration knobs belonging to other capabilities (e.g., the clear-search
  timeout belongs to `panel-session`, not "settings").
- Defining new behavior. If a requirement is tempting to write because it
  *should* be true but isn't observable in code today, it does not belong in
  this change.

## Decisions

### Decision: Five capabilities, not three or seven

Considered alternatives:
- **Three capabilities** (search, refresh, panel) — too coarse; collapses
  `card-detail` (lazy SQLite + NSCache) into either search or panel and loses
  the distinct contract.
- **Seven capabilities** (split panel-session into hotkey/positioning/lifecycle,
  split refresh into subprocess/protocol/idempotency) — too fine; each future
  change would span multiple specs, increasing delta count without value.
- **Five** matches the natural seams in the codebase
  (`SearchEngine`, `AppModel.select`, `FetcherProcess` + `ProgressEmitter`,
  `PanelController`, `ImageCache`) and matches how a user would describe what
  the app does.

### Decision: `panel-session` over `menu-bar-panel`

The in-flight `clear-search-on-timeout` change already uses `panel-session`.
Using the same name lets its `ADDED Requirements` either layer on top of this
baseline (if this change archives first) or co-exist (if its change archives
first, we revise to use `MODIFIED Requirements`). Picking a different name
would force a rename or a duplicate capability later.

### Decision: Tests are verification, not implementation

`tasks.md` contains verification tasks (run `swift test`, exercise the fetcher
with `--no-images`, observe panel behavior manually) rather than implementation
tasks. The "implementation" of a baseline change is the act of writing the
specs themselves; once written, the work is to **confirm** the code already
matches.

### Decision: Idle-clear timeout requirement lives in the in-flight change, not here

`PanelController.clearSearchIfTimedOut` exists in code today, but the in-flight
`clear-search-on-timeout` change owns the requirement statements for it. To
keep the baseline scope-clean and avoid duplicate requirements at archive time,
this change's `panel-session` spec documents only the panel chrome, hotkey,
positioning, and dismissal behavior. Session-reset behavior is left to the
in-flight change's spec, which appends to the same capability.

## Risks / Trade-offs

- **Drift discovery without action** → Verification tasks may surface real
  bugs. Mitigation: capture each as a one-line follow-up at the end of
  `tasks.md` and propose a separate change rather than expanding scope.
- **Archive ordering with `clear-search-on-timeout`** → If that change archives
  first, this change's `panel-session` spec must shift from `ADDED` to a mix
  of `ADDED` (new requirements) and tolerate that the timeout requirement
  already exists. Mitigation: archive `baseline-capabilities` first if both
  are ready; if not, revise the `panel-session` spec at archive time.
- **Spec phrasing freezes implementation choices** → e.g., "in-memory ranker"
  encodes that search is not SQLite-backed. Mitigation: phrase requirements in
  terms of *observable behavior* (latency, ordering) rather than mechanism
  where possible; reserve mechanism-bound language for cases where the
  mechanism is itself the contract (e.g., NDJSON over stdout, four phases).

## Migration Plan

Not applicable — no runtime change. After archive, future changes touching
search/detail/refresh/panel/cache must propose deltas against these specs.
