# Quick Study — Design System Implementation

**Date:** 2026-06-15
**Status:** Approved (design)

## Background

The "Quick Study Design System" handoff (`quick-study-design-system/`) was reverse-engineered
from this app's own source, so its structure already matches the codebase. The current SwiftUI
views, however, use **generic system styling** — `Color.accentColor`, `.secondary`/`.tertiary`,
and gray placeholder thumbnails — and are missing the two signature elements of the design system:

1. The **brand blue→violet accent** (the app currently uses the OS system accent).
2. The **MTG mana color identity** — WUBRG / colorless / **gold-for-multicolor** tints on
   thumbnails, card placeholders, mana pips, and identity badges (the app has none of this today).

This spec covers implementing the **full** design system natively in SwiftUI/AppKit, treating the
handoff tokens as the source of truth.

### Key data fact

`Card.colors` (`[String]`, e.g. `["W","U"]`) is already persisted as a JSON `TEXT` column in the
`cards` table (`colors`, default `"[]"`). **No DB migration is required.** `Card.Mini` — the ~25k
in-memory rows behind the result list and pinned row — currently carries only `id` + `name`, so
coloring *list* thumbnails by identity needs an additive `Mini` change; coloring the *preview*
pane does not (it already has the full `Card`).

## Architecture

Approach **A** (approved): centralized Swift token layer + a shared `ColorIdentity` helper, with
views referencing tokens only ("tokens only, one source of truth" — the design system's mandate).

```
Sources/Shared/
  Card.swift          (edit) ColorIdentity enum + Card.identity + Mini.identity
  CardStore.swift     (edit) loadMinis() reads existing colors column
Sources/QuickStudy/DesignSystem/   (new)
  Tokens.swift                 DS namespace: Color, Radius, Shadow, Motion + Color(light:dark:)
  ManaCostView.swift           mana-cost string → row of colored pips
  IdentityBadge.swift          identity-tinted capsule badge
  IdentityPlaceholder.swift    mana-tinted gradient fill for missing images
  BrandProminentButtonStyle.swift  accent-gradient fill for primary actions
Sources/QuickStudy/Views/   (edit) Thumbnail, ResultList, PinnedRow, CardPreview, SearchPanel,
                                    DownloadPromptView
Sources/QuickStudy/SettingsView.swift (edit) brand tint
Tests/   (new) ColorIdentityTests, ManaCostParserTests
```

## Components

### 1. Token layer — `DesignSystem/Tokens.swift`

A `DS` namespace. Adaptive colors use a `Color(light:dark:)` helper that resolves via the current
`NSAppearance`; the app follows the OS appearance (equivalent to the design's `data-theme="auto"`),
so no manual light/dark switch is built.

- **`DS.Color`**
  - Brand: `blue #283C8C`, `violet #7846B4`, `brandGradient` (160°). Brand/marketing mark only.
  - `accent`: `#5B45C2` (light) / `#9B8AF2` (dark) — borderless text, strokes, selection.
  - `accentGradient`: 150°, `#3E4FB5→#7A45B6` (light) / `#4A5BC8→#8E54CE` (dark) — solid fills.
  - `selection`: accent @ 0.16 (light) / 0.30 (dark); `selectionStrong`: 0.26 / 0.42.
  - Mana tints (theme-independent constants): `W #FFFBD5`, `U #AAE0FA`, `B #CBC2BF`, `R #F9AA8F`,
    `G #9BD3AE`, `C #CAC5C0`, `gold #D6B458`; `goldGradient` `#E6CC74→#C49B3F`; pip ink `#1A1714`.
  - Status: `red #FF3B30`, `green #34C759`, `orange #FF9500`.
  - **Text / surfaces / separators are NOT redefined** — they keep native macOS semantics
    (`.primary`, `.secondary`, `.tertiary`, `Color(nsColor: .separatorColor)`), which already match
    the design's 85/50/26/10% label opacities and adapt to OS light/dark automatically.
- **`DS.Radius`** — `xs 3`, `sm 6`, `md 7`, `lg 10`, `img 12`, `panel 14`.
- **`DS.Shadow`** — `card` (`0 8 24` black @ .18); `control` (`0 1 1` @ .05 + 0.5px ring).
- **`DS.Motion`** — `selectScroll` (`easeOut`, 0.08s); `resize` (0.2s).

Type continues to flow through `UIScale.font(size:weight:design:)` (sizes/weights are already
on-spec: 22 light search, 17 bold name, 14 row, 13 oracle, 12 type line, 11 meta, 10 pinned).
Only off-spec call sites get corrected.

### 2. `ColorIdentity` — `Shared/Card.swift`

Pure enum, no SwiftUI import (keeps `Shared` framework-agnostic):

```swift
public enum ColorIdentity: Sendable, Equatable {
    case white, blue, black, red, green, colorless, multicolor
}
```

Derivation rule (the design's non-negotiable "multicolor = gold"):

- `colors.count >= 2` → `.multicolor`
- `colors.count == 1` → that single color
- `colors.count == 0` → `.colorless` (lands, artifacts, generic costs)

Exposed as a computed `Card.identity` and stored on `Card.Mini`. The `DS` layer (in `QuickStudy`)
owns the `ColorIdentity → Color` tint mapping.

### 3. `Card.Mini` change (additive, no migration)

- Add `public let identity: ColorIdentity` to `Mini`.
- **Keep** the existing `Mini(id:name:)` init (identity defaults to `.colorless`) so
  `SearchEngineTests` compile and pass unchanged.
- Add `Mini(id:name:colors:)` that derives identity.
- `CardStore.loadMinis()` widens its query to `SELECT id, name, colors FROM cards`, decodes the
  existing JSON `colors`, and builds Minis with identity.

### 4. New reusable views

- **`ManaCostView`** — parses a cost string with the regex `\{([^}]+)\}` into tokens and renders a
  horizontal row of pips:
  - `W/U/B/R/G` → disc filled with that mana tint.
  - generic / numeric / `X` → colorless-tint disc.
  - `T` → glyph `↻`.
  - Each pip: pill shape, SF Mono bold, ink `#1A1714`, glyph ≈ 0.58× pip size, inset 0.5px ring.
  - **v1 simplification (flagged):** hybrid / Phyrexian tokens (`{B/R}`, `{W/P}`, `{2/U}`) render as
    a single colorless disc showing the inner text. Two-tone split pips are out of scope.
  - Replaces the raw monospace mana string in `CardPreview`.
- **`IdentityBadge`** — a small identity-tinted capsule (pill, footnote semibold, ink `#1A1714` on
  the tint) shown in the `CardPreview` header.
- **`IdentityPlaceholder`** — a mana-tinted gradient fill (the gold gradient for `.multicolor`) used
  wherever an image is missing: `Thumbnail` (radius 3) and `CardPreview`'s missing-image box
  (radius 12). **Real downloaded images keep rendering unchanged** — showing Scryfall images is the
  app's purpose; they only gain a 0.5px ring. (The design system's "never reproduce WOTC art" rule
  governs the *mock* placeholders, not the shipping app's legitimate Scryfall image display.)

### 5. Applying the system to existing views

- **`Thumbnail`** — accepts `identity`; missing image → `IdentityPlaceholder`; real image gains a
  0.5px ring. Callers (`ResultList`, `PinnedRow`) pass `mini.identity`.
- **`ResultList` / `PinnedRow`** — selection wash switches from `Color.accentColor.opacity(0.25)` to
  `DS.Color.selection` (and `selectionStrong` for the active row).
- **`CardPreview`** — `ManaCostView` for the cost; `IdentityBadge` in the header; `DS.Shadow.card`
  on the image; pin button tint → `DS.Color.accent`; missing image → `IdentityPlaceholder`.
- **`SearchPanel` / `DownloadPromptView`** — `.tint(DS.Color.accent)` at the root recolors
  ProgressViews, buttons, and banner icons to brand in one move; dividers use the separator token.
- **`BrandProminentButtonStyle`** — accent-gradient fill, applied only to primary actions
  (Download Everything, Update, the default action). Secondary buttons stay native `.bordered`.
- **`SettingsView`** — `.tint(DS.Color.accent)` so its switches and sliders adopt the brand accent.

## Data flow

`CardStore.loadMinis()` → `[Card.Mini]` (now with `identity`) → `SearchEngine` (unchanged ranking)
→ `AppModel.results` → `ResultList`/`PinnedRow` → `Thumbnail(identity:)`. The preview pane fetches
the full `Card` lazily (existing `NSCache` path) → `CardPreview` uses `card.identity` and
`card.manaCost`. No new async paths; no per-keystroke SQLite hits.

## Error handling / edge cases

- Empty / malformed `colors` JSON → `.colorless` (existing decode already falls back to `[]`).
- Empty mana cost or no `{…}` tokens → `ManaCostView` renders nothing.
- Unknown pip tokens → colorless disc with the literal text.
- Missing image → `IdentityPlaceholder` (never a crash, never a blank box).

## Testing

- **`ColorIdentityTests`** — golden cases: `["W","U"] → .multicolor`, `["R"] → .red`,
  `[] → .colorless`, `["W","U","B","R","G"] → .multicolor`.
- **`ManaCostParserTests`** — `{2}{W}{U}` → `["2","W","U"]`; hybrid `{B/R}` → single colorless disc
  token; `{T}` → tap glyph.
- **`SearchEngineTests`** — must stay green; guaranteed by the additive `Mini(id:name:)` init.

## Out of scope (YAGNI)

- Manual light/dark theme toggle (the app follows the OS).
- Licensed Keyrune / Scryfall mana-symbol font.
- Two-tone hybrid / Phyrexian pips.
- Animated panel transitions beyond the existing 0.08s scroll-to-selection.
