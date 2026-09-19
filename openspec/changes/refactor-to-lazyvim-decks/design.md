## Context

See `proposal.md` — Why. This section records only the existing structure the approach depends on.

Four properties of the current code shape every decision below.

1. **Scheduling state is already card-keyed.** `stats.bindings["lazyvim/normal/<leader>ff"]` holds state, due date and lapses; `stats.profiles["lazyvim"]` holds run counters, the coverage cursor and mastery. That is already Anki's split between card state and deck state, so replacing the deck-level namespace does not touch per-card history.

2. **The profile is overloaded.** `Profiles.js` makes one id mean four things at once: the card supply, the study scope, the state namespace and the home-screen cabinet. The refactor separates the first from the other three.

3. **Judging modes were built never to merge.** `lib/TextKey.js:6` states that the text mode is deliberately not the keysym mode in `InputNormalizer.js` and that the two must never be merged. The keysym path is therefore removable surgically rather than untangled.

4. **`bin/keybinds-json` is not a ground helper.** `InputGuard.begin()` runs it as `--guard-status` on every launch and refuses to start if it cannot confirm `binds:disable_keybind_grabbing` is off. Removing the Omarchy ground does not remove this helper.

Constraints the design must satisfy: the overlay holds `WlrKeyboardFocus.Exclusive` for its entire lifetime and contains no `TextInput` anywhere, so no user text can be entered in-app; and invariants R1–R8 apply unchanged, with `decks.json` becoming a new untrusted input subject to R2, R3, R4, R5 and R7.

## Goals / Non-Goals

**Goals**

- Make the deck the study scope while leaving the card supply and all per-card history untouched.
- Add exactly one new external input (`decks.json`) and read it through an existing, already-hardened reader rather than a new helper.
- Persist as little as possible: the user's explicit choices, not the derived result of those choices.
- Keep the removal surgical — delete whole files where the seam is clean, rather than partially rewriting shared code.
- Leave every migration non-destructive to learning history.

**Non-Goals** (design-level; see `proposal.md` — Non-goals for scope-level exclusions)

- Introducing a new state file kind or a new write path in `bin/state-store`.
- Introducing a new binding-id namespace. Cards added through `keymaps.lua` already receive `lazyvim/` ids through the existing override path.
- Preserving downgrade compatibility of deck-level state. Card-level state must survive a downgrade; deck counters need not.

## Decisions

### D1 — Decks are declared in config, membership is stored in state

`decks.json` lives in `${XDG_CONFIG_HOME:-~/.config}/omarchy/keycade/`, is owned by the user and is never written by the application. Membership deltas live in the application-owned state directory.

This follows the split the repository already enforces: `bin/app-config-json` reads user configuration and never writes; `bin/state-store` owns state and quarantines it when corrupt. A file written by both sides is where merge bugs live, and a user editing a `state-store`-managed file would fight its quarantine behaviour.

*Alternative considered:* decks in state, app-writable, auto-named `DECK 4` until renamed. Rejected — it makes the app able to mint decks, at the cost of dual ownership of one file, and the user accepted that new decks require editing a file.

*Consequence:* a deck cannot be created from inside the overlay. The only in-app gestures are adding and removing cards.

### D2 — Read `decks.json` through `bin/app-config-json`, not a new helper

`app-config-json` already has `read_json(home, relative)` layered on `read_text`, which opens every path component with `O_NOFOLLOW`, rejects non-regular files, caps at `MAX_FILE_BYTES`, and validates UTF-8. It already runs behind `bounded-relay` with a deadline. Adding one entry to its fixed `FILES` table and a `read_decks` function reuses all of that.

*Alternative considered:* a `bin/decks-json` helper. Rejected — it would duplicate the entire R3/R7 read path for one small file and add a second process to the launch sequence.

### D3 — Deck contents are computed, not stored

