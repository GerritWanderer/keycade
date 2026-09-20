## Purpose

Provides the single, authoritative LazyVim shortcut card supply by loading the compiled pack, gating cards against active extras, ingesting static keymaps overrides, and evaluating answers in text sequence mode.

## ADDED Requirements

### Requirement: Compiled Pack Loading
The system SHALL load the built-in LazyVim keybinding pack from static application assets without making network requests or invoking external interpreters.

#### Scenario: Startup pack compilation
- **WHEN** the application starts up
- **THEN** the LazyVim card pack is loaded into memory with all core shortcuts available and card IDs prefixed with `lazyvim/`.

### Requirement: Extras Activation Gating
The system SHALL evaluate each card's required extras against the active configuration in `lazyvim.json`, marking any card whose provider is not enabled as disabled.

#### Scenario: Extra not enabled
- **WHEN** a card requires `lazyvim.plugins.extras.editor.harpoon2` and that extra is not present in `lazyvim.json`
- **THEN** the card is marked as disabled and excluded from the active training corpus.

#### Scenario: Extra enabled
- **WHEN** a card requires `lazyvim.plugins.extras.editor.harpoon2` and that extra is present in `lazyvim.json`
- **THEN** the card is marked as active and included in the active training corpus.

### Requirement: Static User Keymap Ingestion
The system SHALL statically extract user-defined keybindings from `lua/config/keymaps.lua` using strict grammar parsing without executing the Lua file, assigning custom entries to `category: "misc"`.

#### Scenario: Ingesting new custom keybinding
- **WHEN** `lua/config/keymaps.lua` defines `vim.keymap.set("n", "<leader>u", "<cmd>UndotreeToggle<cr>", { desc = "Toggle Undo Tree" })`
- **THEN** a new card with `localId: "normal/<leader>u"`, `desc: "Toggle Undo Tree"`, and `customKind: "added"` is synthesized into the corpus.

#### Scenario: Ingesting override of existing shortcut
- **WHEN** `lua/config/keymaps.lua` defines a mapping matching an existing LazyVim card notation
- **THEN** the card replaces the default description and is marked with `customKind: "changed"`.

#### Scenario: Static deletion of packaged shortcut
- **WHEN** `lua/config/keymaps.lua` explicitly deletes a packaged mapping via `vim.keymap.del`
- **THEN** the corresponding card is absent from the training corpus and the count of deleted mappings reported to the user increases by one.

### Requirement: Exclusion-Based Eligibility Filtering
The system SHALL apply user exclusions before any deck seed evaluation, hiding an excluded card from every deck including the reserved `all` deck. Per-deck removal is a separate mechanism: a card removed from one deck remains eligible in every other deck it belongs to.

#### Scenario: Excluded card absent from every deck
- **WHEN** the user has excluded a card and opens any deck, including `all`
- **THEN** the card is absent from the deck and from the deck's displayed card count.

#### Scenario: Per-deck removal leaves the card eligible elsewhere
- **WHEN** a card is removed from the deck `lsp` but is not excluded
- **THEN** the card remains eligible in every other deck it belongs to, including `all`.

### Requirement: Leader and Localleader Calibration
The system SHALL statically detect leader key assignments in Neovim configuration files and substitute them for `<leader>` and `<localleader>` notation placeholders.

#### Scenario: Space leader calibration
- **WHEN** `options.lua` defines `vim.g.mapleader = " "`
- **THEN** `<leader>` in all card answers resolves to the space character.

### Requirement: Text Sequence Judging
The system SHALL judge card recall using sequential text character matching, rejecting keysym translation and physical keycode evaluation.

#### Scenario: Correct sequential keystroke entry
- **WHEN** a card prompt expects `<leader>ff` and the user types space followed by `f` followed by `f`
- **THEN** the answer is accepted as a first-try success.

#### Scenario: Incomplete prefix entry
- **WHEN** a card prompt expects `<leader>ff` and the user types space followed by `f`
- **THEN** the sequence is held in progress without registering an error or lapse.

#### Scenario: Mistyped sequence entry
- **WHEN** a card prompt expects `<leader>ff` and the user types space followed by `x`
- **THEN** the sequence registers a failure and initiates remedial queue insertion.
