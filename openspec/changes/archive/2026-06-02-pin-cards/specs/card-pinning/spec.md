## ADDED Requirements

### Requirement: Pin and unpin the previewed card

The system SHALL allow the user to pin the currently-previewed card to a persistent pinned set via a control in the preview pane and via the in-panel keyboard shortcut **⌘P**. The control SHALL toggle: invoking it on an unpinned card pins it, and invoking it on an already-pinned card unpins it. The preview-pane control SHALL visually reflect whether the currently-previewed card is pinned. When no card is currently previewed, the pin action SHALL be a no-op.

#### Scenario: Pinning the previewed card

- **WHEN** a card is previewed and is not yet pinned, and the user activates the preview-pane pin control or presses ⌘P
- **THEN** the card is added to the pinned set and the preview-pane control reflects the pinned state

#### Scenario: Toggling off an already-pinned card

- **WHEN** the previewed card is already pinned and the user activates the pin control or presses ⌘P
- **THEN** the card is removed from the pinned set

#### Scenario: Pin action with nothing previewed

- **WHEN** no card is currently previewed and the user presses ⌘P
- **THEN** the pinned set is unchanged

### Requirement: Persistent pinned bottom row

The system SHALL display the pinned cards in a row at the bottom of the panel. The pinned row SHALL be shown whenever the card database is ready and at least one card is pinned, regardless of the current search query or result list — including when the query is empty or produces no matches. Each entry SHALL show the card's thumbnail and name. The entry corresponding to the currently-previewed card SHALL be visually highlighted. The pinned row SHALL preserve the order in which cards were pinned.

#### Scenario: Pinned row visible with empty query

- **WHEN** at least one card is pinned and the search query is empty
- **THEN** the pinned row remains visible with all pinned cards

#### Scenario: Pinned row visible with no matches

- **WHEN** at least one card is pinned and the current query produces no results
- **THEN** the pinned row remains visible with all pinned cards

#### Scenario: No pinned row when nothing is pinned

- **WHEN** no cards are pinned
- **THEN** no pinned row is displayed

#### Scenario: Pinned entry tracks the current preview

- **WHEN** the currently-previewed card is also present in the pinned row
- **THEN** that pinned entry is highlighted

### Requirement: Clicking a pinned card previews it

The system SHALL change the main preview to show a pinned card when the user clicks that card's entry in the pinned row, loading its full detail the same way a search-result selection does.

#### Scenario: Click swaps the preview

- **WHEN** the user clicks a pinned card's entry in the pinned row
- **THEN** the main preview updates to show that card's detail and that entry becomes highlighted

### Requirement: Per-entry unpin control

The system SHALL provide an always-visible unpin control on each pinned entry that removes only that card from the pinned set, independent of the preview-pane toggle and the ⌘P shortcut.

#### Scenario: Removing a single pinned card

- **WHEN** the user activates the unpin control on a specific pinned entry
- **THEN** only that card is removed from the pinned set and the remaining pinned cards keep their order

### Requirement: Pins persist across restarts

The system SHALL persist the pinned set so that it survives quitting and relaunching the application. On launch, the system SHALL restore the previously pinned cards, in their original order, into the pinned row without requiring a new search.

#### Scenario: Pins restored on relaunch

- **WHEN** one or more cards are pinned, the application is quit, and then relaunched
- **THEN** the same cards appear in the pinned row in the same order

#### Scenario: Unpin persists

- **WHEN** a pinned card is unpinned and the application is later relaunched
- **THEN** that card does not reappear in the pinned row
