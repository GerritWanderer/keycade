# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **Symlinked configuration read as absent**: `bin/app-config-json` opened every path component with `O_NOFOLLOW`, so a `~/.config/nvim` linked into a dotfiles repository — the ordinary setup for stow, chezmoi and yadm — failed to open and the whole calibration read as empty. Custom `keymaps.lua` bindings, enabled `lazyvim.json` extras and the installed LazyVim version were all silently missing, and the keymaps filter in the browser showed nothing. The read now follows a symlinked component and vets what it lands on instead of refusing it.

### Security

- **R3 scoped to state I/O**: the `O_NOFOLLOW` rule continues to govern every write under `~/.local/state/omarchy/keycade-lazyvim/`, which is where a redirected path could do harm. Read-only configuration reads — `options.lua`, `lazyvim.json`, `lazy-lock.json`, `keymaps.lua` and `decks.json` — instead `fstat` each component on the descriptor already held and refuse any that is not owned by the caller or by root, or that is group/world-writable unless it is a sticky directory. Ownership is checked on the open descriptor rather than the pathname, so it cannot change between the check and the read. Nothing on this path writes, and R1's no-execution rule and every existing byte cap are untouched.

## [2.0.1] - 2026-09-20

### Documentation

- **Copyright**: `LICENSE` and both READMEs now carry `GerritWanderer`'s notice beside `luneth90`'s. MIT requires the original notice to survive in every copy, so this is added, not replaced.
- **Security policy**: supported versions move to 2.0.x, with a note on where a 1.0-only finding belongs; the reporting checklist names the helpers, QML consumers and Wayland input path that exist today instead of retired IPC socket handlers; disclosure routes through GitHub private reporting and the maintainer's profile rather than a published personal address.
- **OpenSSF Best Practices badge**: removed from both READMEs. It pointed at a project registered against the repository this one was renamed from, so it claimed something this repository has not earned. `.bestpractices.json` is kept as the record of what was submitted. Scorecard, CodeQL, Dependabot and the Atheris fuzz gate are unchanged.

No code, schema or packaging changes: state, decks, binding ids and the plugin id behave exactly as in 2.0.0.

## [2.0.0] - 2026-09-20

### Renamed

- **Plugin identity**: Keycade is now **Keycade LazyVim**, published as `gerritwanderer.keycade-lazyvim` from `GerritWanderer/keycade-lazyvim`. The name follows the scope: this release drills one card supply, LazyVim, rather than six applications. Omarchy treats a new id as a new plugin, so the previous installation is not upgraded in place.
- **State directory**: `${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/keycade/` becomes `.../omarchy/keycade-lazyvim/`. The first launch adopts an existing directory by renaming it through the already-verified parent descriptor, preserving every card record, run counter and saved session. When both directories exist the new one wins and the old one is left untouched; nothing is ever merged or deleted.
- **Deck configuration**: deck declarations move to `${XDG_CONFIG_HOME:-~/.config}/omarchy/keycade-lazyvim/decks.json`. This file is user-owned and never written by the application, so it is moved by hand; an unmoved file reads as absent and the shipped starter decks apply.
- **Layer-shell namespace**: the Wayland surface is now `keycade-lazyvim`, so a `layerrule` matching `keycade` no longer applies.

### Migration

```bash
omarchy plugin add https://github.com/GerritWanderer/keycade-lazyvim.git --enable
mv ~/.config/omarchy/keycade ~/.config/omarchy/keycade-lazyvim   # only if you declared decks
omarchy plugin remove luneth90.keycade
```

Rebind the Hyprland shortcut afterwards — the binding embeds the plugin id as both label and command.

## [1.0.1] - 2026-09-05

### Security & Hardening

- **Marketplace Security Review Hardening**: Addressed findings from the Omarchy marketplace security audit (invariants R1–R8):
  - **Dual-Ended Input Bounds (R2)**: Enforced independent schema validation and resource caps on external input sources (live tmux, Herdr, and offline packs); bounded overlay launch payload to 16 KiB.
  - **Prototype Pollution Defense (R4)**: Converted dynamic data stores and schedulers to null-prototype maps (`Object.create(null)`), rejecting prototype-special keys.
  - **Hermetic Trusted Commands (R7)**: Verified child executables at the process relay boundary (`bounded-relay`) to reject relative, non-root, or writable paths; eliminated all `/usr/bin/env` references.
  - **Plain Text UI (R5)**: Constrained dynamic UI texts and action buttons with strict line limits and plain text boundaries.

