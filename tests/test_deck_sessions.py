"""Real deck/store/source/session wiring, without focus or personal state writes.

The temporary copy replaces only the focus guard and PanelWindow shell with
noninteractive Items. Store helpers, reader, pack calibration, scheduler,
session methods and disk writes are real. Temporary timers force both startup
orderings. No compositor, exclusive focus, or personal runtime files are used.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PACK = json.loads((ROOT / "assets/packs/lazyvim.json").read_text())
IDS = ["lazyvim/" + card["localId"] for card in PACK["bindings"] if not card["extras"]][:8]

GUARD = '''import QtQuick
Item {
  property var window: null
  property bool keyboardFocused: false
  property bool wantsFocus: false
  property bool active: true
  property int plays: 0
  signal ready()
  signal blocked(string message)
  signal closed()
  function begin() { ready() }
  function pause() {}
  function play() { plays++ }
  function updateInput(mask) {}
  function requestClose() { closed() }
  function fail(message) { blocked(message) }
}
'''


class DeckSessionIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.app = self.home / "app"
        self.app.mkdir()
        shutil.copy(ROOT / "Keycade.qml", self.app)
        for directory in ("lib", "bin", "assets"):
            shutil.copytree(ROOT / directory, self.app / directory)
        (self.app / "lib/InputGuard.qml").write_text(GUARD)
        runtime = self.home / "runtime"
        runtime.mkdir(mode=0o700)
        self.env = dict(os.environ, HOME=str(self.home), XDG_CONFIG_HOME=str(self.home / "config"),
                        XDG_STATE_HOME=str(self.home / "state"), XDG_CACHE_HOME=str(self.home / "cache"),
                        XDG_DATA_HOME=str(self.home / "data"), QT_QPA_PLATFORMTHEME="", QT_STYLE_OVERRIDE="Fusion",
                        XDG_RUNTIME_DIR=str(runtime), QT_QPA_PLATFORM="offscreen")
        config = self.home / "config/omarchy/keycade-lazyvim"
        config.mkdir(parents=True)
        (config / "decks.json").write_text(json.dumps({"schemaVersion": 1, "decks": [
            {"id": "git", "name": "Git"}, {"id": "lsp", "name": "Shared"},
            {"id": "empty", "name": "Empty"}, {"id": "zz-declared", "name": "Last"}]}))
        self.settings = {"schemaVersion": 4, "activeDeck": "git", "feedbackSound": False,
                         "countdownSound": False, "excludedBindings": ["lazyvim:" + IDS[6][8:]],
                         "deckCards": {"git": {"added": IDS[:7], "removed": []},
                                       "lsp": {"added": IDS[:1], "removed": []},
                                       "missing-deck": {"added": [IDS[7]], "removed": []}}}
        self.stats = {"schemaVersion": 5, "runSequence": 40, "bindings": {},
                      "decks": {"git": {"runs": 2}, "zz-declared": {"runs": 9}}}
        # Cap pressure proves the final configuration, not guessed defaults,
        # protects the last declared record during either startup ordering.
        self.stats["decks"].update({f"orphan-{i:02}": {"runs": i} for i in range(55)})
        self.write_state("settings", self.settings)
        self.write_state("stats", self.stats)

    def write_state(self, kind, value):
        subprocess.run([str(ROOT / "bin/state-store"), "write", kind], env=self.env,
                       input=json.dumps(value) + "\n", text=True, capture_output=True, check=True, timeout=5)

    def read_state(self, kind):
        return json.loads((self.home / f"state/omarchy/keycade-lazyvim/{kind}.json").read_text())

    def launch(self, body, ordering="config-first"):
        # Delay delivery, not validation. Both helpers still run against the
        # isolated HOME and the production bounded descriptor-relative paths.
        qml = (ROOT / "Keycade.qml").read_text().replace("  id: root\n", """  id: root
  property alias testStore: store
  property alias testGuard: guard
  property bool testConfigBeforeSettings: false
  property bool testSettingsBeforeConfig: false
  Timer { id: delayedConfig; interval: 600; onTriggered: root.applyDetectedConfig() }
