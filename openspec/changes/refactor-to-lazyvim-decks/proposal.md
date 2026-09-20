## Why

Keycade currently ships six training grounds (Omarchy, herdr, tmux, VIM, NEOVIM, LazyVim). Picking a ground is a choice between *applications*, but the thing a user actually wants to drill is a *topic* — marks, LSP, git, the twelve shortcuts they keep fumbling. The ground concept forces breadth the user did not ask for while offering no way to narrow within the one ground they care about.

This change narrows Keycade to LazyVim and replaces the fixed ground grid with user-authored decks: named collections of cards the user assembles themselves, the way they would build a deck in Anki. Breadth becomes depth, and the choice moves from "which application" to "which of my own collections".

## What Changes

- **BREAKING**: The Omarchy, herdr, tmux, VIM and NEOVIM training grounds are removed. Only the LazyVim card supply remains.
- **BREAKING**: The profile stops being the study scope. `Profiles.js` retains `lazyvim` as the card supply only; run scoping, run counters, the coverage cursor, progress and mastery move to the deck.
- **BREAKING**: Keysym judging (`judgeMode: "keysym"`) is removed along with the physical-keycode matching path and the `libxkbcommon` dependency. LazyVim is text-judged, so only `judgeMode: "text"` survives.
- **New**: Decks are declared in `~/.config/omarchy/keycade/decks.json`, read-only to the application. A deck has an id, a display name, and an optional seed.
- **New**: A deck's contents are computed as `seed(corpus) ∪ added − removed`. The seed is evaluated live against the current corpus; only the user's explicit additions and removals are persisted.
- **New**: A deck may be seeded from the pack's own `categories`, `extras` and `contexts` vocabularies. There is no query language, no glob and no free-text matching.
- **New**: A browse-and-pick surface for assigning corpus cards to decks, plus a per-card gesture during a run.
- **Unchanged**: The card supply. The LazyVim pack, the `lazyvim.json` extras gate, the `lua/config/keymaps.lua` override reader and leader calibration all keep working exactly as they do today. This change adds no new ingestion path.
- **Unchanged**: Per-card scheduling history. `stats.bindings["lazyvim/normal/<leader>ff"]` keys survive verbatim, so no learning progress is lost.
- **Retained**: `bin/keybinds-json` survives, reduced to its `--guard-status` preflight. `InputGuard` refuses to launch without it, so it is not a ground-specific helper.

### Non-goals

- **Card literals in `decks.json`.** A card declared there would assert that a mapping exists with nothing to check it against; a typo would be drilled forever. Cards for plugins outside LazyVim's extras are declared in `lua/config/keymaps.lua`, where the line that teaches Keycade is the line that creates the mapping. This is a rejection, not a deferral.
- **Parsing `lua/plugins/*.lua`.** Plugin specs rarely carry a usable `desc`, and a recall trainer needs the prompt more than the key. Reading them would not remove the authoring step it appears to remove.
- **Creating a deck from inside the overlay.** The overlay holds keyboard focus exclusively and has no text input; adding one is disproportionate to minting a name. A new deck means editing the file.
- **A search or filter language for seeds.** Closed vocabularies keep seed validation total.
- **Sharing, importing or syncing decks.**

## Capabilities

### New Capabilities

- `training-corpus`: The single LazyVim card supply — the compiled pack, the extras gate, literal `keymaps.lua` overrides, leader calibration, eligibility filtering, and text-mode answer judging. Replaces the multi-ground profile registry.
- `deck-collections`: What a deck is and where it comes from — the `decks.json` declaration file and its bounds, seed evaluation, persisted membership deltas, curation gestures, and reconciliation when a deck or a card disappears.
- `training-session`: A run scoped to a deck — deck-relative session sizing, run counters, coverage cursor, progress, mastery and celebration, and resume.

### Modified Capabilities

None. The project has no specs under `openspec/specs/` yet; `openspec list --specs` reports none.

## Impact

**Removed**