```
deck contents = seed(corpus)  UNION  added  MINUS  removed
                ^^^^^^^^^^^^         ^^^^^^^^^^^^^^^^^^^^^
                config, evaluated    state, the user's explicit
                live on every load   choices only
```

Persisting only the deltas means a seeded deck the user never edits costs zero bytes, and a deck pruned by five cards costs roughly 200. A fully hand-built 45-card deck costs about 1.7 KB.

This is what keeps the change out of `bin/state-store`: the deltas fit inside `settings.json` (64 KiB, currently holding `excludedBindings` under an 8 KiB sub-cap) beside the mechanism they structurally resemble. No new file kind, no new write path.

A live seed also means a LazyVim update that adds two Harpoon mappings puts them in a Harpoon-seeded deck automatically, which a materialise-once seed would not.

*Alternative considered:* store full membership (~11 KB for the whole corpus). Rejected — an order of magnitude more state, a new file kind, and a seed that silently goes stale.

### D4 — The seed vocabulary is closed

`seed` accepts only `categories`, `extras` and `contexts`, each drawn from a vocabulary the loaded pack declares, unioned when more than one is present, and omitted meaning unconstrained. No globs, no regular expressions, no matching on descriptions.

Every seed value can therefore be checked against the pack, so an unrecognised value is a counted rejection rather than a silent half-match, and validation is total. It also stops the seed from becoming a query language that must be documented, versioned and fuzzed.

The `extras` key is what makes a plugin deck a single line and has no dependence on the `category` field. Categories remain available as a seed but are not the organising principle.

*Alternative considered:* Anki's filtered-deck search syntax (`category:lsp lapses>=3`). Rejected for this change — a parser, a UI and documentation, for power the closed vocabulary plus hand-picking already covers.

### D5 — Cards outside LazyVim's extras come from `keymaps.lua`, never from `decks.json`

`PackSource.mergedBindings` already synthesises a new corpus card from each literal `vim.keymap.set` that `app-config-json` reports, assigning `customKind: "added"`, parsing the lhs with `TextKey.parseNotation` and defaulting `category: "misc"`. This path ships today and is covered by `tests/test_app_config.py`.

A card literal in `decks.json` would assert that a mapping exists with nothing to verify it against; a typo would be drilled forever. A `vim.keymap.set` line *creates* the mapping it teaches, so the two cannot drift. Since the plugin supplies no usable `desc` either way, the user authors a description in both designs — authoring it as a real keymap costs the same keystrokes and yields a mapping that exists.

*Consequence:* such cards land in `category: "misc"`, which the shipped pack declares. They participate in normal category and context seed matching like every other eligible corpus card; they are not restricted to manual assignment. Browse-and-pick remains available for finer-grained collections. No special-case exclusion of custom cards is applied during seed evaluation.

### D6 — Curation needs a browse-and-pick surface, not only a play-time gesture

A card declared in `keymaps.lua` enters the corpus as `unseen`. The scheduler deals six unseen cards per run out of roughly 200, so a play-time-only gesture could take many runs to surface a card the user just created. Assignment must therefore also be possible from a list.

The `EXCLUDED` panel is the precedent: a top-bar toggle opening a scrollable list with a per-row action. The deck panel is that over the corpus rather than over the exclusions.

Deck assignment happens in this drawer only; the per-card gesture during a run keeps its existing exclusion meaning (D12).

Because the overlay holds exclusive keyboard focus with no text input, the browse-and-pick surface operates via **Deck-Focused Curation** and **filter chips**:
- **Target deck selector at top**: The user selects which deck they are currently curating (e.g. `Nemesis`, `LSP`).
- **Filter chips bar**: Fast toggles for categories (`git`, `lsp`, `search`), custom mappings (`keymaps.lua`), active extras (`harpoon2`), and membership status (`all` vs `in deck`).
- **Per-row action**: Each card row shows its prompt, notation, context badges (showing other decks the card belongs to), and a single contextual button for the active deck:
  - If not in deck: `[ + Add ]` (appends to `deckCards[deckId].added`).
  - If manually added: `[ ✓ In Deck (Added) ]` (clicking removes from `added`).
  - If seeded: `[ ✓ In Deck (Seeded) ]` (clicking appends to `deckCards[deckId].removed` to prune it).
