# image-cache Specification

## Purpose
TBD - created by archiving change baseline-capabilities. Update Purpose after archive.
## Requirements
### Requirement: Local image storage in Application Support

The system SHALL persist downloaded card images as regular files in a dedicated images directory under the application's Application Support folder. The card-data-refresh subprocess SHALL write into this directory; the application UI SHALL read from it.

#### Scenario: Images directory is under Application Support
- **WHEN** an image is downloaded by the refresh subprocess
- **THEN** the file is stored under the QuickStudy Application Support directory in the configured images subdirectory

### Requirement: Measure on-disk size of the image directory

The system SHALL expose an operation that returns the total size in bytes of all regular files directly contained in the images directory, excluding hidden files. The operation SHALL return zero when the directory does not exist.

#### Scenario: Empty or missing directory reports zero
- **WHEN** the images directory does not exist or contains no regular files
- **THEN** the reported total size is zero bytes

#### Scenario: Reported size sums regular file sizes
- **WHEN** the images directory contains a set of regular files with known sizes
- **THEN** the reported total equals the sum of those file sizes

### Requirement: Clear the image directory while preserving the directory

The system SHALL expose an operation that deletes every regular file directly contained in the images directory and returns the total bytes freed. The directory itself SHALL be preserved so that subsequent refreshes can write into it without recreating it. The clear operation SHALL be a no-op (returning zero) when the directory does not exist.

#### Scenario: Clear removes files but keeps the directory
- **WHEN** the clear operation runs on a non-empty images directory
- **THEN** every regular file directly inside the directory is removed, the directory itself still exists, and the returned byte count equals the freed bytes

#### Scenario: Clear on missing directory is a no-op
- **WHEN** the clear operation runs and the images directory does not exist
- **THEN** the operation returns zero and produces no error

### Requirement: Clear-cache UI gated on idle refresh state

The system SHALL expose a user-facing control in Settings that triggers the clear operation and refreshes the displayed cache size. The control SHALL be available only while no card-data refresh is in progress, to prevent clearing files concurrent with the subprocess writing to the same directory.

#### Scenario: Clear control is disabled during a refresh
- **WHEN** a card-data refresh is in progress
- **THEN** the clear-cache control is not actionable

#### Scenario: Clear control updates the displayed size after running
- **WHEN** the user activates the clear control while idle
- **THEN** the images directory is cleared and the Settings UI updates the displayed cache size to reflect the new total

