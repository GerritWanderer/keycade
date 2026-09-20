## Context

See `proposal.md` — Why. Three properties of the current code shape the decisions below.

1. **The plugin id is carried by the manifest, not the code.** `Keycade.qml` reads `root.manifest.id` and only falls back to a literal when the shell supplies no manifest. One file defines identity; the literals elsewhere are defaults and documentation.

2. **The two user directories have opposite ownership.** `bin/state-store` owns `${XDG_STATE_HOME}/omarchy/keycade/` and is the only writer. `${XDG_CONFIG_HOME}/omarchy/keycade/decks.json` belongs to the user and is read through `bin/app-config-json`, which never writes. D1 and D2 of `refactor-to-lazyvim-decks` make that split load-bearing.

3. **`refactor-to-lazyvim-decks` has not shipped.** Its specs, its design and the 2.0.0 state schemas are pending. The rename lands in the same release, so both describe one version rather than a rename layered on a published one.

## Goals / Non-Goals

**Goals**

- Move the identity without moving a single byte of learning history.
- Keep the migration inside the existing descriptor-relative discipline — no new pathname traversal, no new helper, no new write path.
- Leave the application unable to write to the user's configuration directory, exactly as before.
- Make a partially migrated machine behave predictably rather than silently blending two states.

**Non-Goals**

- Supporting both ids at once, or reading the old state directory after adoption.
- Preserving Hyprland keybindings, `layerrule`s or shell scripts a user wrote against the old id and namespace. These are documented, not automated.

## Decisions

### D1 — Keep the `keycade` prefix; the name states the scope

The published name becomes `keycade-lazyvim` and the display name `Keycade LazyVim`. The product is the same arcade under a name that no longer overpromises.

*Alternative considered:* an unrelated new name. Rejected — it discards the recognition the existing listing has, and the arcade framing is still what the UI is.

*Consequence:* the id, the repository, the state directory and the config directory all move together; the wordmark, the cabinet badge and every screenshot stay valid.

### D2 — The state directory is adopted once, through the already-verified parent descriptor

`open_state_directory()` opens `${XDG_STATE_HOME}` and then `omarchy/` as descriptors. Before opening `keycade-lazyvim/`, it checks that entry with `fstatat(AT_SYMLINK_NOFOLLOW)`; only when it is absent and `keycade/` is an owned directory does it `renameat` one to the other within that parent, then `fsync` the parent.

This keeps R3 intact: every component is still reached through a verified directory fd, nothing is opened by pathname, and a symlink at either name aborts the adoption rather than being followed. It costs one `stat` per launch once migration has happened.

*Alternative considered:* copying the three files into the new directory. Rejected — a copy is not atomic across three files, doubles the data on disk, and has to decide what to do when it fails halfway. A rename either happens or does not.

*Alternative considered:* leaving the state directory at `keycade/` and moving only the id. Rejected — it makes the next reader ask which product owns that directory, and the answer would only ever be found in a comment.

*Consequence:* adoption is invisible when it works. On a machine where both directories exist, the new one wins and the old one is left untouched for the user to inspect or delete; the application never deletes it.

### D3 — `decks.json` moves, and the application does not move it

The config path becomes `${XDG_CONFIG_HOME}/omarchy/keycade-lazyvim/decks.json`. An unmoved file is simply absent, which is an already-specified state: the shipped starter decks apply and training is never blocked.

*Alternative considered:* reading the old path as a fallback. Rejected — two live config paths is a permanent bound-checking surface and a permanent question about precedence, in exchange for saving one `mv`.

*Consequence:* the release notes must say plainly that a user with a `decks.json` has one command to run, and that nothing breaks if they do not run it.

### D4 — The wordmark stays; the subtitle carries the scope

`KEYCADE` stays at 32px in the top bar and `K` stays in the cabinet badge. `brandSubtitle` becomes `LAZYVIM RECALL ARCADE` (`LazyVim 快捷键记忆训练机`).

*Alternative considered:* `KEYCADE LAZYVIM` as the wordmark. Rejected — 15 glyphs at `pixelSize: 32` with `letterSpacing: 4` elides in the top bar it shares with the deck badge and the controls, and every screenshot in `docs/` would need reshooting on a live Wayland session.

### D5 — The layer-shell namespace follows the id

`WlrLayershell.namespace` becomes `keycade-lazyvim`, and the input probe becomes `keycade-lazyvim-input-probe`.

The namespace is how a compositor rule addresses this surface. Leaving it as `keycade` would keep one user-visible identifier pointing at the old name, and a user with rules for both plugins installed could not tell the surfaces apart.

*Consequence:* an existing `layerrule` matching `keycade` stops applying and is listed in the migration notes.

## Migration Plan

1. Install the new plugin; the first launch adopts the state directory.
2. `mv ~/.config/omarchy/keycade ~/.config/omarchy/keycade-lazyvim` if a `decks.json` exists.
3. Rebind the Hyprland shortcut — the binding embeds the id as both label and command.
4. Update any `layerrule` matching the `keycade` namespace.
5. `omarchy plugin remove luneth90.keycade`.

Order matters only in that step 5 comes last: removing the old plugin does not touch state, but running both installations before adoption would leave whichever launches first owning the directory.

## Risks / Trade-offs

- **A user runs the old and new plugins side by side.** The first new launch adopts `keycade/`, and the old installation then finds no state and starts fresh, writing a new `keycade/` directory. Mitigation: the migration notes tell the user to remove the old plugin, and adoption never deletes or merges.
- **The marketplace listing loses its hearts and install count.** Accepted: a new id is a new plugin, and there is no transfer mechanism.
- **Documentation drift.** 262 occurrences across 47 files; a stale one is a command that installs the wrong plugin. Mitigation: the verification gate greps for the bare name and accepts only the historical `CHANGELOG.md` entries.
