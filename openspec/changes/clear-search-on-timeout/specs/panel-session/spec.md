## ADDED Requirements

### Requirement: Idle timeout clears search state on reopen

The system SHALL clear the current search state — including the query string, the selected card ID, the selected card detail, and the result list — when the panel is shown after having been hidden for longer than the configured timeout.

The system SHALL preserve the search state across show/hide cycles whose elapsed hidden time is shorter than the configured timeout.

The elapsed hidden time SHALL be measured against the timestamp of the most recent panel hide. Before the panel has ever been hidden within the current app process, the system SHALL NOT clear the search state on show.

#### Scenario: Reopening after timeout clears state
- **WHEN** the panel has been hidden for longer than the configured timeout and the user invokes the global hotkey to show it again
- **THEN** the query field is empty, no result is selected, no card detail is shown, and the result list is empty before the panel becomes visible to the user

#### Scenario: Reopening within the timeout preserves state
- **WHEN** the panel is hidden and reopened within an interval shorter than the configured timeout
- **THEN** the query, selected card ID, selected card detail, and result list are unchanged from when the panel was last visible

#### Scenario: First show in the app session does not clear state
- **WHEN** the panel is shown for the first time after app launch and has never been hidden
- **THEN** the system does not invoke the search-state reset

### Requirement: Timeout duration is user-configurable

The system SHALL expose the idle-clear timeout as a user setting in the Settings window under the Behavior section. The setting SHALL be persisted across app restarts using the standard application preferences store.

The setting SHALL offer a fixed set of preset durations including an explicit "Never" option that disables the clear-on-timeout behavior. The default value SHALL be 60 seconds.

When the setting is configured to the "Never" option, the system SHALL NOT clear the search state on any show event, regardless of how long the panel was hidden.

#### Scenario: Default value applies on first launch
- **WHEN** the user opens Settings without ever having changed the clear-search timeout
- **THEN** the selected duration is 60 seconds

#### Scenario: "Never" disables the clear behavior
- **WHEN** the user selects the "Never" option and later reopens the panel after an arbitrarily long hidden interval
- **THEN** the query, selected card ID, and result list are unchanged from when the panel was last visible

#### Scenario: Updated setting takes effect on the next show
- **WHEN** the user changes the timeout to a new preset and subsequently hides then reopens the panel
- **THEN** the show event uses the newly chosen value when deciding whether to clear the search state

### Requirement: Reset is internal to the panel lifecycle

The system SHALL clear the search state as part of the panel show flow, before the panel is presented as the key window to the user. The reset SHALL NOT introduce any change to the fetcher subprocess, the SQLite card store, the search engine's loaded card corpus, or the on-disk image cache.

#### Scenario: Reset does not touch persistent storage
- **WHEN** the system clears the search state because the timeout has elapsed
- **THEN** the card database, the image cache directory, and the loaded search engine corpus are unchanged
