## Purpose

Defines user-authored and starter deck collections, managing declarative configuration, closed-vocabulary seeds, interactive card curation deltas, and state reconciliation.

## ADDED Requirements

### Requirement: Declarative Deck Configuration Reading
The system SHALL read deck declarations from `~/.config/omarchy/keycade-lazyvim/decks.json` using descriptor-relative `O_NOFOLLOW` traversal and enforce dual-ended boundary limits.

#### Scenario: Successfully loading valid decks configuration
- **WHEN** `decks.json` is present with `schemaVersion` 1 and three well-formed deck definitions
- **THEN** those three decks are offered for training in the order the file lists them.

#### Scenario: Rejecting decks beyond the declared cap
- **WHEN** `decks.json` declares 40 decks
- **THEN** the first 32 are accepted, the remainder are rejected and counted, and training is not blocked.

#### Scenario: Rejecting a malformed deck identifier
- **WHEN** a deck declares an `id` that does not match `^[a-z][a-z0-9-]{0,31}$`
- **THEN** that deck is rejected and counted, and the remaining valid decks still load.

#### Scenario: Rejecting a duplicate deck identifier
- **WHEN** two decks declare the same `id`
- **THEN** the first declaration is kept, the later duplicate is rejected and counted.

#### Scenario: Fallback when decks configuration is absent
- **WHEN** `decks.json` does not exist on disk
- **THEN** the system activates the shipped starter decks: the reserved `all` deck plus four starters seeded on navigation, LSP and diagnostics, search and find, and git categories.

#### Scenario: Resilience to malformed decks configuration
- **WHEN** `decks.json` contains malformed JSON
- **THEN** the system falls back to the reserved `all` deck, surfaces the reason to the user, and still allows training to start.

### Requirement: Reserved All Deck
The system SHALL maintain a reserved, undeletable `all` deck that contains every eligible card in the corpus, ignores any declared seed, and is presented first in the deck list.

#### Scenario: Querying the all deck
- **WHEN** the user selects the `all` deck
- **THEN** the deck evaluates to the entire eligible corpus without applying category or extra constraints.

#### Scenario: User redeclares the reserved deck
- **WHEN** `decks.json` declares a deck with `id` `all` carrying both a `name` and a `seed`
- **THEN** the declared name is honoured, the seed is ignored, and the deck still contains the entire eligible corpus.

### Requirement: Declared Decks Replace Shipped Starters
The system SHALL treat a present `decks.json` as the complete deck list, replacing the shipped starter decks entirely rather than merging with them.

#### Scenario: Declared decks replace starters
- **WHEN** `decks.json` is present and declares two decks
- **THEN** the deck list offers exactly those two decks plus the reserved `all`, and no shipped starter deck appears.

### Requirement: Deck List Presentation
The system SHALL present decks as a list ordered by their declaration order with `all` first, showing each deck's name and its current card count.

#### Scenario: Deck row reports a shrunken seed
- **WHEN** an extra is switched off in `lazyvim.json` and a deck seeded on that extra loses cards
- **THEN** that deck's row shows the reduced card count.

### Requirement: Dynamic Seed Evaluation
The system SHALL evaluate deck contents dynamically in memory as `seed(corpus) ∪ added − removed` against closed seed vocabularies for categories, extras, and contexts.

#### Scenario: Evaluating category seed
- **WHEN** a deck declares `seed: { categories: ["lsp", "diagnostics"] }`
- **THEN** all active corpus cards matching those categories are included in the computed deck.

#### Scenario: Evaluating extras seed
- **WHEN** a deck declares `seed: { extras: ["lazyvim.plugins.extras.editor.harpoon2"] }`
- **THEN** only active corpus cards provided by that extra are included in the computed deck.

#### Scenario: Evaluating an unseeded hand-curated deck
- **WHEN** a deck declares no seed object
- **THEN** the deck contains only the cards explicitly enumerated in the user's `added` list.

