# Flip Button for Double-Faced Cards — Design

**Date:** 2026-07-16
**Branch:** `feat/card-flip`

## Problem

Double-faced cards (e.g. *Sephiroth, Fabled SOLDIER // Sephiroth, One-Winged Angel*)
only ever show their front face in the card preview. The fetcher downloads
`card_faces[0]`'s image as `images/{id}.jpg`; the back face is never fetched, and
the app has no signal that a back face exists.

Only ~500 cards in the current dataset (401 `transform` + 100 `modal_dfc`) have a
distinct back-face image once tokens and art series are filtered out — roughly
60 MB of one-time downloads.

## Decision summary

- **Image source:** the fetcher downloads back faces during the images phase
  (chosen over on-demand streaming from the app).
- **UI:** a rotate icon button overlaid at the top-right corner of the card image
  in `CardPreview`, shown only when a back-face image exists on disk.
- **Animation:** Y-axis 3D flip (`rotation3DEffect`), image swapped at the 90°
  midpoint.
- **No DB migration.** Presence of `images/{id}_back.jpg` on disk is the entire
  state, matching the existing `Card.imagePath` / `art/` convention.

## Fetcher changes (`Sources/Fetcher`, `Sources/Shared`)

- `Paths` (Shared) gains `backImageURL(forCardID:) -> URL` returning
  `imagesDir/{id}_back.jpg`, so both executables agree on the filename.
- `CardImageRef` gains an optional `backImageURL: String?`.
- Ref extraction (`ScryfallClient`) also reads `card_faces[1].image_uris.normal`,
  but only for true DFCs: cards whose faces carry their own `image_uris`
  (`transform` / `modal_dfc`). Split, adventure, prepare, and flip layouts have a
  single top-level image and get no back ref. Token/art-series layouts are
  already filtered out before this point.
- `ImageDownloader` downloads the back image to `images/{id}_back.jpg` alongside
  the front, with the same idempotent skip-if-on-disk behavior. The DB's
  `image_path` column is untouched (it continues to describe the front image
  only). Progress totals count files, so back faces are reflected in the
  existing NDJSON `images` phase — no protocol change.

## App changes (`Sources/QuickStudy/Views/CardPreview.swift`)

- When the previewed card changes, check `FileManager.fileExists` for
  `Paths.backImageURL(forCardID:)`. If present, overlay a rotate icon button
  (SF Symbol, circular-arrow style) at the top-right corner of the card image.
- Clicking the button (or pressing `⌘F`) toggles between faces with a Y-axis 3D
  flip; the displayed image swaps at the 90° midpoint so the motion reads like
  turning a physical card.
- The back image loads through the same `ThumbnailCache` + off-main-thread
  decode path as the front, under cache key `{id}_back`.
- Flip state resets to the front face whenever the selection changes.
- Name, oracle text, mana cost, and printings are untouched — they already
  render both faces (joined with `//`).

## Out of scope

- Flipping thumbnails in result lists / recently-added rows.
- Per-printing back faces.
- Split / adventure / flip layouts (single-faced; one image holds both halves).
- Any DB schema change.

## Error handling

- Missing back file (refresh not yet run): button simply doesn't render.
- Failed back-face download: fetcher's existing silent-skip-and-retry-next-refresh
  behavior applies; the app just keeps showing no button for that card.
- Back image fails to decode: the flip shows the existing `IdentityPlaceholder`,
  same as a missing front image.

## Verification

1. Run a refresh from the installed build; confirm the images phase downloads
   the new `_back.jpg` files and a second refresh skips them.
2. Search "Sephiroth" → rotate button appears → flip shows One-Winged Angel;
   flip back; switch selection and return — front face shows again.
3. Single-faced card (e.g. "Blood Crypt"): no button.
4. Split card ("Fire // Ice") and adventure card: no button.
5. `swift test` stays green (SearchEngine golden cases unaffected).