""", 1)
        qml = qml.replace("    var resolved = Decks.definitions(appConfig.deckConfig)", """    root.testConfigBeforeSettings = !store.settingsLoaded
    root.testSettingsBeforeConfig = store.settingsLoaded
    var resolved = Decks.definitions(appConfig.deckConfig)""")
        # This integration owns the engine, not the window/guard lifecycle.
        # Keep the real child UI objects so engine references still resolve,
        # but provide no native window or compositor connection at all.
        panel = '''  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "keycade-lazyvim"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: guard.wantsFocus ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore'''
        self.assertIn(panel, qml)
        qml = qml.replace(panel, '''  Item {
    id: panel
    visible: false
    width: 1280; height: 800''')
        if ordering == "settings-first":
            qml = qml.replace("onFinished: root.applyDetectedConfig()", "onFinished: delayedConfig.start()")
        (self.app / "Keycade.qml").write_text(qml)
        store = (ROOT / "lib/StateStore.qml").read_text()
        if ordering == "config-first":
            store = store.replace('Component.onCompleted: root.enqueue({ action: "load" })',
                                  '''Component.onCompleted: delayedLoad.start()
  Timer { id: delayedLoad; interval: 600; onTriggered: root.enqueue({ action: "load" }) }''')
        (self.app / "lib/StateStore.qml").write_text(store)
        shell = self.home / "shell.qml"
        shell.write_text('''import QtQuick
import Quickshell
import "app" as App
import "app/lib/Stats.js" as Stats
import "app/lib/Session.js" as Session
Scope {
  id: test
  App.Keycade { id: overlay }
  property bool exercised: false
  property var report: null
  function check(value, message) { if (!value) throw new Error(message) }
  Timer {
    interval: 20; running: true; repeat: true
    onTriggered: {
      if (test.exercised || !overlay.stateReady || overlay.groundLoading) return
      test.exercised = true
      try {
        check(!overlay.opened && !overlay.testGuard.wantsFocus, "never opens/focuses overlay")
        check(overlay.testStore.declaredDeckIds.join(",") === "all,git,lsp,empty,zz-declared", "final declarations")
        check(overlay.testStore.stats.decks["zz-declared"].runs === 9, "declared counter protected")
        check(Object.keys(overlay.testStore.stats.decks).length === 48, "counter cap")
        %s
        test.report = { ok: true, session: overlay.testStore.session, stats: overlay.testStore.stats,
                        sessionSize: overlay.sessionSize }
      } catch (error) { test.report = { failure: String(error) } }
    }
  }
  Timer {
    interval: 20; running: true; repeat: true
    onTriggered: {
      if (!test.report || overlay.testStore.currentOperation || overlay.testStore.operations.length) return
      console.log("DECK-RESULT " + JSON.stringify(test.report)); Qt.quit()
    }
  }
  Timer { interval: 10000; running: true
    onTriggered: { console.log('DECK-RESULT {"failure":"timeout"}'); Qt.quit() } }
}
''' % body)
        completed = subprocess.run(["/usr/bin/quickshell", "--no-color", "--path", str(shell)], env=self.env,
                                   capture_output=True, text=True, timeout=15)
        output = completed.stdout + completed.stderr
        self.assertEqual(completed.returncode, 0, output)
        reports = [line.split("DECK-RESULT ", 1)[1] for line in output.splitlines() if "DECK-RESULT " in line]
        self.assertEqual(len(reports), 1, output)
        report = json.loads(reports[0])
        self.assertNotIn("failure", report, output)
        return report

    def test_both_startup_orders_use_loaded_exclusions_and_final_declarations(self):
        for order in ("config-first", "settings-first"):
            with self.subTest(order=order):
                self.launch('''
                  check(overlay.%s, "forced startup ordering")
                  check(overlay.deckId === "git", "saved active deck")
                  check(overlay.eligibleBindings.length === 6, "exclusion on first load")
                  check(overlay.deckProgress.git.total === 6, "live progress on first load")
                  check(!overlay.cardsForDeck("all").some(function(c) {return c.id === %s}), "excluded from all")
                  check(overlay.testStore.stats.runSequence === 40, "reads allocate no identities")
                  overlay.view = "home"
                  check(overlay.selectDeck("empty"), "empty deck selectable")
                  overlay.startRun()
                  check(overlay.view === "home" && overlay.startRefusal === "empty-deck", "empty refused nonfatally")
                  check(overlay.testGuard.plays === 0 && overlay.testStore.stats.runSequence === 40, "no empty session")
                  check(!overlay.selectDeck("missing-deck"), "orphan unselectable")
                  check(overlay.selectDeck("git"), "switch back")
                ''' % ("testConfigBeforeSettings" if order == "config-first" else "testSettingsBeforeConfig",
                       json.dumps(IDS[6])), order)

    def create_interrupted(self):
        return self.launch('''
          overlay.view = "home"
          overlay.startRun()
          check(overlay.deck.length === 6 && overlay.sessionSize === 6, "six unique cards")
          check(overlay.activeRunId === 41 && overlay.runNumber === 3, "global identity/local display")
          check(!overlay.selectDeck("lsp") && overlay.deckId === "git", "no mid-run switch")
          var ids = overlay.deck.map(function(c) {return c.binding.id})
          check((new Set(ids)).size === ids.length, "initial deal unique")
          overlay.hitCurrent()
          overlay.advanceCard()
          overlay.deck[overlay.cardIndex].tier = "learning"
          overlay.missCurrent("received", "wrong")
          check(overlay.correctionRequired, "pending correction")
          overlay.leaveRun()
          check(overlay.hasResumableSession(), "saved session")
          check(overlay.testStore.session.schemaVersion === 2 && overlay.testStore.session.deckId === "git", "deck scope")
          check(overlay.testStore.session.offset === 1, "completed offset saved")
          check(overlay.testStore.session.cards.length === 5, "remaining cards saved")
          check(overlay.testStore.stats.decks.git.runs === 2, "interruption not completion")
          check(overlay.selectDeck("lsp") && !overlay.resumeAvailable, "foreign deck cannot resume")
          check(overlay.selectDeck("git") && overlay.resumeAvailable, "original deck resumes")
        ''')

    def test_exact_disk_resume_keeps_score_correction_offset_and_global_identity(self):
        before = self.create_interrupted()["session"]
        persisted = self.read_state("session")
        self.assertEqual(before, persisted)
        stats = self.read_state("stats")
        self.assertEqual(stats["runSequence"], 41)
        resumed = self.launch('''
          overlay.view = "home"
          check(overlay.resumeAvailable && overlay.activeRunId === 41, "adopted pending identity")
          check(overlay.runNumber === 3 && overlay.sessionSize === 6, "adopted size/display")
          var saved = JSON.stringify(overlay.testStore.session)
          overlay.resumeRun()
          check(overlay.view === "playing" && overlay.runOffset === 1, "resumed offset")
          check(overlay.correctionRequired, "correction restored")
          check(overlay.deck.length === 5 && overlay.sessionSize === 6, "remaining queue and denominator")
          check(overlay.testStore.stats.runSequence === 41, "resume did not allocate")
          overlay.leaveRun()
        ''', "settings-first")["session"]
        for key in before.keys() - {"savedAt"}:
            self.assertEqual(resumed[key], before[key], key)
        self.assertEqual(self.read_state("stats")["bindings"], stats["bindings"])

    def test_changed_membership_shrinks_resume_preserving_history_and_original_plan(self):
        original = self.create_interrupted()["session"]
        stats = self.read_state("stats")
        removed = original["cards"][0]["bindingId"]
        settings = self.read_state("settings")
        settings["deckCards"]["git"]["removed"] = [removed]
        self.write_state("settings", settings)
        remaining = [card for card in original["cards"] if card["bindingId"] != removed]
        after = self.launch('''
          overlay.view = "home"
          overlay.resumeRun()
          check(overlay.view === "playing" && overlay.sessionSize === %d, "shrunken resumed size")
          check(overlay.runOffset === 1 && overlay.deck.length === %d, "offset preserved")
          check(!overlay.correctionRequired, "removed current card correction not transferred")
          overlay.leaveRun()
        ''' % (1 + len(remaining), len(remaining)))["session"]
        self.assertEqual(after["cards"], remaining)
        for key in ("correct", "attempts", "newLearned", "masteredGained", "runResults",
                    "runReviewTarget", "runNewTarget", "runId", "runNumber", "offset"):
            self.assertEqual(after[key], original[key], key)
        self.assertEqual(self.read_state("stats")["bindings"], stats["bindings"])
        # Entire remaining queue vanishes: no phantom resume or 0/0 mastery.
        settings["deckCards"]["git"]["removed"] = IDS[:7]
        self.write_state("settings", settings)
        self.launch('''
          overlay.view = "home"
          check(!overlay.resumeAvailable && !overlay.hasResumableSession(), "no zero-remaining resume")
          check(overlay.progressCounts.total === 0, "zero membership")
          check(!overlay.checkFirstMastery(3), "no zero/zero mastery")
          overlay.startRun()
          check(overlay.view === "home" && overlay.startRefusal === "empty-deck", "zero start refused")
          check(overlay.testStore.stats.runSequence === 41, "no phantom allocation")
        ''')

    def test_run_exclusion_shrinks_remaining_queue_without_erasing_results(self):
        original = self.create_interrupted()["session"]
        after = self.launch('''
          overlay.view = "home"
          overlay.resumeRun()
          var id = overlay.currentBinding.id
          var history = JSON.stringify(overlay.testStore.stats.bindings)
          var results = JSON.stringify(Session.serializableResults(overlay.runResults))
          var remaining = overlay.deck.filter(function(card) {return card.binding.id !== id}).length
          overlay.excludeCurrentBinding()
          check(overlay.excludeStampVisible, "real exclusion gesture accepted")
          check(!overlay.cardsForDeck("all").some(function(c) {return c.id === id}), "global exclusion")
          // Drive the stamp's completion without waiting on wall-clock UI.
          overlay.dropExcludedCard(id)
          check(overlay.sessionSize === overlay.runOffset + remaining, "shrunken playable size")
          check(JSON.stringify(overlay.testStore.stats.bindings) === history, "history unchanged")
          check(JSON.stringify(Session.serializableResults(overlay.runResults)) === results, "results unchanged")
          overlay.leaveRun()
        ''')["session"]
        for key in ("correct", "attempts", "newLearned", "masteredGained", "runResults",
                    "runReviewTarget", "runNewTarget", "runId", "runNumber", "offset"):
            self.assertEqual(after[key], original[key], key)
        removed = original["cards"][0]["bindingId"]
        self.assertEqual(after["cards"], [c for c in original["cards"] if c["bindingId"] != removed])
        self.assertEqual(after["sessionSize"], after["offset"] + len(after["cards"]))

    def test_small_deck_mastery_counts_time_and_celebrates_once_per_deck(self):
        self.launch('''
          var store = overlay.testStore
          overlay.view = "home"
          check(overlay.setDeckCard("git", overlay.eligibleBindings[5].id, "remove"), "curation uses atomic store API")
          check(overlay.eligibleBindings.length === 5, "five-card custom deck")
          overlay.eligibleBindings.forEach(function(card) {
            Stats.recordGuided(store.stats, card.id, 40, 1)
            Stats.recordFirstTry(store.stats, card.id, true, 300, 40, 2)
          })
          overlay.view = "home"
          overlay.startRun()
          overlay.activeSegmentStartedAt = Date.now() - 1000
          while (overlay.view === "playing") {
            overlay.hitCurrent()
            if (overlay.view === "playing") overlay.advanceCard()
          }
          check(overlay.view === "mastery", "small deck celebrates")
          check(store.stats.decks.git.runs === 3 && store.stats.decks.git.firstMasteryRun === 3, "local mastery/run")
          check(store.stats.decks.git.totalTrainingMs >= 1000, "deck study time")
          check(store.stats.decks.git.firstMasteryCelebrated, "once marker")
          check(overlay.deckProgress.lsp.mastered === 1, "shared progress propagated")
          check(overlay.selectDeck("lsp"), "select shared deck")
          overlay.startRun()
          check(overlay.sessionSize === 1 && overlay.activeRunId === 42 && overlay.runNumber === 1, "one card/global id/local run")
          overlay.hitCurrent()
          check(overlay.view === "mastery", "one-card deck celebrates")
          check(store.stats.decks.lsp.runs === 1 && store.stats.decks.lsp.firstMasteryRun === 1, "local one-card milestone")
          check(store.stats.decks.git.runs === 3, "other deck counters unchanged")
          overlay.view = "home"
          overlay.startRun()
          overlay.hitCurrent()
          overlay.advanceCard()
          check(overlay.view === "summary", "no repeat celebration")
          check(store.stats.decks.lsp.runs === 2 && store.stats.runSequence === 43, "completed sessions distinct")
        ''')


if __name__ == "__main__":
    unittest.main()