A card may belong to multiple decks simultaneously (1:N mapping, D8).

### D7 — Session length follows deck size, and a card is dealt once

`Scheduler.build` currently allocates a fixed `10/6/6/2` across due, unseen, weak and maintenance to reach 24, then fills any shortfall from `chooseFallback`, which permits repeats. On a five-card deck that deals the same five cards roughly five times in one run — drilling, not spaced repetition.

The initial session length becomes `min(24, eligible)`, the queue split scales proportionally with the remainder going to `due`, and no card appears twice in a run except as a remedial insert. `Session.MAX_CARDS` remains 24 as the upper bound that resume validates against.

After exclusions or configuration changes remove cards, `sessionSize` becomes the completed offset plus the remaining playable cards. Score, results, recall history and the original bounded new/review targets are preserved, even when those targets exceed the reduced size. An unchanged resume retains its exact queue and score. Zero remaining cards do not create a phantom resume or a zero-card mastery celebration.

At `eligible == 0` — an unseeded deck nobody has curated yet — the deck row reports zero cards and starting is refused with a hint rather than opening a run with nothing in it. The deck stays listed, because it is the row the user needs in order to find the deck in the drawer and fill it.

*Alternative considered:* keep 24 with repeats. Rejected — it is the current behaviour and it is wrong for the small decks this change makes common.

### D8 — Mastery stays a card property; completion and celebration become per-deck

Mastery is unchanged: two consecutive first-try successes in separate runs. A deck is complete when every card in it is mastered, and the celebration fires once per deck, recorded in that deck's counters. A card in two decks contributes to both.

Card history and run-relative scheduling use a bounded, globally monotonic numeric run identity, persisted in the existing stats file. Each new session allocates a fresh identity; resuming an interrupted session reuses its identity. `successfulRuns`, `lastSuccessfulRun` and `dueRun` refer to this global sequence, not the deck-local display counter. Thus `lsp` run 1 and `git` run 1 are distinct successes, and a card due on the next run can be due in another deck. Deck-visible run counts, training time and celebration counters remain deck-local. Exhaustion refuses a new allocation rather than wrapping or reusing an identity.

Migration preserves existing numeric card records unchanged. The sequence is seeded from existing LazyVim counters and history, and an unfinished legacy LazyVim session's identity is reserved before a new session can be allocated. Retired-prefix history remains inert and does not advance the sequence. This adds no state file kind or write path.

No minimum deck size for celebration. The deck is the user's own construction, so a small deck cleared is an accomplishment they defined; a threshold would require explaining why a deck did not celebrate.

`knownTotal` / `knownMastered` are dropped from the written record. They existed because two grounds read the machine through a subprocess and could not be recomputed on the home screen. Seeds evaluate in memory over an already-loaded corpus, so every deck's progress can be computed on demand. The fields are still read for migration and then stop being written.

### D9 — The home screen becomes a list

The fixed 2×3 cabinet grid is replaced by a vertical scrollable list, one row per deck showing name and progress, with `all` pinned first. Deck names are user-authored and up to 48 characters, which a fixed-width cabinet cell cannot hold; a list row gives stable geometry and room to elide. The cabinet metaphor is being retired with the grounds in any case.

### D10 — Foreign-prefix state is retained and inert, never deleted

Card entries under `hyprland/`, `herdr/`, `tmux/`, `vim/` and `neovim/` prefixes are kept untouched, not counted and not displayed. They cost roughly 250 entries against a `MAX_BINDINGS` budget of 4000, and retaining them makes a downgrade non-destructive.

