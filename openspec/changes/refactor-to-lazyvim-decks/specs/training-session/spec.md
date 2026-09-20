## Purpose

Manages training session lifecycle, dynamic session sizing, proportional spaced repetition queueing, and deck-relative progress, mastery, and celebration.

## ADDED Requirements

### Requirement: Dynamic Session Sizing
The system SHALL size training sessions to `min(24, eligible)` without dealing duplicate cards in the initial queue.

#### Scenario: Sizing a session for a large deck
- **WHEN** a deck contains 50 eligible cards
- **THEN** the session queue is sized to exactly 24 cards.

#### Scenario: Sizing a session for a small deck
- **WHEN** a deck contains 7 eligible cards
- **THEN** the session queue is sized to exactly 7 cards and no card appears twice in the initial deal.

#### Scenario: Refusing to start an empty deck
- **WHEN** the user attempts to start a session in a deck with zero eligible cards
- **THEN** starting is refused, the deck row shows zero cards, and a bounded hint directs the user to the browse-and-pick drawer.

### Requirement: Proportional Queue Allocation
The system SHALL scale the default 10/6/6/2 queue distribution (due, unseen, weak, maintenance) proportionally when session size is under 24 cards, allocating any remainder to due cards.

#### Scenario: Proportionally allocating cards for reduced session size
- **WHEN** a deck has 12 eligible cards and every queue holds enough candidates to satisfy its share
- **THEN** the session deals exactly 5 due, 3 unseen, 3 weak and 1 maintenance card.

#### Scenario: Reallocating an exhausted queue's share
- **WHEN** a queue holds fewer candidates than its proportional share allots
- **THEN** the unfilled remainder is reallocated to the due queue and no card is dealt twice.

### Requirement: Deck-Scoped Progress and Run Counters
The system SHALL record run completions, study duration, and coverage cursors per deck, while recording recall history per card independently of any deck.

#### Scenario: Completing a session in a specific deck
- **WHEN** a training session in deck `lsp` completes
- **THEN** the run count and study time for deck `lsp` increase, and no other deck's run count changes.

#### Scenario: Coverage cursor advances per deck
- **WHEN** consecutive sessions are run in deck `lsp` and then in deck `git`
- **THEN** each deck resumes dealing from its own coverage position rather than a shared one.

#### Scenario: Multi-deck card progress propagation
- **WHEN** a card belonging to both `all` and `nemesis` is answered correctly on its first try
- **THEN** mastery progress for that card is reflected immediately when querying either deck.

### Requirement: Per-Deck Completion and Celebration
The system SHALL trigger a deck celebration when all eligible cards in that deck achieve mastery status, without enforcing a minimum deck size requirement.

#### Scenario: Mastering all cards in a small deck
- **WHEN** the final unmastered card in a 5-card custom deck is mastered
- **THEN** the deck completion celebration triggers and is recorded in that deck's counter record.

### Requirement: Deck-Scoped Session Resume
The system SHALL scope interrupted session recovery state to the active deck ID.

#### Scenario: Resuming an active session
- **WHEN** the application restarts with an unfinished session in deck `git`
- **THEN** the session resumes with the exact remaining cards and score for deck `git`.

### Requirement: Non-Destructive Progress Migration
The system SHALL migrate existing per-profile counters to deck counters on first launch after the update, preserving all per-card recall history including entries recorded under retired training grounds.

#### Scenario: Existing LazyVim progress appears under the all deck
- **WHEN** a user upgrades with existing LazyVim run counts, study time and mastery recorded against the LazyVim profile
- **THEN** those counters appear against the `all` deck and no per-card recall history is lost.

#### Scenario: Retired ground history is retained but inert
- **WHEN** stored per-card history contains entries recorded under a retired training ground
- **THEN** those entries are retained unchanged, are never dealt, and are excluded from every displayed total.

#### Scenario: Counters for retired grounds are dropped
- **WHEN** stored counters exist for retired training ground profiles
- **THEN** those counter records are dropped while the LazyVim record is carried over to the `all` deck.
