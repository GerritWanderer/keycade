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

## WP1c — QML source and pack teardown — PASS

- Removed retired QML sources, pack assets and collectors; LazyVim's 361-card
  payload is unchanged (asset SHA-256
  `56d2d83ae1341526959e29fb753b96d15d00bc57f02c6e7d778427b56c29ca03`).
- Kept only LazyVim reachable in the application. Adapted surviving integration
  assertions for supply loading, resume, run counters and mastery.
- Authorized allowlist expansion: `tools/screenshot-shell.qml` and
  `tools/shoot-screenshots`, solely to remove dangling retired-ground/API calls.
  No screenshots generated or personal state modified.
- Orchestrator gates: 188 Python tests, 80 QML tests, lint exit 0 (baseline
  metadata warnings only), fuzz 1000, pack regeneration, strict OpenSpec,
  diff whitespace checks and all three isolated Wayland integration tests PASS.
- Challenger `github-copilot/gpt-5.6-sol` with verified `xhigh`: **PASS**, no
  blocking or advisory findings. Prior provider failures and acknowledgement-only
  results did not count as reviews. Requested `gpt-5.8-sol` retries were rejected
  by the provider as unsupported.
- User paused, then authorized continuation after refreshing agent definitions.
  Orchestrator verified the reviewed diff was byte-identical and repeated the
  full automated gate successfully before committing.
- Logs: `/tmp/keycade-lazyvim-decks-gates/wp1c/` and `wp1c-resume/`.
- Tasks 1.3 and 1.4 complete; task 1.7 remains partial until helper/matcher
  teardown completes.

## WP1a + WP1b + WP2 — atomic helper/reader landing — PASS

WP1a removed tmux configuration parsing and its seven dedicated tests, adapting
shared security/CLI tests to LazyVim rather than deleting them. Independent
non-fuzz gate: 181 Python / 80 QML / lint / strict validation PASS. Challenger
reviewed the exact saved WP1a patch and returned PASS with no findings.

WP1b reduced `keybinds-json` to the trusted read-only guard preflight and removed
Herdr/tmux helpers, their tests, and their dedicated fixtures. Applicable trusted
command, environment, bounds, deadline and process-reaping tests were retained.
Independent initial non-fuzz gate: 108 Python / 80 QML PASS.

WP2 added `read_decks` using bounded descriptor-relative reads, safe XDG handling,
closed pack vocabularies, sanitized names and counted rejection. The independent
consumer is `DeckValidation.js`, wired into the existing `AppConfigSource` launch
and incremental transport. Its interface is `{schemaVersion: 1, status, reason,
decks, rejected}`, distinguishing absent, valid (including empty), and invalid
configuration. Atheris now actually exercises hostile raw and structured deck
JSON; it keeps `import atheris` and no longer imports deleted helpers.

### Findings and resolutions

- WP2 blocking R5 finding: incomplete terminal escape stripping left ESC command
  bytes in names. Both boundaries now use complete scanners with matched,
  exhaustive final/intermediate-range and malformed/truncated-sequence tests.
- WP2 advisory resolved: real offscreen Quickshell `AppConfigSource.accept()`
  tests cover retained-object isolation, schema/prototype defenses, stream
  handling and combined transport limits, beyond pure-validator tests.
- **User clarification:** reserved `all.seed` is entirely opaque, with no
  traversal or nested rejection counts. Unknown keys on the declaration itself
  still count. This clarifies the existing reserved-deck override, not membership
  semantics or scope. Challenger accepted the clarification and returned PASS.
- WP1b blocking schema finding: malformed guard values could report disabled
  false. The helper now accepts only real versioned Hyprland int/bool schemas
  with exact option identity, rejecting conflicting/unsupported/wrong-typed
  values. Real-schema and hostile-shape tests cover the boundary.
- WP1b blocking R8 finding: generic post-spawn errors and ignored PDEATHSIG setup
  failures could miss teardown. Setup/prctl failures now prevent execution;
  every post-spawn exit path kills and reaps the group. Fault-injection tests
  assert actual child/descendant liveness, not only error strings.