This follows an established convention: `Session.excludedList` already keeps other grounds' exclusion entries specifically so two grounds cannot clear each other's. Exclusions therefore need no migration at all.

The same rule applies to deltas for a deck id no longer present in `decks.json` — retained but inert, so re-adding the id restores the curation.

### D11 — `decks.json`, if present, fully defines the deck list

Shipped starter decks are compiled in, carrying `nameKey` for localisation the way pack records carry `descKey`. If `decks.json` is absent the starters are used; if it is present it replaces them entirely, plus the reserved `all`.

*Alternative considered:* merging shipped and user decks. Rejected — a merge needs a hide list and surprises the user with decks they did not declare.

The shipped set is four decks plus the reserved `all`: Navigation (`navigation`, `window`, `buffer`, `tab`), LSP & Diagnostics (`lsp`, `diagnostics`), Search & Find (`search`, `find`) and Git (`git`). Their stable deck ids are `navigation`, `lsp`, `search` and `git`, respectively, independent of localized display names. They are examples of the seed vocabulary in use, not an attempt at coverage; a user who writes `decks.json` replaces all four.

### D12 — Exclusion and per-deck removal stay separate mechanisms

An exclusion means *never show me this card anywhere* and continues to be stored profile-keyed in `excludedBindings`, hiding the card from every deck including `all`. A per-deck `removed` entry means *not in this one deck* and leaves the card eligible elsewhere.

Keeping them separate is what lets D10 stand: exclusions need no migration precisely because they never became deck-scoped. Folding them into `all`'s `removed` list would force one, and would make "stop showing me this" depend on which deck the user happened to be in when they said it.

*Consequence:* the eligibility filter applies before seed evaluation, so an excluded card is absent from every deck's card count.

*Consequence:* the per-card gesture during a run keeps its current meaning — it excludes. Deck assignment happens only in the browse-and-pick drawer, which avoids inventing a target-deck selector for a surface that has no room for one: adding a card to the deck currently being trained is a no-op, so an in-run deck-add gesture would need to name some other deck with no text input available.

### The file

```jsonc
{
  "schemaVersion": 1,
  "decks": [
    { "id": "marks", "name": "Marks & Jumps",
      "seed": { "extras": ["lazyvim.plugins.extras.editor.harpoon2"] } },
    { "id": "lsp", "name": "LSP & Diagnostics",
      "seed": { "categories": ["lsp", "diagnostics"] } },
    { "id": "nemesis", "name": "Keeps Getting Me" },
    { "id": "all", "name": "Everything" }
  ]
}
```

`decks` is an array rather than an object: order is the display order and must be explicit, and a JSON object parsed into JS is the prototype-pollution surface R4 forbids.

The deck `id` is the state key, so it is stable across renames — changing `name` preserves curation, changing `id` creates a new deck.

`all` is reserved: undeletable, default, contains every eligible card. If the user declares it, only `name` is honoured and any `seed` is ignored. Its seed is entirely opaque: no traversal or nested rejection accounting is performed. Unknown keys on the deck declaration itself are still ignored and counted.

### Bounds (R2 — enforced in `read_decks` and independently re-validated in QML)

| Field | Cap | Borrowed from |
| --- | --- | --- |
| file | 64 KiB | `app-config-json` `MAX_FILE_BYTES` |
| `decks[]` | 32 | new |
| `id` | `^[a-z][a-z0-9-]{0,31}$`, unique | `Profiles.ID_PATTERN` |
| `name` | 48 chars, C0/C1/bidi stripped | `PackSource.safeText` |
| `seed.categories[]` | 24 entries × 32 chars | `PackSource.maxCategories` |
| `seed.extras[]` | 32 entries × 128 chars | `app-config-json` `MAX_EXTRA_CHARS` |
| `seed.contexts[]` | 8 entries, from the profile's contexts | `Profiles.contexts` |
| `deckCards` total | 24 KiB within `settings.json` | beside `excludedBindings`' 8 KiB |
| deck counter records | 48 | replaces `Stats.MAX_PROFILES: 16` |
| global run sequence | existing `Stats.MAX_COUNTER` bound | numeric card-run history bound; never wrap or reuse |

