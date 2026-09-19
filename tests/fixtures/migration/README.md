# Pre-deck migration fixtures (WP0)

Synthetic snapshots of the supported on-disk shapes at commit `80e6b79`.
No personal configuration or state was read to create them.

- `settings-v3.json`: schema 3 as written by `StateStore.defaultSettings` /
  `normalizedSettings`, with non-default preferences and exclusions in all six
  existing card namespaces. Exclusions use `profile:localId` (unlike stats'
  `profile/localId` keys), matching `Session.excludedEntry` / `excludedList`.
  Migration must select `activeDeck: "all"`, retain
  preferences and exclusions, and introduce the bounded membership-delta map.
- `stats-v4.json`: schema 4 as written by `Stats.defaults`, `freshEntry`, and
  `freshProfile`. Includes counters and a mastered card for every existing
  namespace, plus a learning LazyVim card. Values are deliberately distinct to
  expose accidental cross-profile copies. All entries are already normalized.

Expected schema-5 migration: carry `profiles.lazyvim` to `decks.all`, preserve
its run/time/cursor/mastery fields, stop writing `knownTotal` / `knownMastered`,
and discard only retired **profile counters**. Every binding key and every
binding entry must remain identical; foreign-prefix entries become inert, not
removed. Compare parsed binding values (or each entry's canonical serialized
bytes), not whitespace of the enclosing JSON file.

Historical schemas and new-schema hostile/cap fixtures belong to WP4's test
matrix; these two files freeze the pre-refactoring shapes before teardown.
