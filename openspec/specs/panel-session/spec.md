# panel-session Specification

## Purpose
TBD - created by archiving change baseline-capabilities. Update Purpose after archive.
## Requirements
### Requirement: Menu-bar application without Dock presence

The system SHALL run as a menu-bar accessory application with no Dock icon and no main application window. The application SHALL be activated and presented via a borderless floating HUD panel rather than a standard window.

#### Scenario: No Dock icon at launch
- **WHEN** the application launches
- **THEN** no Dock icon appears for it and no main window is presented automatically

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

