# LazyVim decks execution record

Change: `refactor-to-lazyvim-decks`. Source baseline: `80e6b79`.
The OpenSpec task checklist is the completion tracking authority (26 boxes).
No pushes or PR creation are authorized by this execution.

## WP0 — baseline

Orchestrator ran these gates before implementation:

| Gate | Result |
| --- | --- |
| `python3 -m unittest discover -s tests -p "test_*.py"` | PASS: 189 tests |
| `QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml/tst_algorithms.qml -import /usr/lib/qt6/qml` | PASS: 95 tests |
| `qmllint Keycade.qml lib/*.qml` | PASS: exit 0; existing warnings listed below |
| `python3 tests/fuzz_keybinds.py -runs=1000` | PASS: 1000 runs |
| `openspec validate refactor-to-lazyvim-decks --strict` | PASS |

Environment resolution (no repository dependency changes):

- Initial lint command exited 127 because `/usr/lib/qt6/bin` was absent from
  PATH. Prepending that directory resolves the installed `qmllint`.
- Initial fuzz command exited 1 because Atheris was missing. Created
  `/tmp/keycade-lazyvim-decks-venv` with `python3 -m venv`, then installed
  `requirements-dev.txt` using `pip install --require-hashes --only-binary=:all:
  --no-cache-dir`. Atheris 3.1.0 uses the pinned CPython 3.14 wheel.
- Subsequent gates use
  `PATH=/tmp/keycade-lazyvim-decks-venv/bin:/usr/lib/qt6/bin:$PATH`.
- Lint baseline warnings: `PanelWindow` uncreatable type in `Keycade.qml`, and
  unresolved `QProcess::ExitStatus` signal metadata in `lib/InputGuard.qml`
  and `lib/StateStore.qml`. These are recorded, not suppressed or represented
  as warning-free.
- Raw gate logs: `/tmp/keycade-lazyvim-decks-gates/wp0/` (local, not committed).

Synthetic fixtures: `tests/fixtures/migration/settings-v3.json` and
`tests/fixtures/migration/stats-v4.json`. They include all six namespaces to
make non-destructive migration testable without accessing personal state.

Planning docs were ignored by `docs/**/*.md`; the two requested plans are
explicitly added alongside `openspec/` in the first commit. `.pi/` is not
committed. Both required worker profiles and the Challenger are already
registered; no agent-profile creation is needed. The fixture/baseline commit
follows the planning-only first commit, **before** creating the spine worktree,
so every lane has the fixtures from inception.

### WP0 Challenger review — PASS after delta re-review

The orchestrator's corrected-fixture gate passed (189 Python / 95 QML /
lint exit 0 / fuzz 1000 / strict OpenSpec). Challenger independently verified
the corrections and returned explicit PASS before either initial commit.

- Initial provider attempt failed without a verdict; resumed the same review.
- Blocking: settings fixture used slash-qualified stats IDs as exclusions;
  baseline exclusions require `profile:localId`. Corrected all six entries.
- Advisory resolved: use numeric Hyprland modmask `64` and herdr `default`
  context in both fixtures rather than synthetic unsupported source IDs.
- Advisory resolved: fixture commit precedes all worktree creation (above).
- Advisories for WP4 briefs: historical settings schemas are 1–3 (migrate to
  4), historical stats schemas are 1–4 (migrate to 5); use only synthetic data.
  The current schema should additionally have round-trip/cap tests. Plan prose
  says 25 tasks but the actual checklist has 26. Registry creation note is stale.

## Authorized sequencing reconciliation

The user approved an atomic WP1a + WP1b + WP2 helper/fuzzer landing. The
individual packages keep their assigned workers and reviews, but there is no
commit between removal of the old fuzz targets and the working `read_decks`
retarget. WP1c may land first so WP2 can run alongside WP1d/1e as planned.
This resolves the roadmap's contradictory temporary-broken-fuzzer allowance
in favor of the user's explicit green-at-every-commit rule.
