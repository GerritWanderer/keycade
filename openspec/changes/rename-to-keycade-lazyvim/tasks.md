## 1. Plugin Identity

- [x] 1.1 Update `manifest.json` — `id` to `gerritwanderer.keycade-lazyvim`, `name` to `Keycade LazyVim`, `author` to `gerritwanderer`, description, and `version` to `2.0.0`, verifying the `jq` assertions in `.github/workflows/ci.yml` and `tests/test_assets.py`
- [x] 1.2 Update `Keycade.qml` — `marketplaceUrl`, the id fallback in `dismiss()`, and `WlrLayershell.namespace`; update the namespace and banner in `dev/InputProbe.qml`
- [x] 1.3 Update the `jq` manifest assertions in `.github/workflows/ci.yml` and the manifest expectations in `tests/test_assets.py`

## 2. State and Configuration Directories

- [x] 2.1 Rename the state directory to `keycade-lazyvim` in `bin/state-store` and add a one-time descriptor-relative adoption of a legacy `keycade` directory (D2), refusing to act when the new entry exists or either entry is not an owned directory
- [x] 2.2 Add adoption cases to `tests/test_state_store.py` — legacy only, neither, both present, legacy is a symlink, legacy is a regular file — verifying no state is deleted in any case
- [x] 2.3 Move the deck configuration path to `.config/omarchy/keycade-lazyvim/decks.json` in `bin/app-config-json` (`FILES` table and the `XDG_CONFIG_HOME` literal), verifying `tests/test_decks_json.py`
- [x] 2.4 Update the hardcoded state and config paths in `tests/test_settings.py`, `tests/test_decks_json.py` and the four `tests/*.sh` integrations

## 3. Product Text

- [x] 3.1 Update `brandSubtitle` and `supportPrompt` in `assets/locales/en.json` and `assets/locales/zh-CN.json`, regenerate with `python3 tools/build_locales.py`, verifying `tests/test_assets.py` reports no drift
- [x] 3.2 Update the console warnings in `lib/StateStore.qml` and `lib/sources/PackSource.qml`, and the prose in `bin/app-config-json`, `bin/state-store` and `tests/mocks/hyprctl`
- [x] 3.3 Update `prototype/` brand copy

## 4. Repository and Documentation

- [x] 4.1 Update `README.md` and `README.zh-CN.md` — badges, clone URL, install/update/remove commands, summon command, marketplace link, state and config paths, and a migration section
- [x] 4.2 Update `CONTRIBUTING.md`, `SECURITY.md`, `AGENTS.md`, `CLAUDE.md` and `.bestpractices.json` URLs and names
- [x] 4.3 Add the 2.0.0 `CHANGELOG.md` entry covering the rename, the new id, the directory moves and the user migration steps, leaving the 1.x history as written
- [x] 4.4 Update the pending `refactor-to-lazyvim-decks` proposal, design and spec text where it states the old config path, since it describes this same unreleased version

## 5. Verification

- [x] 5.1 `grep -ri keycade` finds no surviving old plugin id, repository URL, state path or config path outside the deliberate ones: the `CHANGELOG.md` history, the migration instructions, the legacy name in `bin/state-store`, and the retired screenshot names pinned by `tests/test_assets.py`
- [x] 5.2 Run the full Python suite, every `tests/qml/tst_*.qml` suite, the four shell integrations and `qmllint` on the dev host; the Atheris fuzz smoke test runs in CI, where the pinned dependency is installed
- [ ] 5.3 Verify on a live session: `omarchy plugin add`, the new summon command, adoption of an existing state directory, and a clean first run with no prior state
