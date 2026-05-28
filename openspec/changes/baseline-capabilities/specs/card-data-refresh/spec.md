## ADDED Requirements

### Requirement: Refresh runs as an out-of-process subprocess

The system SHALL perform bulk card data refresh by spawning a separate `mtg-fetcher` executable as a subprocess. The main application SHALL NOT parse bulk card JSON in-process.

The system SHALL resolve the subprocess executable in this order:
1. The path specified by the `MTG_FETCHER_PATH` environment variable, when set.
2. A sibling named `mtg-fetcher` in the same directory as the running main executable (covers both the `.app` bundle layout and direct `swift run` invocations).

When no executable can be resolved, the system SHALL emit an `error` phase event with a message indicating the binary was not found, and SHALL NOT mark the refresh as successful.

#### Scenario: Environment override takes precedence
- **WHEN** `MTG_FETCHER_PATH` is set and points to an executable file
- **THEN** the subprocess is launched from that path regardless of the bundle layout

#### Scenario: Missing binary surfaces an error event
- **WHEN** no executable can be resolved
- **THEN** the refresh state ends in error with a message stating the fetcher was not found

### Requirement: Four-phase progress protocol over NDJSON

The system SHALL stream subprocess progress as newline-delimited JSON events on stdout, one event per line. Each event SHALL be a JSON object with at least the `phase` field, optionally including `done`, `total`, and `message`:

```
{"phase":"<phase>","done":<int|null>,"total":<int|null>,"message":<string|null>}
```

The `phase` field SHALL take one of these values during a normal run, in order:
1. `start` — emitted once when the subprocess begins.
2. `json` — emitted while fetching the bulk-data index and downloading the bulk JSON file.
3. `ingest` — emitted with `done` and `total` set to row counts while upserting cards into SQLite in batches.
4. `images` — emitted with `done` and `total` set to image counts while downloading card images, unless image download is skipped.
5. `done` — emitted once on successful completion.

On any unrecoverable failure during any phase, the system SHALL emit an `error` phase event with a `message` describing the failure and SHALL exit with a non-zero status. The application SHALL also emit an `exit` phase event in the receiving process when the subprocess terminates regardless of success or failure.

#### Scenario: Successful refresh emits start → json → ingest → images → done
- **WHEN** the subprocess completes a full refresh without errors and image download is not skipped
- **THEN** the receiver observes events in the order start, json (one or more), ingest (one or more, with done advancing toward total), images (one or more, with done advancing toward total), done, exit

#### Scenario: Error event ends the run
- **WHEN** any phase fails
- **THEN** an event with `phase: "error"` and a descriptive `message` is emitted and the subprocess exits non-zero

### Requirement: Image download can be skipped

The system SHALL support a `--no-images` command-line flag on the subprocess. When set, the subprocess SHALL skip the image download phase entirely and emit `done` immediately after ingest completes.

#### Scenario: --no-images skips the images phase
- **WHEN** the subprocess is invoked with `--no-images`
- **THEN** no `images` phase events are emitted and the run transitions directly from `ingest` to `done`

### Requirement: Idempotent and resumable ingest and image download

The system SHALL upsert ingested cards using insert-or-update semantics keyed by card identity, so that re-running a refresh against an unchanged or partially-updated database does not produce duplicate rows or fail on existing rows.

The system SHALL skip image downloads for images that already exist on disk, so that a re-run after an interrupted run downloads only the missing images.

#### Scenario: Re-running a completed refresh succeeds
- **WHEN** a refresh is run twice consecutively against the same bulk data
- **THEN** the second run completes successfully without errors and without producing duplicate rows in the card store

#### Scenario: Re-running after an interrupted image phase downloads only the missing files
- **WHEN** a refresh is interrupted partway through the `images` phase and re-run
- **THEN** the second run skips images already on disk and downloads only the remainder

### Requirement: Refresh metadata is recorded

The system SHALL record, on every successful ingest, a `last_refresh` timestamp (ISO-8601) and a `bulk_updated_at` value sourced from the upstream bulk-data index, in the card store's meta table.

#### Scenario: Successful refresh updates metadata
- **WHEN** the ingest phase completes successfully
- **THEN** the meta table contains a `last_refresh` ISO-8601 timestamp and a `bulk_updated_at` value from the bulk-data index

### Requirement: Receiver is a streaming line-decoder

The system SHALL read subprocess stdout incrementally, split the byte stream on the newline character, and decode each line as a JSON event independently, so that progress is observable before the subprocess terminates.

The system SHALL discard lines that fail to decode as a valid event without aborting the run.

#### Scenario: Events appear before the subprocess exits
- **WHEN** the subprocess is mid-run and has flushed a progress line
- **THEN** the receiver decodes and forwards that line as an event before the subprocess exits

#### Scenario: Malformed line is ignored
- **WHEN** the subprocess emits a stdout line that does not decode as a valid event
- **THEN** the receiver discards that line and continues processing subsequent lines
