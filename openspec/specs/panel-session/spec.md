# panel-session Specification

## Purpose
TBD - created by archiving change baseline-capabilities. Update Purpose after archive.
## Requirements
### Requirement: Dock app that also lives in the menu bar

The system SHALL run as a regular application with a Dock icon (`LSUIElement` is false and the app sets the `.regular` activation policy at launch) and SHALL also provide a menu-bar item. The search UI SHALL be presented via a borderless floating HUD panel rather than a standard window, and no main application window SHALL be presented automatically at launch.

#### Scenario: Dock icon and menu-bar item at launch
- **WHEN** the application launches
- **THEN** a Dock icon appears, the menu-bar item is available, and no main window is presented automatically

### Requirement: Global hotkey toggles panel visibility

The system SHALL register a user-configurable global keyboard shortcut that toggles the panel: pressing the shortcut while the panel is hidden SHALL show it; pressing it while the panel is visible SHALL hide it.

#### Scenario: Hotkey shows the panel when hidden
- **WHEN** the panel is not visible and the user invokes the global shortcut
- **THEN** the panel becomes visible and key

#### Scenario: Hotkey hides the panel when visible
- **WHEN** the panel is visible and the user invokes the global shortcut
- **THEN** the panel is dismissed from the screen

### Requirement: Borderless non-activating HUD panel chrome

When shown, the panel SHALL be a borderless, non-activating floating panel with a translucent HUD-style background (vibrancy material `.hudWindow`, blending behind the window) and rounded corners. The panel SHALL float above standard application windows, SHALL be available across all spaces, SHALL appear over full-screen apps as an auxiliary panel, and SHALL be transient (not retained in the window cycle).

The panel SHALL accept key-window status so its embedded text field receives keystrokes, but SHALL NOT become the main window.

#### Scenario: Panel renders as a translucent HUD
- **WHEN** the panel is visible
- **THEN** it has no title bar, has rounded corners, uses a translucent HUD background, and casts a shadow

#### Scenario: Panel coexists with full-screen apps
- **WHEN** the user invokes the panel while a full-screen application is active
- **THEN** the panel appears above the full-screen application as an auxiliary panel

### Requirement: Panel is centered and clamped to the active screen

The system SHALL position the panel horizontally centered on, and vertically biased toward the upper portion of, the active screen's visible frame. The system SHALL clamp the panel's origin so that the entire panel remains within the screen's visible frame, even on screens smaller than the panel's natural size or with menu-bar / dock insets.

#### Scenario: Panel centers on the active screen
- **WHEN** the panel is shown on a screen large enough to contain it
- **THEN** the panel is horizontally centered and vertically positioned in the upper portion of the visible frame

#### Scenario: Panel stays on-screen on small displays
- **WHEN** the active screen's visible frame is smaller than the panel's natural position would require
- **THEN** the panel origin is clamped so that the panel remains fully within the visible frame

### Requirement: Panel dismissal paths

The system SHALL dismiss the panel in each of these cases:
- The user presses Escape while the panel is key.
- The panel resigns key status because the user clicks outside it.
- The user invokes the global hotkey while the panel is visible.

When the panel is dismissed, the system SHALL record the dismissal timestamp so other capabilities (e.g., session reset on idle) can measure elapsed hidden time.

#### Scenario: Escape dismisses the panel
- **WHEN** the panel is key and the user presses Escape
- **THEN** the panel is dismissed

#### Scenario: Clicking outside the panel dismisses it
- **WHEN** the panel is visible and the user clicks on another application or the desktop
- **THEN** the panel resigns key and is dismissed

### Requirement: Panel rebuild on UI scale change

The system SHALL rebuild the panel when the user-selected UI scale changes between hides, so that the next show reflects the new scale. The system SHALL NOT rebuild the panel when the scale is unchanged.

#### Scenario: Scale change between shows rebuilds the panel
- **WHEN** the UI scale setting differs from the scale used to build the existing panel
- **THEN** the next show discards the existing panel and constructs a new one at the current scale

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
