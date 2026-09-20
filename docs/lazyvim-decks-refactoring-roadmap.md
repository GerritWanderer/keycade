# Refactoring Roadmap: `refactor-to-lazyvim-decks`

**Date:** 2026-09-19
**Basis:** `proposal.md`, `design.md` (D1–D12, all open questions resolved), `specs/{training-corpus,deck-collections,training-session}`, `tasks.md` (25 tasks)
**Golden rule:** the repository must be green at every commit — `python3 -m unittest discover -s tests -p "test_*.py"` plus the QML algorithm runner pass after every milestone.

---

## 0. Sequencing rules that override task order

Three constraints from the artifacts that dictate the build order regardless of how `tasks.md` is grouped:

1. **The fuzzer breaks the moment helpers are deleted.** `tests/fuzz_keybinds.py` loads all four helpers at module scope. Deleting `bin/herdr-keys-json` / `bin/tmux-keys-json` (task 1.1) breaks its import, and with it the OpenSSF `Fuzzing: 10/10` check. `read_decks` (task 2.2) must exist **before** the deletion lands, so the fuzzer can be retargeted in the same commit series — never after.
2. **`bin/app-config-json` is edited from both ends.** Task 1.2 removes its tmux readers; tasks 2.1–2.2 add `read_decks` to the same file. Land the removal first so the reader work starts from the reduced surface.
3. **The state shape (M3) gates the engine (M4) and the UI (M5).** `deckCards`, `activeDeck` and the deck-keyed counters must exist before `Decks.js` evaluates a single deck.

---

## Milestones

### M0 — Baseline safety net *(no repo changes)*
- Run and record the full gate: Python suite (189 tests), QML runner, `qmllint`, fuzz smoke `-runs=1000`.
- Snapshot today's `settings.json` / `stats.json` shapes as synthetic migration fixtures for M3.
- **Exit:** baseline recorded; nothing committed.

### M1 — Teardown: remove five grounds and the keysym path *(tasks 1.1–1.7)*
Order within the milestone:
1. `bin/keybinds-json` → `--guard-status` only (1.1); trim `test_keybinds_json.py` to the guard-status cases (part of 1.7) — same commit, so the suite stays green.
2. `bin/app-config-json`: remove tmux readers (1.2) + delete `test_tmux_keys.py`, herdr tests, tmux slice of `test_app_config.py` (1.7).
3. Delete QML sources and `lib/sources/hyprland/` (1.3); delete `hyprland_source_smoke.qml`, `test_hyprland_source_qml.sh`, fixtures (1.7).
4. `assets/packs/` → LazyVim only + `tools/build_packs.py` collector removal (1.4); `test_assets.py` / `test_build_packs.py` updated in the same commit.
5. `Profiles.js` prune + keysym halves of `InputNormalizer.js` / `AnswerMatcher.js` (1.5); QML algorithm tests retargeted to text-only.
6. Locale string removal (1.6).
- **Gate:** suite green; `qmllint Keycade.qml lib/*.qml` clean; `InputGuard` still launches (guard-status intact).
- **Risk:** dangling QML references to removed ids — `qmllint` plus a manual overlay launch is the check.
- **Note:** the fuzzer is now broken at import. This is the *only* window where it may be — M2 must land immediately after, ideally the same PR.

### M2 — Deck reader + fuzzer retarget *(tasks 2.1–2.3, 6.1)*
1. `FILES["keycade"]` entry (2.1).
2. `read_decks` with all R2 bounds: 32 decks, id regex, 48-char sanitized name, closed seed vocabularies, counted rejections (2.2).
3. `tests/test_decks_json.py` — the 27 deck-collections scenarios are the test matrix: valid/absent/malformed file, 33rd deck, duplicate id, out-of-vocabulary seed, unknown keys, prototype-pollution attempts (2.3).
4. Retarget `tests/fuzz_keybinds.py` to fuzz `read_decks` over hostile JSON; `import atheris` preserved (6.1). **Scorecard gap from M1 closes here.**
- **Gate:** suite green; `python3 tests/fuzz_keybinds.py -runs=1000` clean.

