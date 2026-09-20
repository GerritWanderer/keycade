"""Run the real asynchronous StateStore boundary in isolated offscreen Quickshell."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests/fixtures/migration"


def fixture(name):
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


class StateConsumerTests(unittest.TestCase):
    def exercise(self, settings, body="", stats=None, deferred=False, session=None,
                 relaunch=False, early_declarations=False):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            runtime = home / "runtime"
            runtime.mkdir(mode=0o700)
            environment = {"PATH": "/usr/bin", "HOME": directory, "XDG_RUNTIME_DIR": str(runtime),
                           "XDG_STATE_HOME": str(home / "state"), "XDG_CONFIG_HOME": str(home / "config"),
                           "XDG_CACHE_HOME": str(home / "cache"), "QT_QPA_PLATFORM": "offscreen",
                           "QT_QPA_PLATFORMTHEME": "", "QT_STYLE_OVERRIDE": "Fusion"}
            for kind, value in (("settings", settings), ("stats", stats), ("session", session)):
                if value is not None:
                    subprocess.run([str(ROOT / "bin/state-store"), "write", kind],
                                   input=json.dumps(value).encode() + b"\n", env=environment,
                                   check=True, capture_output=True, timeout=5)
            shell = home / "shell.qml"
            shell.write_text(('''import QtQuick
import Quickshell
import "%s" as State
import "%s" as DeckState
import "__STATS_URL__" as Stats
Scope {
  id: root
  property bool exercised: false
  property var report: null
  property int refusals: 0
  property bool deferred: %s
  property bool earlyDeclarations: %s
  Component.onCompleted: if (root.earlyDeclarations) store.setDeclaredDeckIds(["all", "zz-declared"])
  function check(condition, message) { if (!condition) throw new Error(message) }
  State.StateStore {
    id: store
    onDeckCardsRefused: function(reason) { root.refusals++; root.check(reason.length < 64, "bounded refusal") }
    onFailed: function(message) { root.report = { failure: message }; finish.start() }
    onReadyChanged: {
      if (!ready || root.exercised) return
      root.exercised = true
      try {
        %s
        root.report = { ready: store.ready, settings: store.settings, stats: store.stats, session: store.session,
                        identityPrepared: store.runIdentityPrepared, sessionCorrupt: store.sessionCorrupt,
                        corrupt: store.settingsCorrupt, statsCorrupt: store.statsCorrupt,
                        refusals: root.refusals, error: store.error }
      } catch (error) { root.report = { failure: String(error) } }
      finish.start()
    }
  }
  Timer {
    interval: 10; running: !root.earlyDeclarations; repeat: true
    onTriggered: {
      // Wait for the actual helper load, not a copied parser or stub. The
      // withheld declarations model a slower config result on a cold launch.
      if (!store.settingsLoaded || !store.sessionLoaded || store.currentOperation) return
      stop()
      try {
        if (root.deferred) {
          root.check(!store.statsLoaded && !store.ready, "stats deferred")
          root.check(store.pendingStatsRaw !== null, "bounded raw retained")
          root.check(store.pendingStatsRaw.length <= store.fileLimits.stats, "pending cap")
          root.check(Object.keys(store.stats.decks).length === 0, "no guessed pruning")
          store.saveStats()
          root.check(store.operations.filter(function(op) { return op.kind === "stats" }).length === 0,
                     "no premature stats write")
        }
        store.setDeclaredDeckIds(["all", "zz-declared"])
      } catch (error) { root.report = { failure: String(error) }; finish.start() }
    }
  }
  Timer {
    id: finish; interval: 20; repeat: true
    onTriggered: {
      if (!root.report || (!root.report.failure && (store.currentOperation || store.operations.length))) return
      console.log("STATE-RESULT " + JSON.stringify(root.report)); Qt.quit()
    }
  }
  Timer {
    interval: 8000; running: true
    onTriggered: { console.log('STATE-RESULT {"failure":"timeout"}'); Qt.quit() }
  }
}
''' % ((ROOT / "lib").as_uri(), (ROOT / "lib/DeckState.js").as_uri(),
       "true" if deferred else "false", "true" if early_declarations else "false",
       body)).replace("__STATS_URL__", (ROOT / "lib/Stats.js").as_uri()), encoding="utf-8")
            launch_reports = []
            for _ in range(2 if relaunch else 1):
                # A second launch reopens these same files; it does not reseed
                # state or replace the malformed session with a clean fixture.
                completed = subprocess.run(["/usr/bin/quickshell", "--no-color", "--path", str(shell)],
                                           env=environment, capture_output=True, text=True, timeout=12)
                output = completed.stdout + completed.stderr
                self.assertEqual(completed.returncode, 0, output)
                reports = [line.split("STATE-RESULT ", 1)[1] for line in output.splitlines()
                           if "STATE-RESULT " in line]
                self.assertEqual(len(reports), 1, output)
                launch_report = json.loads(reports[0])
                self.assertNotIn("failure", launch_report, output)
                launch_reports.append(launch_report)
            report = launch_reports[0]
            if relaunch:
                report["relaunch"] = launch_reports[1]
            state = home / "state/omarchy/keycade"
            disk = {path.name: path.read_text(encoding="utf-8") for path in state.iterdir()}
            return report, disk

    def test_settings_v1_through_v3_preserve_preferences_and_every_exclusion(self):
        for version in (1, 2, 3):
            with self.subTest(version=version):
                source = fixture(f"settings-v{version}.json")
                report, disk = self.exercise(source)
                expected = {key: value for key, value in source.items() if key != "activeProfile"}
                expected.update(schemaVersion=4, activeDeck="all", deckCards={})
                self.assertEqual(report["settings"], expected)
                self.assertEqual(json.loads(disk["settings.json"]), expected)
                self.assertFalse(report["corrupt"])

    def test_all_historical_profile_selections_map_to_all(self):
        # Exercise normalization on the actual StateStore for every historical
        # schema and selector, including invalid and absent selector values.
        self.exercise(fixture("settings-v3.json"), '''
          var profiles = ["lazyvim", "hyprland", "herdr", "tmux", "vim", "neovim", "unknown", "__proto__", null]
          for (var version = 1; version <= 3; version++) {
            profiles.forEach(function(profile) {
              var value = store.normalizedSettings({schemaVersion: version, activeProfile: profile,
                                                    activeDeck: "lsp"})
              root.check(value.activeDeck === "all" && value.activeProfile === undefined, "historical selection")
            })
          }
          root.check(store.normalizedSettings({schemaVersion:1,soundEnabled:false}).feedbackSound === false,
                     "historical soundEnabled preference")
          root.check(store.normalizedSettings({schemaVersion:2,soundVolume:0.3}).soundVolume === 0.4,
                     "historical v2 volume correction")
        ''')

    def test_v4_roundtrip_keeps_deleted_decks_missing_cards_and_preferences(self):
        source = fixture("settings-v4.json")
        report, disk = self.exercise(source, '''
          root.check(Object.getPrototypeOf(store.settings.deckCards) === null, "safe map")
          store.saveSettings()
        ''')
        self.assertEqual(report["settings"], source)
        self.assertEqual(json.loads(disk["settings.json"]), source)

    def test_real_boundary_refuses_utf8_cap_atomically_and_nonfatally(self):
        report, disk = self.exercise(fixture("settings-v4.json"), '''
          root.check(store.setDeckCard("curated", "lazyvim/normal/gd", "add"), "add")
          root.check(store.setDeckCard("curated", "lazyvim/normal/gd", "remove"), "remove")
          root.check(store.settings.deckCards.curated.added.length === 0, "opposite cleared")
          root.check(store.setDeckCard("curated", "lazyvim/normal/gd", "reset"), "reset")
          root.check(store.settings.deckCards["deleted-deck"].added[0] === "lazyvim/normal/missing", "orphans retained")
          var next = { deck: { added: [], removed: [] } }
          for (var i = 0; i < 8; i++) next.deck.added.push("lazyvim/" + i + "名".repeat(1000))
          var gap = DeckState.MAX_BYTES - DeckState.serializedBytes(next)
          next.deck.added.push("x/" + "a".repeat(gap - 5))
          store.settings.deckCards = DeckState.normalize(next)
          store.saveSettings()
          var before = JSON.stringify(store.settings)
          var queued = JSON.stringify(store.operations)
          root.check(!store.setDeckCard("new-deck", "lazyvim/new", "add"), "overflow refused")
          root.check(store.deckCardsRefusal === "deck-cards-limit", "specific reason")
          root.check(JSON.stringify(store.settings) === before, "previous deltas untouched")
          root.check(JSON.stringify(store.operations) === queued, "no refusal write")
          root.check(store.ready && !store.error, "nonfatal refusal")
          root.check(!store.setDeckCard("__proto__", "lazyvim/new", "add"), "prototype refused")
          root.check(JSON.stringify(store.settings) === before, "invalid mutation atomic")
        ''')
        self.assertEqual(report["refusals"], 2)
        self.assertEqual(report["error"], "")
        saved = json.loads(disk["settings.json"])
        self.assertEqual(saved, report["settings"])
        self.assertEqual(len(json.dumps(saved["deckCards"], ensure_ascii=False,
                                       separators=(",", ":")).encode("utf-8")), 24 * 1024)
        self.assertEqual(saved["excludedBindings"], fixture("settings-v4.json")["excludedBindings"])

    def test_invalid_schema_shape_prototypes_and_overcap_use_quarantine(self):
        cases = [fixture("settings-v4-hostile.json"), fixture("settings-v4-overcap.json"),
                 {"schemaVersion": 5}, {"schemaVersion": 4, "deckCards": []},
                 {"schemaVersion": 4, "deckCards": {"safe": {"added": ["unqualified"], "removed": []}}}]
        for source in cases:
            with self.subTest(source=str(source)[:80]):
                report, disk = self.exercise(source)
                self.assertTrue(report["corrupt"])
                self.assertEqual(report["settings"]["deckCards"], {})
                self.assertEqual(report["error"], "")
                quarantined = [name for name in disk if name.startswith("settings.json.corrupt-")]
                self.assertEqual(len(quarantined), 1, disk.keys())
                self.assertEqual(json.loads(disk[quarantined[0]]), source)
                self.assertNotIn("settings.json", disk)

    def test_stats_load_and_save_wait_for_final_declared_ids(self):
        source = fixture("stats-v5-overcap.json")
        report, disk = self.exercise(fixture("settings-v4.json"), stats=source, deferred=True)
        result = json.loads(disk["stats.json"])
        self.assertEqual(report["stats"], result)
        self.assertEqual(len(result["decks"]), 48)
        self.assertEqual(result["decks"]["zz-declared"]["runs"], 99)
        self.assertEqual(set(result["decks"]), {"all", "zz-declared"} |
                         {f"orphan-{i:02d}" for i in range(46)})
        self.assertEqual(json.dumps(source["bindings"], sort_keys=True),
                         json.dumps(result["bindings"], sort_keys=True))
        self.assertFalse(any("corrupt" in name for name in disk))

    def test_pending_legacy_identity_reserved_before_ready_and_survives_restart(self):
        pending = {"schemaVersion": 1, "profileId": "lazyvim", "runId": 77,
                   "cards": [{"bindingId": "lazyvim/normal/<leader>ff", "tier": "learning", "queue": "due"}]}
        report, disk = self.exercise(fixture("settings-v4.json"), '''
          root.check(store.runIdentityPrepared, "adopted before ready")
          root.check(store.stats.runSequence === 77, "pending legacy reservation")
          root.check(Stats.peekRunIdentity(store.stats) === 78, "next identity above pending")
          root.check(Stats.adoptRunIdentity(store.stats, store.session.runId) === 77, "resume")
          root.check(Stats.adoptRunIdentity(store.stats, store.session.runId) === 77, "repeat resume")
          root.check(store.stats.runSequence === 77, "resume did not allocate")
        ''', stats=fixture("stats-v4.json"), session=pending, deferred=True)
        saved = json.loads(disk["stats.json"])
        self.assertEqual(saved["runSequence"], 77)
        self.assertEqual(report["session"]["runId"], 77)
        self.assertEqual(json.loads(disk["session.json"])["runId"], 77)
        self.assertEqual(saved["bindings"], fixture("stats-v4.json")["bindings"])
        # Reopening keeps the same identity, but abandoning and starting a new
        # session consumes the next one without incrementing visible counters.
        report, disk = self.exercise(fixture("settings-v4.json"), '''
          root.check(store.stats.runSequence === 77, "reopened high-water")
          root.check(Stats.allocateRunIdentity(store.stats) === 78, "restart gets new identity")
          store.clearSession()
          store.saveStats()
        ''', stats=saved, session=pending)
        restarted = json.loads(disk["stats.json"])
        self.assertEqual(restarted["runSequence"], 78)
        self.assertEqual(restarted["decks"], saved["decks"])
        self.assertNotIn("session.json", disk)
        report, _ = self.exercise(fixture("settings-v4.json"), '''
          root.check(Stats.allocateRunIdentity(store.stats) === 79, "abandoned identity not reused")
        ''', stats=restarted)
        self.assertEqual(report["stats"]["runSequence"], 79)

    def test_stats_save_callbacks_wait_for_late_session_adoption(self):
        report, disk = self.exercise(fixture("settings-v4.json"), '''
          store.sessionLoaded = false
          store.runIdentityPrepared = false
          store.session = null
          store.loadStats(JSON.stringify({schemaVersion: 4, profiles: {lazyvim: {runs: 2}}, bindings: {}}))
          store.saveStats()
          root.check(!store.ready && store.statsSavePending, "save deferred until session loaded")
          Qt.callLater(function() {
            try {
              root.check(!store.currentOperation && store.operations.length === 0, "no earlier stats write")
              store.loadSession(JSON.stringify({schemaVersion: 1, profileId: "lazyvim", runId: 91, cards: []}))
              root.check(store.ready && store.stats.runSequence === 91, "adoption before readiness")
            } catch (error) { root.report = {failure: String(error)} }
          })
        ''', stats=fixture("stats-v5.json"))
        self.assertEqual(json.loads(disk["stats.json"])["runSequence"], 91)
        self.assertEqual(report["stats"]["runSequence"], 91)

    def test_foreign_pending_session_cannot_advance_run_sequence(self):
        pending = {"schemaVersion": 1, "profileId": "tmux", "runId": 1000000000,
                   "cards": [{"bindingId": "tmux/foreign"}]}
        report, _ = self.exercise(fixture("settings-v4.json"), stats=fixture("stats-v4.json"), session=pending)
        self.assertEqual(report["stats"]["runSequence"], 8)
        self.assertEqual(report["session"]["runId"], 1000000000)

    def test_valid_legacy_boundary_session_is_retained_and_can_resume(self):
        pending = {"schemaVersion": 1, "profileId": "lazyvim", "runId": 1000000000,
                   "cards": [{"bindingId": "lazyvim/normal/<leader>ff"}]}
        report, disk = self.exercise(fixture("settings-v4.json"), '''
          root.check(store.stats.runSequence === Stats.MAX_COUNTER, "boundary reserved")
          root.check(store.session.runId === Stats.MAX_COUNTER && !store.sessionCorrupt, "legacy boundary retained")
          root.check(Stats.adoptRunIdentity(store.stats, store.session.runId) === Stats.MAX_COUNTER, "boundary resume")
          root.check(Stats.peekRunIdentity(store.stats) === 0, "no successor")
          var refused = false
          try { Stats.allocateRunIdentity(store.stats) } catch (error) { refused = true }
          root.check(refused && store.ready, "new allocation refused without dropping valid resume")
        ''', stats=fixture("stats-v4.json"), session=pending)
        self.assertTrue(report["identityPrepared"])
        self.assertFalse(any("corrupt" in name for name in disk))
        self.assertEqual(json.loads(disk["session.json"]), pending)
        saved = json.loads(disk["stats.json"])
        self.assertEqual(saved["runSequence"], 1000000000)
        self.assertEqual(saved["bindings"], fixture("stats-v4.json")["bindings"])

    def test_hostile_pending_identity_is_quarantined_nonfatally_and_relaunch_recovers(self):
        stats = fixture("stats-v5.json")
        for early in (True, False):
            for identity in (0, -1, 1.5, "17", 1000000001, None, True):
                with self.subTest(identity=identity, early_declarations=early):
                    pending = {"schemaVersion": 1, "profileId": "lazyvim", "runId": identity, "cards": []}
                    report, disk = self.exercise(fixture("settings-v4.json"), '''
                      root.check(store.ready && !store.error, "bad session must not block startup")
                      root.check(store.session === null, "invalid identity never adopted or clamped")
                      root.check(store.stats.runSequence === 7, "valid sequence unchanged")
                      root.check(Stats.peekRunIdentity(store.stats) === 8, "invalid input consumed no identity")
                    ''', stats=stats, session=pending, relaunch=True, early_declarations=early)
                    for launch in (report, report["relaunch"]):
                        self.assertTrue(launch["ready"])
                        self.assertTrue(launch["identityPrepared"])
                        self.assertEqual(launch["error"], "")
                        self.assertIsNone(launch["session"])
                        self.assertEqual(launch["stats"], stats)
                    self.assertTrue(report["sessionCorrupt"])
                    self.assertFalse(report["relaunch"]["sessionCorrupt"])
                    self.assertEqual(json.loads(disk["stats.json"]), stats)
                    self.assertNotIn("session.json", disk)
                    quarantined = [name for name in disk if name.startswith("session.json.corrupt-")]
                    self.assertEqual(len(quarantined), 1, disk.keys())
                    self.assertEqual(json.loads(disk[quarantined[0]]), pending)

    def test_deck_scoped_session_reserves_identity_even_if_declaration_is_missing(self):
        pending = {"schemaVersion": 2, "deckId": "missing-deck", "runId": 77,
                   "runNumber": 1, "sessionSize": 1, "offset": 0,
                   "cards": [{"bindingId": "lazyvim/normal/<leader>ff", "tier": "learning", "queue": "due"}],
                   "correct": 0, "attempts": 0, "newLearned": 0, "masteredGained": 0,
                   "runReviewTarget": 1, "runNewTarget": 0}
        for early in (False, True):
            with self.subTest(early=early):
                report, disk = self.exercise(fixture("settings-v4.json"), '''
                  root.check(store.stats.runSequence === 77, "deck identity reserved before readiness")
                  root.check(Stats.peekRunIdentity(store.stats) === 78, "no orphan-session identity reuse")
                  root.check(store.session.deckId === "missing-deck", "undeclared session retained")
                ''', stats=fixture("stats-v5.json"), session=pending,
                    early_declarations=early, relaunch=True)
                self.assertEqual(report["relaunch"]["stats"]["runSequence"], 77)
                self.assertEqual(json.loads(disk["stats.json"])["runSequence"], 77)
                self.assertEqual(json.loads(disk["session.json"]), pending)

    def test_hostile_deck_session_identity_uses_nonfatal_quarantine_and_recovery(self):
        for early in (False, True):
            for identity in (0, -1, 1.5, "17", 1000000001, None, True):
                with self.subTest(early=early, identity=identity):
                    pending = {"schemaVersion": 2, "deckId": "zz-declared", "runId": identity,
                               "runNumber": 1, "sessionSize": 0, "offset": 0, "cards": [],
                               "correct": 0, "attempts": 0, "newLearned": 0, "masteredGained": 0,
                               "runReviewTarget": 0, "runNewTarget": 0}
                    report, disk = self.exercise(fixture("settings-v4.json"), '''
                      root.check(store.ready && !store.error && !store.session, "nonfatal quarantine")
                      root.check(store.stats.runSequence === 7, "invalid identity not adopted")
                    ''', stats=fixture("stats-v5.json"), session=pending,
                        early_declarations=early, relaunch=True)
                    self.assertTrue(report["sessionCorrupt"])
                    self.assertFalse(report["relaunch"]["sessionCorrupt"])
                    self.assertEqual(report["stats"], fixture("stats-v5.json"))
                    self.assertNotIn("session.json", disk)
                    quarantines = [name for name in disk if name.startswith("session.json.corrupt-")]
                    self.assertEqual(len(quarantines), 1)
                    self.assertEqual(json.loads(disk[quarantines[0]]), pending)

    def test_invalid_current_stats_shape_is_quarantined(self):
        report, disk = self.exercise(fixture("settings-v4.json"),
                                    stats={"schemaVersion": 5, "bindings": {}, "decks": []})
        self.assertTrue(report["statsCorrupt"])
        self.assertEqual(report["stats"]["decks"], {})
        self.assertTrue(any(name.startswith("stats.json.corrupt-") for name in disk))


if __name__ == "__main__":
    unittest.main()