Unrecognised keys are ignored and counted, following the existing `dropped` / `rejected` convention.

An addition that would carry `deckCards` past its cap is refused and surfaced, leaving the stored deltas untouched. Evicting an older entry to make room would silently discard curation the user performed deliberately, which is the failure the cap exists to prevent.

### Reconciliation

| Situation | Behaviour |
| --- | --- |
| `decks.json` absent | Shipped starters plus `all`. Not an error. |
| `decks.json` malformed | Fall back to `all`, surface the reason, never block training. |
| Deck removed from the file | Its deltas are retained but inert (D10). |
| Delta names a card no longer in the corpus | Retained, inert, not counted toward the deck total. |
| Stored deck-counter map exceeds its cap | Orphan records pruned deterministically by id on load. |
| An addition would exceed the `deckCards` cap | Refused and surfaced; stored deltas untouched. |
| Card is excluded while also a deck member | Exclusion wins; the card is absent from every deck and its counts (D12). |

## Risks / Trade-offs

- **The keyboard-layout story is the project's strongest technical differentiator and it goes.** → Accepted deliberately, not incidentally. Recorded in `proposal.md` — Impact so the README, manifest and marketplace framing are revised in the same change rather than left stale.
- **`tests/fuzz_keybinds.py` breaks at import**, taking the OpenSSF Scorecard `Fuzzing` check with it. → It must be retargeted in the same change; `read_decks` over hostile JSON is a stronger target than the tmux grammar it replaces.
- **A live seed can shrink a deck silently** when an extra is switched off in `lazyvim.json`. → Deck rows show a card count, and deltas for the vanished cards are retained, so switching the extra back on restores the deck exactly.
- **Roughly half the Python test suite is deleted**, in code paths that carry R7 trusted-command logic. → The `--guard-status` tests in `test_keybinds_json.py` are retained rather than deleted with the file, and are the acceptance gate for the reduced helper.
- **Two schema migrations land at once** (settings and stats). → Both are additive-plus-rename with no card-level deletion (D10); the existing quarantine path in `StateStore` already handles a file that fails to parse.
- **Cards from `keymaps.lua` default to the broad `misc` category rather than plugin-specific categories.** → They can be collected by valid `misc` or context seeds, while browse-and-pick supports finer-grained manual assignment. The same seed formula applies to custom and packaged cards.
- **Deck state does not survive a downgrade.** → Card history does, which is the part that took months to earn. Deck definitions are a config file the user still has.

## Migration Plan

1. `settings.json` schemaVersion 3 → 4: `activeProfile` becomes `activeDeck`; any stored value maps to `all`. `excludedBindings` is untouched — foreign-prefix entries are already retained and inert.
2. `stats.json` schemaVersion 4 → 5: `profiles` becomes `decks`; `profiles["lazyvim"]` becomes `decks["all"]`, preserving runs, training time and mastery; the other five profile records are dropped. `bindings` is untouched, including foreign-prefix entries (D10). Initialize the bounded global run sequence from LazyVim counters/history and reserve any unfinished legacy LazyVim session identity before allocating a new run (D8); foreign-prefix history does not influence this sequence.
3. On first launch after the update the user sees the `all` deck with their existing LazyVim progress intact, plus the shipped starter decks, and no `decks.json`.
4. No rollback path for deck-level counters. Card-level history is preserved under both schemas, so a downgrade loses run counts and celebration flags but no recall history.

## Open Questions

- Whether `bin/keybinds-json` is renamed once reduced to `--guard-status`. Cosmetic; it can follow in a separate change without affecting anything here.
