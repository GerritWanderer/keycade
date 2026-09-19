## 1. Removal of Legacy Grounds and Keysym Judging

- [x] 1.1 Remove legacy helpers `bin/herdr-keys-json` and `bin/tmux-keys-json`, and prune `bin/keybinds-json` to only retain `--guard-status`, verifying the retained `--guard-status` unit-test cases still pass (no live compositor needed)
- [x] 1.2 Remove tmux prefix parsing functions and tables from `bin/app-config-json`, verifying unit tests still pass for LazyVim options
- [x] 1.3 Remove QML sources `lib/sources/HyprlandSource.qml`, `lib/sources/HerdrSource.qml`, `lib/sources/TmuxLiveSource.qml`, and `lib/sources/hyprland/`, verifying no dangling import references remain
- [x] 1.4 Remove `neovim.json`, `tmux.json`, and `vim.json` from `assets/packs/` and remove the vim, neovim and tmux collectors from `tools/build_packs.py`, verifying `python3 tools/build_packs.py` succeeds with only the LazyVim path
- [x] 1.5 Prune `lib/Profiles.js` to retain only `lazyvim` profile definition and remove keysym judging paths from `lib/AnswerMatcher.js` and `lib/InputNormalizer.js`, verifying sequence text judging continues to pass tests
- [ ] 1.6 Remove `libxkbcommon` references from `AGENTS.md` and `CLAUDE.md`, and prune unused locale strings from `lib/Locales.js`
- [ ] 1.7 Delete obsolete tests and fixtures — `test_herdr_keys.py`, `test_tmux_keys.py`, the tmux slice of `test_app_config.py`, the non-guard-status cases of `test_keybinds_json.py`, `hyprland_source_smoke.qml`, `test_hyprland_source_qml.sh`, and fixtures `binds.txt`, `devices.txt`, `herdr-keys.txt`, `canonical-keys.js` — verifying `python3 -m unittest discover -s tests -p "test_*.py"` still passes
- [ ] 1.8 Revise `README.md`, `README.zh-CN.md` and `manifest.json` framing (remove the Keyboard Layouts section, reposition Keycade as a LazyVim trainer running on Omarchy) and sync `.bestpractices.json`, verifying no stale references to removed grounds remain

## 2. Deck Configuration Reader and Hardening

- [x] 2.1 Add `keycade` section with `.config/omarchy/keycade/decks.json` to `FILES` table in `bin/app-config-json`
- [x] 2.2 Implement `read_decks(home, files)` in `bin/app-config-json` with R2 bounds checks (max 32 decks, ID regex `^[a-z][a-z0-9-]{0,31}$`, name <= 48 chars, closed seed vocabulary), verifying with dedicated unit tests
- [x] 2.3 Add unit test suite `tests/test_decks_json.py` covering valid configs, missing files, malformed JSON, prototype pollution keys, duplicate and malformed ids, seed vocabulary rejections, and cap enforcement, verifying `python3 -m unittest discover -s tests -p "test_decks_json.py"` passes
- [ ] 2.4 Compile the four shipped starter decks (Navigation, LSP & Diagnostics, Search & Find, Git) with `nameKey` localisation records, verifying each seed category resolves against the LazyVim pack

## 3. State Store and Schema Migrations

- [ ] 3.1 Migrate `lib/StateStore.qml` settings schema from version 3 to 4, renaming `activeProfile` to `activeDeck` (default `"all"`) and adding bounded `deckCards` mapping (capped at 24 KiB, additions refused and surfaced at the cap), verifying migration on synthetic schema 3 fixtures
- [ ] 3.2 Migrate `lib/Stats.js` schema from version 4 to 5, mapping `profiles["lazyvim"]` to `decks["all"]`, discarding legacy profiles, raising the deck counter cap from `MAX_PROFILES: 16` to 48 with deterministic orphan pruning, and discontinuing `knownTotal`/`knownMastered` disk writes, verifying unit tests in `tests/test_stats.py`
- [ ] 3.3 Ensure foreign-prefix bindings and orphaned deck deltas are retained inertly (D10), verifying via state store load tests

## 4. Dynamic Deck Evaluation and Scheduler Adaptation

- [ ] 4.1 Implement deck definition and evaluation helper `lib/Decks.js` supporting compiled starter decks, exclusion filtering before seed evaluation (D12), and live computation formula `seed(corpus) ∪ added − removed`
- [ ] 4.2 Update `lib/Scheduler.js` to key coverage cursor by `activeDeck` and scale session size to `min(24, eligible)` with proportional 10/6/6/2 queue distribution without duplicate card deals
- [ ] 4.3 Update `lib/Session.js` to scope session resume state to `activeDeck` and respect dynamic session sizing bounds

## 5. UI Refactoring and Curation Drawer

- [ ] 5.1 Replace the 2x3 cabinet grid on the Home screen in `Keycade.qml` with a vertical scrollable deck list displaying deck title, card count, mastery indicator, and pinned `all` deck; disable Start on zero-card decks with a bounded hint
- [ ] 5.2 Implement the Browse-and-Pick Drawer in `Keycade.qml` featuring a target deck selector, category/custom/extra filter chips, and per-row membership toggles; the existing in-run exclusion gesture is retained unchanged and deck assignment happens only in this drawer (D12)
- [ ] 5.3 Add locale keys for the deck list, drawer, and empty-deck hint in `lib/Locales.js` in both languages
- [ ] 5.4 Update session progress display in `Keycade.qml` from hardcoded `/ 24` to dynamic `/ sessionSize`

## 6. Fuzzing, Test Suites, and OpenSSF Verification

- [x] 6.1 Retarget `tests/fuzz_keybinds.py` to fuzz `app-config-json.read_decks` against hostile JSON inputs while preserving `import atheris`, verifying `python3 tests/fuzz_keybinds.py -runs=1000` runs cleanly
- [ ] 6.2 Update and run the full Python test suite, verifying all remaining and newly added tests pass: `python3 -m unittest discover -s tests -p "test_*.py"`
- [ ] 6.3 Run QML algorithm tests with offscreen Qt6 runner: `QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml/tst_algorithms.qml -import /usr/lib/qt6/qml`
- [ ] 6.4 Validate QML components with `qmllint Keycade.qml lib/*.qml` and verify OpenSSF Scorecard and review invariants (R1–R8) remain satisfied