- WP1b consumer advisory resolved with authorized allowlist expansions:
  `lib/InputGuard.qml`, shared pure `lib/GuardStatus.js`, and
  `tests/qml/tst_guard_status.qml`. The consumer requires the guard type tag and
  validates the bounded payload without altering the inhibitor lifecycle.
- Authorized CI compatibility expansion: `tests/mocks/hyprctl` now models the
  surviving guard-only query with a real schema, refuses unsupported requests
  and absent sockets, and has hermetic socket-backed regression tests. CI does
  install this mock; it was not unreferenced.
- A pre-existing sticky InputGuard overflow flag was noted during delta review;
  it was unchanged and is outside these corrections (not a blocker or claimed
  fix). Preserve this observation for the final audit/report.

### Final independent gate and review

Orchestrator: **146 Python / 80 core QML / 56 reader QML / 7 guard QML**, lint
exit 0 (baseline metadata warnings), Atheris 1000, strict OpenSpec, whitespace
checks, four isolated Wayland integrations, and live guard preflight all PASS.
Challenger returned separate PASS verdicts for WP1a, WP1b correction delta, and
WP2 correction delta. No commits occurred during the temporary working-tree
fuzzer break. Logs are under `/tmp/keycade-lazyvim-decks-gates/`, especially
`wp1b-final/`, `wp1b-fixed/`, and `wp2-fixed/`.

Remaining teardown integration: side lane WP1d and WP1e are individually gated
and reviewed; remove the canonical fixture after their matcher changes merge,
and remove 46 retained Herdr locale keys per language after helper deletion is
visible on that lane. Tasks 1.6 and 1.7 remain unchecked until those follow-ups.

## WP1d and WP1e — side-lane integration

- WP1d commit `3f0a029`: LazyVim-only registry and text-only judging. TextKey is
  byte-identical, and legacy v1–v3 stats / pre-profile sessions remain forever
  Hyprland rather than being relabeled by the new default. Foreign namespaces
  and colon-qualified exclusions remain valid but inert. Authorized integration
  test adjustment changed only the obsolete activeProfile selection expectation.
  Independent gates: 188 Python / 73 QML, fuzz, both lint checks, strict validation
  and four Wayland integrations PASS; Challenger PASS with no findings.
- WP1e commit `01bed50`: removed 316 English and 440 Chinese unused locale keys,
  preserving retained values, all 333 LazyVim descriptions and dynamic live keys.
  Removed obsolete XKB references from agent instructions without weakening
  security or tests. Independent gate: 188 Python / 73 QML plus fuzz, lint,
  regeneration and strict validation PASS. Challenger PASS for this coherent
  side-lane step, explicitly requiring the remaining Herdr-key follow-up.
- Both reviewed commits merged without conflicts after the atomic helper/reader
  commit. Integrated gate: 146 Python / 73 core QML / 56 reader QML / 7 guard QML,
  fuzz 1000, lint, strict validation and four Wayland integrations PASS. Logs:
  `/tmp/keycade-lazyvim-decks-gates/teardown-merge/`.

### Coordinated final cleanup

The owning WP1b worker removed `tests/fixtures/canonical-keys.js` only after both
runnable consumers were gone. Orchestrator full gate PASS (146 Python / 73 core
QML / 56 reader / 7 guard, fuzz 1000, lint, strict validation); Challenger delta
PASS with no findings. Its mention in the text-key fixture header is historical
rationale, not a runnable dependency. Task 1.7 is complete.

The owning WP1e worker removed the final 46 Herdr descriptions per language and
regenerated Locales after helper removal was visible. The same complete gate
passed independently; Challenger delta PASS, no findings. Catalogs now have 448
keys each with all live LazyVim and generic strings preserved. After conflict-free
integration the complete gate passed again (`m2-complete/`). Task 1.6 is complete;
M1/M2 are closed, and the side lane is removed before WP4 as planned.
