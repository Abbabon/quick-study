# card-detail Specification

## Purpose
TBD - created by archiving change baseline-capabilities. Update Purpose after archive.
## Requirements
### Requirement: Lazy detail fetch for the selected result

The system SHALL load the full card detail (beyond the `Card.Mini` projection used for ranking) only when a result becomes selected, by reading from the persistent card store. The system SHALL NOT load full card details for non-selected results.

#### Scenario: Selecting a result loads its detail
- **WHEN** a result row becomes the selected result
- **THEN** the system loads its full card record from the persistent card store and exposes it to the UI

#### Scenario: Non-selected results do not trigger a detail fetch
- **WHEN** the search produces a list of results
- **THEN** the system does not fetch full card details for results other than the selected one

### Requirement: Detail cache for repeated selection

The system SHALL cache full card details in memory keyed by card ID. On a subsequent selection of a previously loaded card, the system SHALL serve the cached detail without re-reading from the persistent store.

#### Scenario: Re-selecting a previously viewed card uses the cache
- **WHEN** a card that has already been loaded once during the current app session is selected again
- **THEN** the system serves its detail from the in-memory cache without issuing a new store read

### Requirement: Selection follows the result list

The system SHALL select the first result automatically when a new search produces results and either no result was previously selected or the previously selected result is no longer in the new result list. The system SHALL clear the selection when the result list becomes empty.

The system SHALL support advancing the selection to the next or previous result, clamped to the bounds of the result list (no wrap-around).

#### Scenario: First result is selected on new query
- **WHEN** a new search produces results and the previous selection is absent from the new list
- **THEN** the first result becomes selected

#### Scenario: Empty result list clears the selection
- **WHEN** a search produces no results
- **THEN** the selected card ID and selected card detail are both cleared

#### Scenario: Selecting next at the end of the list stays at the end
- **WHEN** the last result is selected and the user advances the selection
- **THEN** the selection remains on the last result

#### Scenario: Selecting previous at the start of the list stays at the start
- **WHEN** the first result is selected and the user moves the selection back
- **THEN** the selection remains on the first result

