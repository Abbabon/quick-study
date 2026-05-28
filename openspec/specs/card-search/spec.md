# card-search Specification

## Purpose
TBD - created by archiving change baseline-capabilities. Update Purpose after archive.
## Requirements
### Requirement: In-memory ranked search over loaded cards

The system SHALL evaluate every search query against an in-memory collection
of `Card.Mini` rows loaded once at startup, without issuing a SQLite query
per keystroke. The system SHALL return at most `limit` results (default 20)
ranked best-first.

The system SHALL trim leading and trailing whitespace from the query and lower-case it before matching. The system SHALL return an empty result set for an empty or whitespace-only query.

#### Scenario: Empty query yields no results
- **WHEN** the trimmed query is the empty string
- **THEN** the search returns an empty result list and performs no ranking work

#### Scenario: Query is matched case-insensitively
- **WHEN** the query "BOLT" is entered against a corpus containing "Lightning Bolt"
- **THEN** "Lightning Bolt" appears in the result list

### Requirement: Layered scoring with stable tier ordering

The system SHALL classify each candidate card into exactly one of five scoring tiers, evaluated in this order, with higher tiers ranking strictly above lower tiers regardless of length bonus:

1. Exact match (case-insensitive equality with the query).
2. Prefix match (name starts with the query).
3. Token-start match (the query, possibly multi-word, matches the start of consecutive whitespace-separated tokens in the name; for single-word queries, matches the start of a non-first token).
4. Substring match (name contains the query as a contiguous substring).
5. Subsequence / initials match (every character of the query appears in the name in order, not necessarily contiguous).

Cards that do not satisfy any tier SHALL be excluded from the result list.

Within tiers 1, 2, and 4, the system SHALL apply a length bonus that increases the score for shorter names, so that on ambiguous queries a shorter exact-or-prefix-or-substring match outranks a longer one in the same tier. Within tier 5, a tighter (more contiguous) spread of matched characters SHALL outrank a looser one.

#### Scenario: Exact match beats prefix match
- **WHEN** the query is "bolt" and the corpus contains both "Bolt" and "Bolt of Thunder"
- **THEN** "Bolt" ranks above "Bolt of Thunder"

#### Scenario: Prefix match beats token-start match
- **WHEN** the query is "light" and the corpus contains both "Lightning" and "Bolt of Light"
- **THEN** "Lightning" ranks above "Bolt of Light"

#### Scenario: Token-start match beats arbitrary substring
- **WHEN** the query is "bolt" and the corpus contains "Lightning Bolt" and "Boltsmith's Forge"
- **THEN** "Boltsmith's Forge" (prefix tier) ranks above "Lightning Bolt" (token-start tier)

#### Scenario: Length bonus favors shorter name within the same tier
- **WHEN** the query is "bolt" and the corpus contains "Bolt" and "Boltsmith"
- **THEN** "Bolt" ranks above "Boltsmith"

#### Scenario: Initials match is reachable but ranks lowest
- **WHEN** the query is "ljt" and the corpus contains a card whose name has those characters as a subsequence
- **THEN** that card appears in the result list, ranked below any card matching a higher tier

#### Scenario: Non-matching card is excluded
- **WHEN** the query characters cannot be found in a candidate name even as a subsequence
- **THEN** that card does not appear in the result list at any score

### Requirement: Performance target

The system SHALL be capable of ranking the entire loaded corpus (approximately 25,000 cards) against a single query in under one millisecond on the developer's reference hardware, so that no debouncing is needed between keystrokes.

#### Scenario: No debounce required between keystrokes
- **WHEN** the user types multiple characters in rapid succession
- **THEN** the search runs synchronously per keystroke without explicit debouncing logic

### Requirement: Result corpus is reloaded from the card store

The system SHALL load the searchable corpus from the `CardStore` once when the database is in the ready state, and SHALL reload it after a successful card-data refresh.

#### Scenario: Corpus reloads after a successful refresh
- **WHEN** a card-data refresh transitions the database state to ready
- **THEN** subsequent searches use the updated corpus

