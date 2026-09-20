# Orchestration Plan: Subagent Delegation for `refactor-to-lazyvim-decks`

**Date:** 2026-09-19 (rev. 2 — agent assignments + Challenger review loop)
**Companion to:** `docs/lazyvim-decks-refactoring-roadmap.md` (milestones M0–M6)

---

## 1. Orchestration model

**Agents:** `worker` (general-purpose implementation), `smart-worker` (complex refactoring), `challenger` (adversarial review, read-only).

- **Orchestrator (you + main agent)**: owns the branch, commits, `openspec` artifacts, `tasks.md` checkboxes, every integration gate, and every Challenger invocation. No worker edits `openspec/` or merges.
- **Workers** (`worker` / `smart-worker`): receive a self-contained work package = scope (files) + context (spec section, design decisions, invariant subset) + definition of done (exact commands that must pass). A package is not done until its gate is green *and* the Challenger has passed the outcome (§3).
- **Challenger**: reviews every workstream outcome before merge. Never edits code, never edits artifacts — findings only.
- **Hard rule — file ownership**: no two concurrent packages may touch the same file. Contention points called out in §5 and §8.
- Every package brief embeds the relevant R-invariants; AGENTS.md project rules reach subagents via the repo, but the brief restates the ones that matter for that package.

> **Registry note:** `smart-worker` is not yet in the subagent registry (current entries: `worker`, `challenger`, `researcher`, `scout`). Create it — project-local `.pi/agents/` or global `~/.pi/agent/agents/` — before M1 starts, with a strong model and a code-editing tool loadout. Until it exists, its packages fall back to `worker` with heavyweight briefs (workable for 1d, risky for 2/4/5+6). Also: `challenger`'s registered profile red-teams OpenSpec *artifacts* pre-implementation — outcome-review briefs (§3) must explicitly point it at the diff and the spec scenarios instead.

## 2. Work packages and assignments

| WP | Scope | Assignee | Depends on | Gate (definition of done) |
|----|-------|----------|------------|---------------------------|
| **0** | Baseline: run all gates, snapshot `settings.json`/`stats.json` shapes as migration fixtures | orchestrator | — | fixtures committed |
| **1a** | `bin/app-config-json`: remove tmux readers + tmux test slice | worker | — | full suite green |
| **1b** | `bin/keybinds-json` → `--guard-status` only, trim `test_keybinds_json.py` in same commit; delete `herdr-keys-json`, `tmux-keys-json`, their tests, fixtures | worker | — | full suite green |
| **1c** | QML teardown: delete `HyprlandSource/HerdrSource/TmuxLiveSource`, `lib/sources/hyprland/`, `ExternalPackValidation.js`, smoke tests; `assets/packs/` → lazyvim only; `build_packs.py` collector removal; `test_assets.py`/`test_build_packs.py` updated | worker | — | suite green, `qmllint` clean |
| **1d** | Keysym surgical split: `Profiles.js` prune; keysym halves of `InputNormalizer.js` + `AnswerMatcher.js`; `TextKey.js` untouched | **smart-worker** | 1c (Packs.js state) | suite + QML algorithm tests green |
| **1e** | Locale pruning (277 keys, both languages) | worker | 1c | suite green, no dangling `nameKey` lookups |
| **2** | `read_decks` + `FILES["keycade"]` + `tests/test_decks_json.py` + Atheris retarget (must land with 1a/1b deletions in same PR) | **smart-worker** | 1a, 1b | suite green, fuzz `-runs=1000` clean |
| **4** | Migrations: `StateStore.qml` 3→4, `Stats.js` 4→5, `MAX_PROFILES` 16→48 + orphan pruning, D10 retention, cap refuse-and-surface | **smart-worker** | 2 (same PR series or after) | migration tests over WP0 fixtures; card history byte-identical |
| **5+6** | Deck engine + scheduler: `lib/Decks.js` (D12 exclusion-before-seed, `seed ∪ added − removed`), four starter decks, `Scheduler.js` proportional split / no repeats / deck cursor, `Session.js` deck-scoped resume. One package to avoid interface mismatch | **smart-worker** | 4 | offscreen QML tests: deck evaluation, 12→5/3/3/1, empty deck, resume |
| **7a** | Home screen deck list + counts + `all` pinned + zero-card Start refusal (all in `Keycade.qml`) | worker | 5+6 | `qmllint` clean, manual launch |
| **7b** | Browse-and-Pick drawer (target selector, chips, per-row toggles) in `Keycade.qml` | **smart-worker** | 7a (same file — serialized) | `qmllint` clean, manual curate run |
| **7c** | Session HUD `/ sessionSize` | worker | 7a | `qmllint` clean |
| **8** | Locale keys (list/drawer/hint, both languages), README.md, README.zh-CN.md, manifest.json, `.bestpractices.json` | worker | 7b (string freeze) | no stale ground references; suite green |
| **9** | Final integration gate: full gates, R1–R8 checklist, strict `openspec validate`, tick all `tasks.md` boxes | orchestrator + **Challenger full audit** | all | everything green, Challenger passes the change |