### M3 — State and migrations *(tasks 3.1–3.3)*
1. `StateStore.qml` schema 3 → 4: `activeProfile` → `activeDeck` (`"all"`), bounded `deckCards` (24 KiB, refuse-and-surface at cap) (3.1).
2. `Stats.js` schema 4 → 5: `profiles` → `decks`, `lazyvim` → `all`, `MAX_PROFILES: 16 → 48` with deterministic orphan pruning, stop writing `knownTotal`/`knownMastered` (3.2).
3. D10 inert retention of foreign-prefix bindings and orphaned deck deltas (3.3).
- **Gate:** migration tests over the M0 fixtures pass; card history keys survive byte-identical.
- **Risk:** two migrations at once — mitigate with the existing quarantine path plus fixtures for every schema version (1–4 settings, 1–4 stats).

### M4 — Deck engine and scheduler *(tasks 4.1–4.3, 2.4)*
1. `lib/Decks.js`: starter decks, exclusion-before-seed (D12), `seed(corpus) ∪ added − removed` (4.1).
2. Compile the four starters — Navigation, LSP & Diagnostics, Search & Find, Git — with `nameKey` records (2.4).
3. `Scheduler.js`: deck-keyed coverage cursor, `min(24, eligible)`, proportional 10/6/6/2, no repeats (4.2).
4. `Session.js`: deck-scoped resume (4.3).
- **Gate:** QML algorithm tests extended with deck evaluation, proportional split (12 → 5/3/3/1) and empty-deck scenarios; suite green.
- **Risk:** the proportional split is the most error-prone pure function — it lives in `Scheduler.js` and is fully testable offscreen before any UI exists. Do it here, not in M5.

### M5 — UI *(tasks 5.1–5.4)*
1. Home screen: deck list, card counts, `all` pinned first, Start disabled on zero-card decks with hint (5.1).
2. Browse-and-Pick Drawer: target-deck selector, filter chips, per-row membership toggles; run gesture unchanged = exclusion (5.2, D12).
3. Locale keys for list/drawer/hint, both languages (5.3).
4. Session HUD `/ sessionSize` (5.4).
- **Gate:** `qmllint` clean; manual overlay run: create a deck, curate, run a session, resume it.
- **Note:** SafeText for every deck name (R5) and `Object.create(null)` for every parsed map (R4) — spec scenarios cover both.

### M6 — Framing, compliance, final gate *(tasks 1.8, 6.2–6.4)*
1. `README.md` / `README.zh-CN.md` / `manifest.json`: drop Keyboard Layouts, reposition as LazyVim trainer on Omarchy; `.bestpractices.json` sync (1.8).
2. Full gate: Python suite, QML runner, `qmllint`, fuzz smoke, R1–R8 checklist walkthrough (6.2–6.4).
- **Exit:** every `tasks.md` checkbox ticked; strict `openspec validate` passes; ready for `/opsx-apply` close-out and `/opsx-archive`.

---

## Parallelizable work (any time after M2)

- README/manifest drafting (text work, lands in M6).
- Locale keys (5.3) once drawer strings are frozen.
- `.bestpractices.json` review.

## Branch and commit strategy (per AGENTS.md)

- `main` is protected (ruleset 22312414) — all work on `feat/lazyvim-decks`, PR into `main`, delete after merge.
- One conventional commit per coherent unit, e.g.:
  - `refactor(helpers): reduce keybinds-json to the --guard-status preflight`
  - `feat(decks): add read_decks with R2-bounded validation to app-config-json`
  - `test(fuzz): retarget atheris harness to read_decks over hostile JSON`
  - `feat(state): migrate settings and stats schemas for deck-keyed state`
- M1 and M2 in **one PR** (the fuzzer constraint); M3, M4, M5, M6 can be separate PRs stacked on it — each independently green.

## Rollback posture

- Upgrades retain card-level history (`stats.bindings`) without deleting retired-prefix records (D10). Older releases may quarantine unsupported schemas; automatic downgrade compatibility is not promised, so back up state before downgrading and retain quarantined files for recovery.
- Deck-level counters do not survive a downgrade — accepted in `design.md`.
- If M3's migration misbehaves in the field, the existing StateStore quarantine isolates a corrupt file and the app falls back to `all`, never blocking training.