### Fixed

- **Mastery Transition Logic**: Fixed an issue where a stale milestone timestamp could prematurely end a session, ensuring completion triggers only when the active ground is 100% mastered.

### CI & Tooling

- Enforced least-privilege workflow permissions and added Atheris parser fuzz testing in CI.

## [1.0.0] - 2026-09-05

### Highlights

Keycade 1.0.0 is the first major stable release, transforming shortcut memorization into an arcade-style recall training platform. This release introduces six dedicated training cabinets, Wayland input isolation, end-to-end security hardening (review invariants R1–R8), full test automation, and complete third-party verified CI/CD workflows.

### Added

- **Six Dedicated Training Grounds (Cabinets)**:
  - **Omarchy**: Live compositor shortcut extraction directly from running Hyprland instances with validated XKB keymap compilation.
  - **Herdr**: Terminal multiplexer bindings from Omarchy's bounded local listing.
  - **Tmux**: Dynamic key bindings queried safely from active tmux servers via bounded, deadline-enforced listing.
  - **Vim**: Offline curated core editing bindings and operator-motion cards.
  - **Neovim**: Shipped default upstream reference table; no user configuration is read.
  - **LazyVim**: Shipped upstream table calibrated by bounded static reads of literal leader, extras, installed commit, and top-level keymap changes.
- **Arcade Dashboard & Progression**:
  - Home screen tracking every cabinet's cards, progress, and mastery status independently.
  - Visual first-time 100% mastery result with an optional official marketplace heart action.
  - Reset and "Start New Run" capabilities per cabinet.
- **Wayland Input Isolation**:
  - Integration with `zwlr_input_inhibit_manager_v1` ensuring all keystrokes during practice sessions are intercepted and judged locally without triggering system or desktop actions.
- **Automated CI/CD & Security Pipelines**:
  - GitHub Actions CI workflow running on Arch Linux container with container `--init` and non-root execution.
  - GitHub CodeQL Advanced Security scanning for Python and JavaScript/QML.
  - OpenSSF Scorecard supply chain security workflow.
  - Test coverage generation (74% backend coverage) with Codecov integration.
  - OpenSSF-compliant `SECURITY.md` vulnerability reporting policy.
- **Localization**:
  - Complete English and Simplified Chinese localization across all UI elements, tooltips, and documentation.

### Security & Hardening

- **Compliance with marketplace security invariants R1–R8**:
  - **R1 (No User Config Execution)**: User configuration is never executed or evaluated; declared readers accept only bounded literal shapes or read-only APIs.
  - **R2 (Dual-Ended Bounds)**: Producers bound bytes, time, records, and child trees; QML independently validates and rebuilds retained models.
  - **R3 (Descriptor-Relative State I/O)**: State under `~/.local/state/omarchy/keycade/` rejects links and uses verified directory descriptors, 0600 temporary files, `fsync`, and atomic rename.
  - **R4 (Prototype Safety)**: Dynamic maps use null prototypes and reject prototype-special keys.
  - **R5 (Plain Text Dynamic UI)**: External text is stripped of controls and rendered through bounded plain-text components.
  - **R6 (Standard Packaging Only)**: Installation, updates, and removal use only Omarchy's plugin lifecycle.
  - **R7 (Hermetic Trusted Binaries)**: `/usr/bin/python3`, `/usr/bin/hyprctl`, `/usr/bin/tmux`, the root-owned Omarchy Herdr listing command, and required libraries are addressed absolutely and verified where opened by helpers; child environments are whitelisted.
  - **R8 (Incremental Consumption & Reaping)**: Streams are bounded while read and complete process groups are terminated and reaped.

### Testing

- 188 Python unit and security invariant regression tests.
- 92 QML algorithm tests verified with Qt6 `qmltestrunner`.
- 5 comprehensive QML shell integration test scripts.
- Component syntax validation using `qmllint`.
