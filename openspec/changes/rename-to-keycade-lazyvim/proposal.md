## Why

`refactor-to-lazyvim-decks` narrowed the application to a single card supply: it is a LazyVim recall trainer that happens to run on Omarchy, not a shortcut arcade for the whole desktop. The published name no longer describes the product. `keycade` promised six applications; what ships drills one.

This renames the product to **Keycade LazyVim** and publishes it as a distinct Omarchy plugin, `gerritwanderer.keycade-lazyvim`. The `keycade` prefix is kept deliberately — the arcade framing, the wordmark and the interaction model are unchanged, and this is the same lineage under a name that states its scope.

## What Changes

- **BREAKING**: The plugin id becomes `gerritwanderer.keycade-lazyvim`. Omarchy treats a new id as a new plugin: it is installed, updated, summoned and removed under the new id, and the existing `luneth90.keycade` installation is not upgraded in place.
- **BREAKING**: State moves from `${XDG_STATE_HOME}/omarchy/keycade/` to `${XDG_STATE_HOME}/omarchy/keycade-lazyvim/`. `bin/state-store` adopts an existing `keycade` directory once, descriptor-relative, so no mastery history is lost.
- **BREAKING**: Deck declarations move from `${XDG_CONFIG_HOME}/omarchy/keycade/decks.json` to `${XDG_CONFIG_HOME}/omarchy/keycade-lazyvim/decks.json`. This file is user-owned and never written by the application, so the user moves it; an unmoved file reads as absent and the shipped starters apply.
- **BREAKING**: The Wayland layer-shell namespace becomes `keycade-lazyvim`. Any user `layerrule` matching `keycade` stops applying.
- **Changed**: The repository becomes `GerritWanderer/keycade-lazyvim`, and every badge, clone URL, marketplace link and issue link follows.
- **Changed**: The home-screen subtitle names LazyVim. The `KEYCADE` wordmark and the `K` cabinet badge stay exactly as they are.
- **Unchanged**: Every binding id (`lazyvim/normal/<leader>ff`), both state schemas, the three state kinds, the entry point `Keycade.qml`, and all invariants R1–R8.

### Non-goals

- **Renaming the QML entry point.** `manifest.json` names it; nothing else about it is user-visible. Renaming it would churn CI assertions, three test harnesses and five documents for no effect a user can observe.
- **Changing the wordmark.** `KEYCADE` is the retained prefix, it is what the screenshots show, and `KEYCADE LAZYVIM` does not fit the top bar at 32px with 4px letter spacing.
- **A compatibility shim under the old plugin id.** Omarchy has no alias mechanism; two ids would mean two installations racing for one state directory.
- **Migrating `decks.json` on the user's behalf.** The config directory is read-only to the application under D1 of `refactor-to-lazyvim-decks`. Writing there to move a file would break that ownership split for one-time convenience.

## Impact

**Identity**

| Area | Detail |
| --- | --- |
| `manifest.json` | `id`, `name`, `author`, `description`, `version` 2.0.0 |
| `Keycade.qml` | `marketplaceUrl`, the id fallback in `dismiss()`, `WlrLayershell.namespace` |
| `dev/InputProbe.qml` | layer namespace and probe banner |
| `bin/state-store` | state directory name plus a one-time `renameat` adoption of `keycade` |
| `bin/app-config-json` | the `FILES` table entry and the `XDG_CONFIG_HOME` path literal |

**Text**

`lib/StateStore.qml` and `lib/sources/PackSource.qml` console warnings; `assets/locales/{en,zh-CN}.json` (`brandSubtitle`, `supportPrompt`) regenerated into `lib/Locales.js`; `README.md`, `README.zh-CN.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`, `AGENTS.md`, `CLAUDE.md`, `.bestpractices.json`, `prototype/`; the pending `refactor-to-lazyvim-decks` spec and design text, which describe this same unreleased version and would otherwise ship stating the old paths.

**Tests**

`tests/test_assets.py` pins the manifest id and entry point; the four `.sh` integrations and `tests/test_settings.py`, `tests/test_decks_json.py` hardcode the state and config paths; `.github/workflows/ci.yml` asserts the id with `jq`. The directory adoption needs its own cases: old present, new absent; neither present; both present.

**Invariants**

No invariant changes. The adoption is a `renameat` between two entries of a directory opened with the existing verified descriptor, so **R3** holds without a new pathname traversal; it introduces no new helper, state kind, dependency or write path, so **R6**, **R7** and **R8** are untouched.