## 3. The Challenger review loop

The Challenger is invoked by the orchestrator **after a work package's gate is green, before its commit is finalized/merged**. Reviewing outcomes, not artifacts — the brief must say so explicitly (see registry note in §1).

### 3.1 Flow per workstream

```
worker/smart-worker completes WP
        │
        ▼
orchestrator runs the gate itself (never trusts the worker's self-report)
        │
        ▼  green
orchestrator invokes Challenger with: package diff + package brief + gate output
        │
        ├── PASS ──► orchestrator commits (conventional message), ticks tasks.md, merges if at a gate point
        │
        └── findings ──► back to the OWNING worker (same worktree, same lane) for fixes
                          │
                          ▼
                        re-gate ──► Challenger re-reviews the DELTA only (not the whole package again)
```

### 3.2 The Challenger's checklist (embed in every outcome-review brief)

1. **Spec conformance**: for every scenario cited in the package brief, does the diff actually satisfy it? A gate can be green while a scenario is unimplemented because no test covers it.
2. **Invariant compliance** for the package's R-subset — e.g. WP2: is R2 enforced on *both* ends (reader and QML consumer)? Is every dynamic map `Object.create(null)` (R4)?
3. **Gate-gaming**: were tests weakened, skipped, or deleted to make the suite pass? Were bounds checked producer-side only? Is a rejection silently swallowed instead of counted?
4. **Scope leakage**: any file outside the package allowlist touched? (An allowlist violation, not a nitpick — §8.5.)
5. **Teardown-specific** (WP 1a–1e): is anything still referencing what was removed? Dangling QML ids, locale keys, `nameKey` lookups, helper invocations.
6. **Design-conformance**: does the implementation match the cited D-decisions (e.g. D12 exclusion-before-seed in WP 5+6), or did it quietly reinvent something the design rejected?

### 3.3 Verdict format