| Area | Detail |
| --- | --- |
| `bin/` | `herdr-keys-json`, `tmux-keys-json` in full; roughly 800 of 1113 lines of `keybinds-json` (xkb ctypes, keymap compilation, base keysyms, keycode maps, `split_blocks`, `binding_from_block`, RMLVO validation); the tmux prefix readers in `app-config-json` |
| `lib/sources/` | `HyprlandSource.qml`, `hyprland/` (`ActionLocalizer`, `Categorizer`, `Eligibility`), `HerdrSource.qml`, `TmuxLiveSource.qml`, `ExternalPackValidation.js` |
| `lib/` | The keysym halves of `InputNormalizer.js` and `AnswerMatcher.js`; five rows and the tmux `resolvedOptions` special-case in `Profiles.js`; the vim, neovim and tmux packs in `Packs.js` (99 KB of 234 KB); 277 locale keys in `Locales.js`, in both languages |
| `tools/` | The vim, neovim and tmux collectors in `build_packs.py` |
| `tests/` | `test_keybinds_json.py` (846 lines, less the guard-status cases), `test_herdr_keys.py` (266), `test_tmux_keys.py` (236), the tmux slice of `test_app_config.py`, `hyprland_source_smoke.qml`, `test_hyprland_source_qml.sh`, fixtures `binds.txt`, `devices.txt`, `herdr-keys.txt`, `canonical-keys.js` |

**Added or changed**

- `bin/app-config-json`: a `read_decks` reader over the existing `read_json` primitive, plus one entry in its fixed `FILES` table.
- `lib/StateStore.qml` / `settings.json`: an `activeDeck` string and a bounded `deckCards` delta map beside `excludedBindings`. No new state file kind and no new write path.
- `lib/Stats.js`: `stats.profiles` becomes deck-keyed; `MAX_PROFILES: 16` must rise to a deck cap; schema version bump with an `all`-deck migration for the existing `lazyvim` counters.
- `lib/Scheduler.js`: coverage cursor keyed by deck rather than profile; the hardcoded `10/6/6/2` queue split must scale for decks smaller than 24 cards.
- `lib/Session.js`: resume keyed on deck rather than profile; `MAX_CARDS` follows session sizing.
- `Keycade.qml`: the fixed 2x3 cabinet grid becomes a deck list; a browse-and-pick panel; per-card deck gestures; the hardcoded `/ 24` progress display.

**Invariants and compliance**

- `decks.json` is new untrusted input and is bound at both ends under **R2**, read descriptor-relative with `O_NOFOLLOW` under **R3** and **R7** through the existing `app-config-json` reader, parsed into `Object.create(null)` maps under **R4**, and rendered through `SafeText` under **R5**.
- `tests/fuzz_keybinds.py` breaks at import: it loads all four helpers at module scope and calls `KEYBINDS.split_blocks`, `APP_CONFIG.tmux_logical_lines`, `APP_CONFIG.tmux_assignment`, and the tmux and herdr parsers. It must be retargeted — `read_decks` over hostile JSON is the natural replacement and a better target than the tmux grammar was. AGENTS.md section 4.4 requires it stay functional.
- `libxkbcommon` leaves the project. It must be dropped from the **R7** trusted-library list in `AGENTS.md` and `CLAUDE.md`.
- The README's "Keyboard Layouts" section documents the removed keysym path and stops being true. `README.md`, `README.zh-CN.md`, `manifest.json`, `AGENTS.md`, `CLAUDE.md` and the marketplace framing all need revision: Keycade becomes a LazyVim trainer that runs on Omarchy rather than a shortcut arcade for Omarchy.
- No change to **R1** or **R6**: no user configuration is executed and packaging is untouched. **R8** remains mandatory; final invariant review additionally hardens the retained guard and relay against early parent death, failed PDEATHSIG setup, and descendants surviving a relay exit. The expected parent is captured before fork and every relay exit tears down its child group. This introduces no new helper, state kind, dependency or feature.

**Settled in `design.md`** rather than here, because each is a design-level choice with alternatives worth recording: session size for decks under 24 cards (D7), per-deck mastery and celebration semantics (D8), home-screen layout for a variable number of decks (D9), and the numeric deck and counter caps (Bounds).
