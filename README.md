# Keycade

**English** | [简体中文](README.zh-CN.md)

> An arcade-style LazyVim shortcut recall trainer for Omarchy (Wayland), driven by your own decks

[![CI](https://github.com/luneth90/keycade/actions/workflows/ci.yml/badge.svg)](https://github.com/luneth90/keycade/actions/workflows/ci.yml)
[![CodeQL](https://github.com/luneth90/keycade/actions/workflows/codeql.yml/badge.svg)](https://github.com/luneth90/keycade/actions/workflows/codeql.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/luneth90/keycade/badge)](https://scorecard.dev/viewer/?uri=github.com/luneth90/keycade)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/14452/badge)](https://www.bestpractices.dev/projects/14452)
[![codecov](https://codecov.io/gh/luneth90/keycade/branch/main/graph/badge.svg)](https://codecov.io/gh/luneth90/keycade)
[![Omarchy Marketplace](https://img.shields.io/badge/Omarchy%20Marketplace-listed-2ea44f?logo=omarchy)](https://plugins.omarchy.org/plugin.html?id=luneth90.keycade)
[![GitHub Release](https://img.shields.io/github/v/release/luneth90/keycade?logo=github)](https://github.com/luneth90/keycade/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

![A LazyVim leader sequence](docs/screenshots/keycade-lazyvim-en.png)

Keycade is a native Omarchy desktop overlay that turns LazyVim shortcut memorization into quick, arcade-style training runs. Keypresses are captured and judged locally through a Wayland inhibitor, never triggering desktop actions during a session.

The training corpus is the official LazyVim key table, calibrated automatically to your leader keys, enabled extras, and `lua/config/keymaps.lua` overrides. Your study scope is a **deck**: the reserved `all` deck containing every eligible card, the four shipped starter decks, or collections you declare yourself in `decks.json`. Each deck keeps its own card counts, run counters, and mastery status, while per-card recall history stays shared across decks.

## Core Features

- **Calibrated LazyVim Corpus**: The official key table, adjusted live to your `mapleader`/`maplocalleader`, enabled `lazyvim.json` extras, and literal `keymaps.lua` overrides — no manual setup.
- **Your Own Decks**: Declare named decks in `decks.json` with closed-vocabulary seeds, then fine-tune membership card by card from the in-app Browse drawer.
- **Multi-Key Sequences**: Supports complex sequences (`<leader>ff`, `gcc`) as seamlessly as single chords, providing step-by-step visual feedback as you type.
- **Input Isolation**: Hardware keypresses are captured directly by the Wayland inhibitor; no desktop window or application responds while you train.
- **Spaced Repetition Engine**: Each session deals up to 24 cards — smaller decks deal every eligible card — balancing unlearned, due, weak, and mastered items to build reliable muscle memory.
- **Strict Mastery Standard**: A card is marked as mastered only after two consecutive first-try successes across separate runs.
- **Active Error Correction**: Missed cards display the correct answer for immediate follow-up practice and reappear later in the run.
- **Seamless State Persistence**: Progress is saved locally in real time; interrupted sessions resume seamlessly, and mastering every card in a deck triggers a milestone celebration.
- **Gentle Exclusions**: Exclude awkward or unpressable shortcuts at any time; return them whenever you want without losing learning history.
- **Themes & Localization**: English and Simplified Chinese support, retro sound effects, and five curated palettes: Catppuccin, Tokyo Night, Gruvbox, Everforest, and Ristretto.
- **Retro Arcade Aesthetic**: CRT scanlines, dot-matrix counters, and marquee borders (animations gracefully disable under Reduced Motion while preserving data displays).

## Requirements

- Omarchy 4.x
- Quickshell 0.3.1 (with `Quickshell.Wayland._ShortcutsInhibitor.ShortcutInhibitor`)
- Hyprland (configured with `binds:disable_keybind_grabbing = false`)
- `qt6-multimedia` (the overlay imports `QtMultimedia` for its sound effects)
- Python 3

Keycade requires active input inhibition to run safely. If Wayland shortcut protection cannot be verified, it refuses to launch rather than falling back to an insecure focus-only mode.

## Installation

```bash
omarchy plugin add https://github.com/luneth90/keycade.git --enable
```

Bind a shortcut in `~/.config/hypr/bindings.lua`, for example:

```bash
echo 'o.bind("SUPER + SHIFT + K", "Keycade", "omarchy-shell shell summon luneth90.keycade '\''{}'\''")' >> ~/.config/hypr/bindings.lua
```

## Updating

```bash
omarchy plugin update luneth90.keycade
omarchy restart shell
```

> **Note**: Restarting the shell is required to ensure running Quickshell components reload the updated code.

## Usage

- **Launch**: Press `Super + Shift + K`, or run:
  ```bash
  omarchy-shell shell summon luneth90.keycade '{}'
  ```
- **Pick a Deck**: The home screen lists every deck — `all` first, then your declaration order — with live card counts and mastery. Select one, then press Enter to begin or resume.
- **Curate**: Open `BROWSE` from the home or results screen to assign cards to a target deck; see [Decks](#decks) below.
- **Switching Decks**: Click `← BACK` at any time; your progress is automatically saved, and returning to that deck restores your exact position.
- **Preferences**: Use the top bar to toggle language, sound effects, volume, and color themes. Preferences are saved automatically.
- **Excluding Shortcuts**: Click `✕ EXCLUDE` during a card to remove it from every deck and from mastery counts. Re-enable excluded items anytime via the `EXCLUDED` panel without losing past accuracy stats.
- **Exiting**: Release a bare `Esc` key to save and exit immediately. Chords involving Esc (`Super + Esc`, etc.) are treated as ordinary answers.

User statistics and session data are stored under `${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/keycade/` and persist across updates; see [State and Migration](#state-and-migration).

## Decks

A **deck** is a named study scope over the shared LazyVim corpus. The reserved `all` deck always contains every eligible card, is pinned first in the list, and cannot be deleted. With no configuration it is joined by four shipped starters — Navigation (`navigation`), LSP & Diagnostics (`lsp`), Search & Find (`search`), and Git (`git`) — each seeded from pack categories.

Deck contents are computed live on every launch: `seed(corpus) ∪ added − removed`. The seed comes from the config file; `added`/`removed` are your explicit curation choices kept in local state. A LazyVim update or a toggled extra therefore grows or shrinks a seeded deck automatically, and curation that names a currently missing deck or card is retained (inert) until it exists again.

### Configuration

Decks are declared in `${XDG_CONFIG_HOME:-~/.config}/omarchy/keycade/decks.json`. The file is **read-only** to Keycade — it is parsed statically, never written, and no Lua, card literals, or query language is involved:

```json
{
  "schemaVersion": 1,
  "decks": [
    { "id": "marks", "name": "Marks & Jumps",
      "seed": { "extras": ["lazyvim.plugins.extras.editor.harpoon2"] } },
    { "id": "lsp", "name": "LSP & Diagnostics",
      "seed": { "categories": ["lsp", "diagnostics"], "contexts": ["normal"] } },
    { "id": "nemesis", "name": "Keeps Getting Me" },
    { "id": "all", "name": "Everything" }
  ]
}
```

- `schemaVersion` must be `1`. At most 32 declarations are accepted (an `all` override included); the reserved `all` deck itself always exists, declared or not.
- `id` is the stable state key and must match `^[a-z][a-z0-9-]{0,31}$`. Renaming `name` (up to 48 characters) keeps your curation; changing `id` creates a new deck.
- `seed` is optional and closed-vocabulary: `categories`, `extras`, and `contexts` declared by the shipped pack. Only present dimensions participate, unioned when several are present, and a present but empty array matches nothing. Omitting `seed` entirely makes the deck manual-only — it starts empty and is filled from Browse — while an explicit empty `seed: {}` is unconstrained and matches every eligible card.
- Declaring `id: "all"` only overrides its display name; any seed on it is ignored.
- When the file is **absent**, the four starter decks are used. When **present**, it replaces the starters entirely. When **malformed**, Keycade falls back to `all`, shows the reason, and never blocks training. Invalid entries, unknown keys, and out-of-vocabulary values are skipped, counted, and surfaced.

Custom mappings from `lua/config/keymaps.lua` (literal `vim.keymap.set` / `vim.keymap.del` lines) join the corpus under the `misc` category and can match `misc` or context seeds like any other card — or be hand-picked into any deck.

### Curating Cards

Open **Browse** from the home or results screen (it is disabled during active play; opening it from results returns home first). Pick a target deck — independent of the deck you are studying — then filter by category, custom (`keymaps.lua`), active extras, or membership, and toggle cards in or out of the target. Rows badge the other decks each card belongs to. The reserved `all` deck is read-only there.

Two different gestures remove a card, and both keep its learning history:

- **In a run**, `✕ EXCLUDE` excludes the card **globally** — from every deck including `all` — until you restore it from the top bar.
- **In Browse**, removing a card only takes it out of the **target deck**.

Curation state is capped at 24 KiB; an addition that would exceed the cap is refused with a notice — nothing is silently evicted.

### Sessions, Mastery, and Resume

- A session deals `min(24, eligible)` cards — a 7-card deck deals 7 — with no repeats apart from remedial review. Starting an empty deck is refused with a hint toward Browse.
- Mastery stays a per-card property shared across decks (two consecutive first-try successes in separate runs); run counts, training time, and the 100% celebration are per deck.
- An interrupted run resumes exactly; if cards have left the deck meanwhile, the saved session shrinks to the completed offset plus the remaining cards, keeping scores, history, and the original plan targets.

### State and Migration

Keycade keeps exactly three state kinds — `settings.json`, `stats.json`, and `session.json` — under `${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/keycade/`. Updating from a pre-decks release migrates settings schema 3 → 4 and stats schema 4 → 5: all per-card recall history is preserved verbatim, including entries recorded under retired training grounds (retained but inert), and existing LazyVim run counters move to the `all` deck. A global run-identity sequence drives card history and scheduling, independently of the deck-visible run counts. Upgrading preserves every card record and deletes nothing, but no automatic rollback path is provided: older releases may reject the newer settings, stats or session schemas, quarantine those files, and start with fresh visible progress. Back up the state directory before downgrading and retain any quarantined files for recovery — automatic card-history or deck-counter compatibility with an older release is not promised.

## Uninstallation

```bash
omarchy plugin remove luneth90.keycade
```

Saved data remains preserved in `${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/keycade/`. Keycade intentionally does not ship destructive scripts that alter Hyprland configurations or erase user progress on uninstall.

## Development & Testing

### Host System Inspection

Upstream defaults form the core table. Bounded static readers inspect only fixed files to calibrate `mapleader` / `maplocalleader`, enabled `lazyvim.json` extras, the installed LazyVim commit in `lazy-lock.json`, top-level literal `vim.keymap.set` / `vim.keymap.del` changes in `lua/config/keymaps.lua`, and the optional `decks.json` deck declarations. Reads are descriptor-relative, reject symlinks, and accept only documented literal shapes. Complex constructs are skipped and counted; no Lua or shell configuration is executed, no editor is spawned, and no `require` chain is followed.

The only live system query is the launch preflight: a read-only `hyprctl` check confirms Hyprland allows keybind grabbing before the overlay takes exclusive input. Helpers run behind deadlines and output limits, and the QML side independently rebuilds bounded whitelist models before retaining anything.

### Tests & Screenshots

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
for suite in tests/qml/tst_*.qml; do
  QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME= QT_STYLE_OVERRIDE=Fusion \
    /usr/lib/qt6/bin/qmltestrunner -input "$suite" -import /usr/lib/qt6/qml
done
./tests/test_state_store_qml.sh
./tests/test_ground_switching_qml.sh
./tests/test_run_counters_qml.sh
./tests/test_mastery_transition_qml.sh
/usr/lib/qt6/bin/qmllint -I /usr/lib/qt6/qml Keycade.qml lib/*.qml lib/sources/*.qml dev/InputProbe.qml
python3 tests/fuzz_keybinds.py -runs=1000
```

The fuzz smoke test needs the pinned dev dependencies (`requirements-dev.txt`, e.g. in a venv). `./tools/shoot-screenshots` reshoots the documentation images on a live Wayland session (maintainer tool, needs `grim`).

## License

Keycade is released under the [MIT License](LICENSE). Copyright © 2026 luneth90.