PASS, or findings each tagged **blocking** (violates a scenario, invariant, or allowlist → must be fixed and re-gated) or **advisory** (recorded, fixed at the owning worker's discretion or deferred to a later WP). The Challenger does not propose patches — describing the defect precisely is its job; fixing is the worker's.

### 3.4 Cadence and cost

One Challenger invocation per work package (≈13 total), plus one re-review round per package that comes back with findings, plus the full audit at WP9. Reviews run read-only from the orchestrator's checkout — no worktree, no lane contention (§8).

## 4. Where the smart-worker goes — and why

Four packages earn the strong model; each has a failure mode a standard agent plausibly hits:

1. **WP2 — `read_decks`** (27 spec scenarios as the test matrix): the new untrusted-input surface. Dual-ended R2 bounds, R3 `O_NOFOLLOW` reuse, R4 prototype hardening, counted-rejection conventions, and the fuzzer retarget that keeps the Scorecard alive. Security-critical and detail-dense.
2. **WP4 — dual schema migrations**: two version bumps landing together, non-destructive guarantees (D10), quarantine interplay, and a fixture matrix covering every historical schema version. The "existing progress must appear under `all`" scenario is the one users will notice if it breaks.
3. **WP5+6 — engine + scheduler**: the algorithmic core. Proportional 10/6/6/2 scaling with exhausted-queue reallocation, no-repeat dealing except remedial inserts, deck-keyed cursors, `min(24, eligible)`. Design.md itself flags the current repeat behaviour as "wrong for the small decks this change makes common" — this is where that gets fixed, and it's pure logic with no UI to hide behind.
4. **WP1d — keysym surgical split**: shared files where text and keysym modes were *deliberately* built never to merge (`lib/TextKey.js:6`). The design promises surgical removal; keeping that promise without breaking the surviving text path is judgment work.
5. **WP7b — the drawer** (borderline): the one new UI component, with live state interactions against the deck engine. Assign to smart-worker because `Keycade.qml` is a 105 KB file and misplacing the drawer's state wiring is expensive to unwind; 7a and 7c stay with `worker` because they replace existing structures in place.

The genuinely mechanical parts — file deletions (1a–1c), locale pruning (1e), docs/compliance (8), HUD tweak (7c) — go to `worker`; spending the strong model there buys nothing.

## 5. Concurrency map

```
              1a (app-config tmux) ──┐
              1b (helpers+tests) ────┼──► 2 (read_decks+fuzz) ──► 4 (migrations) ──► 5+6 (engine+sched) ──► 7a ──► 7b ──► 8 ──► 9
              1c (QML teardown) ─────┘        ▲                                                        │
              1d (keysym split, smart) ────────┘ (parallel with 2; no shared files)                   └─ 7c (parallel with 7b is tempting but
              1e (locales) after 1c                                                                       same file → serialize or fold into 7b)
```

- **Parallel window 1**: WP2 runs alongside WP1d/1e — disjoint files (`bin/app-config-json` + new tests vs `lib/*.js`).
- **Serial spine**: 1a → 2 → 4 → 5+6 → 7a → 7b — each gate feeds the next; this is the critical path.
- **Late parallel**: WP8 docs drafting can start after 7b's string freeze; locale *additions* must wait for it (WP1e and WP8 both own `lib/Locales.js` — never concurrent).
- The Challenger adds no lanes: it reviews read-only from the orchestrator's checkout between handoffs.

## 6. Package brief template (what to hand each worker)

```
WORK PACKAGE <id>: <name>
Assignee: <worker | smart-worker>
Files you may touch: <explicit allowlist — nothing else>
Context: <spec file + section, design decisions D<n>, invariant subset R<n>>
Constraints: <e.g. "no new state file kind", "run gesture stays exclusion-only">
Interface you deliver: <e.g. "read_decks(home, files) -> (decks, dropped) with bounds X">
Definition of done: <exact commands + expected results>
Out of scope: <everything else; report, don't fix>
```

The Challenger's outcome-review brief reuses the same package brief **plus** the diff and the gate output, with the §3.2 checklist attached.

The allowlist is what makes parallel delegation safe — a worker that stays inside its files cannot collide with the other lane, and the orchestrator's integration gate plus the Challenger's scope-leakage check (§3.2 item 4) catch anything that leaked.

## 7. Orchestrator duties between handoffs

1. Re-run the full gate after every package lands (suite + `qmllint` + fuzz smoke where relevant) — never trust the worker's self-report alone.
2. Invoke the Challenger per §3; only a PASS proceeds to commit.
3. Squash/reword into conventional commits per the roadmap (`refactor(helpers): …`, `feat(decks): …`).
4. Tick the corresponding `tasks.md` checkboxes and keep `openspec validate --strict` passing.
5. PR structure per roadmap: M1+M2 in one PR (fuzzer constraint), M3–M6 as stacked PRs, each green.

## 8. Worktree strategy

**Yes to worktrees — but per concurrent lane, not per work package.**

### 8.1 Why worktrees earn their keep with agent subagents specifically

1. **Concurrent commits share one index.** Two agents running `git add` / `git commit` in the same checkout interleave each other's staged files — commits end up containing half of lane A and half of lane B. This is structural, not a discipline problem agents reliably solve. A worktree gives each lane its own index and HEAD.
2. **Agents run destructive git commands "helpfully."** A subagent that hits a snag and runs `git checkout .`, `git stash` or `git reset` in a shared checkout destroys the *other* lane's uncommitted work. In a dedicated worktree the blast radius is one lane. This is the strongest agent-specific argument.
3. **Clean verification.** Each lane's full-suite gate (`unittest`, `qmllint`, fuzz smoke) runs against only its own changes, with no half-finished edits from the sibling lane sitting in the tree.

### 8.2 Lane mapping, not package mapping

Two worktrees cover the entire plan:

```
Lane A (spine worktree):  1a ──► 2 ──► 4 ──► 5+6 ──► 7a ──► 7b ──► 8 ──► 9
Lane B (side worktree):             1d ──► 1e          (branches off after 1c lands)
```

- Per-WP worktrees add merge ceremony for zero concurrency: WP 7a/7b/7c serialize on the same file, and 4 → 5+6 → 7 is a dependency chain, not parallelism.
- **Lane B merges back before WP4 starts** — 1d's `lib/*.js` files are what the migrations and engine work build on.
- If only one agent runs at a time, skip worktrees entirely; they buy nothing serially.

### 8.3 Precondition: commit the planning artifacts first

`openspec/` is currently **untracked**. Worktrees materialize only committed content — a subagent in a fresh worktree would see no proposal, design, specs or `tasks.md`. Committing the change artifacts is correct regardless (OpenSpec changes are meant to be versioned; they are the review material). Same check for everything a subagent needs:

- WP0 migration fixtures live under `tests/fixtures/` (tracked directory) — fine once committed.
- `AGENTS.md` is tracked — project rules propagate to every worktree automatically.
- `.pi/` skills stay untracked; inline the needed context in each package brief.

### 8.4 Mechanics for this repo

```bash
# 0. Commit planning artifacts first (on main or a planning branch)
git add openspec/ && git commit -m "docs(openspec): add refactor-to-lazyvim-decks change artifacts"

# 1. Spine worktree (from main)
git worktree add ../keycade-wt-spine -b feat/lazyvim-decks

# 2. Side-lane worktree — branch AFTER 1c lands on the spine
git worktree add ../keycade-wt-side -b feat/lazyvim-decks-teardown <spine-sha-after-1c>

# 3. Orchestrator merges at the gate point (before WP4)
git -C ../keycade-wt-spine merge feat/lazyvim-decks-teardown
git worktree remove ../keycade-wt-side && git worktree prune
```

Cheap here: no build directory to duplicate, `__pycache__` is per-worktree, the QML offscreen runner imports from system paths, and `tools/build_packs.py` resolves `ROOT` from its own file location — everything verifies correctly inside a worktree.

### 8.5 Caveats

- **Manual overlay launches** from different worktrees all read the same `~/.config/omarchy/keycade-lazyvim/` and the same state files, and fight over the same Wayland layer. Never have two agents manual-launch simultaneously (true in a shared checkout too) — interactive verification happens on the spine only.
- **Merging is the orchestrator's job**, at gate points only, never mid-package. Because the allowlists are disjoint, merges should be conflict-free by construction; a conflict means an allowlist was violated — which is itself a signal, not just an inconvenience.
- **The Challenger needs no worktree** — it reviews diffs read-only from the orchestrator's checkout and cannot collide with either lane.