#### Scenario: Rejecting a seed value outside the pack vocabulary
- **WHEN** a deck declares `seed: { categories: ["telepathy"] }` and the loaded pack declares no such category
- **THEN** the value is rejected and counted rather than silently matching nothing.

#### Scenario: Ignoring unrecognised declaration keys
- **WHEN** a deck declaration carries a key the schema does not define
- **THEN** the key is ignored and counted, and the rest of the deck still loads.

### Requirement: Persistent Membership Deltas
The system SHALL persist manual additions and removals in `settings.json` under `deckCards` using atomic file writes bounded to a 24 KiB sub-budget.

#### Scenario: Manually adding a card to a deck
- **WHEN** a user assigns a card not matched by the seed to a deck
- **THEN** the card ID is recorded in `deckCards[deckId].added` in `settings.json`.

#### Scenario: Manually pruning a seeded card from a deck
- **WHEN** a user removes a card that matches the deck's seed
- **THEN** the card ID is recorded in `deckCards[deckId].removed` in `settings.json` and excluded from the computed deck.

#### Scenario: Addition refused at the state cap
- **WHEN** an addition would carry the persisted membership deltas past their storage cap
- **THEN** the addition is refused, a bounded message is surfaced to the user, and the stored deltas are unchanged.

### Requirement: Browse-and-Pick Curation Surface
The system SHALL provide an in-app drawer for browsing the corpus with filter chips and a deck-focused target selector.

#### Scenario: Filtering cards by category chip
- **WHEN** the user selects the `git` filter chip in the browse-and-pick drawer
- **THEN** only corpus cards belonging to the git category are displayed.

#### Scenario: Toggling card membership for selected deck
- **WHEN** the user targets deck `nemesis` in the drawer and activates the membership toggle on a card row
- **THEN** the card is recorded in that deck's additions and the row reports the card as a member.

#### Scenario: Row reports membership in other decks
- **WHEN** a card already belongs to decks `lsp` and `all` while the drawer targets deck `nemesis`
- **THEN** the row indicates the other decks the card belongs to without changing the toggle's target.

### Requirement: Non-Destructive State Reconciliation
The system SHALL preserve membership deltas for decks or cards that are temporarily absent from configuration, and SHALL prune stored deck counter records deterministically when they exceed their cap.

#### Scenario: Deck restored after temporary deletion
- **WHEN** a deck is removed from `decks.json` and subsequently re-added with the same ID
- **THEN** the deck immediately regains its previously saved additions and removals.

#### Scenario: Delta names a card no longer in the corpus
- **WHEN** a stored addition names a card that the current corpus no longer provides
- **THEN** the entry is retained in state, is not offered for training, and does not count toward the deck's card total.

#### Scenario: Stored deck counter records exceed their cap
- **WHEN** stored deck counter records exceed the supported maximum on load
- **THEN** orphan records are pruned deterministically by deck id and the decks currently declared keep their counters.

### Requirement: Deck Name Sanitization
The system SHALL strip control, bidirectional and terminal escape sequences from deck names, bound them to 48 characters, and render them as plain text.

#### Scenario: Deck name carrying terminal control sequences
- **WHEN** a deck name contains ANSI escape sequences or bidirectional override characters
- **THEN** those sequences are stripped and the remaining plain text is displayed without affecting surrounding layout.

#### Scenario: Deck name exceeding the length bound
- **WHEN** a deck name is longer than 48 characters
- **THEN** the name is truncated to the bound before it is stored or displayed.

### Requirement: Independent Consumer Re-Validation
The system SHALL re-validate deck declarations against every documented bound in the consuming application, independently of the bounds already applied by the configuration reader.

#### Scenario: Reader output violates a documented bound
- **WHEN** the deck payload reaching the consumer exceeds a documented count, length or vocabulary bound
- **THEN** the offending deck or field is rejected by the consumer before it is retained or displayed.
