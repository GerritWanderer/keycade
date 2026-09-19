"""Actual home deck-list UI behaviour, driven through the real component.

The temporary copy replaces only the focus guard and the PanelWindow shell;
the overlay, deck engine, store, reader, pack calibration and the real home
card delegates all run for real inside an offscreen Qt Quick window with the
software scene graph. Rows are scrolled into view and read back from the live
delegates, controls are driven through their own MouseAreas, and the render
grabs are saved outside the repository for visual inspection. No compositor,
exclusive focus, overlay.open(), or personal runtime files are used.
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
RENDER_DIR = Path("/tmp/keycade-wp7a-renders")
EMPTY_HINT = "EMPTY DECK — ADD CARDS WITH THE BROWSE DRAWER (COMING SOON)"
LONG_NAME = "Deck" + "名" * 44  # exactly 48 codepoints, multilingual
MARKUP_NAME = "<b>Nemesis</b> & <i>marks</i>"

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

PANEL = '''  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "keycade"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: guard.wantsFocus ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore'''

SHELL = '''import QtQuick
import QtQuick.Window
import Quickshell
import "app" as App
import "app/lib/Stats.js" as Stats

Scope {
  id: test
  property bool exercised: false
  property int phase: 0
  property var report: null
  property string renderTo: __RENDER_TO__

  function check(value, message) { if (!value) throw new Error(message) }

  function byName(item, name) {
    if (!item) return null
    if (item.objectName === name) return item
    if (item.item) {
      var viaItem = byName(item.item, name)
      if (viaItem) return viaItem
    }
    if (item.contentItem) {
      var viaContent = byName(item.contentItem, name)
      if (viaContent) return viaContent
    }
    var kids = item.children || []
    for (var index = 0; index < kids.length; index++) {
      var found = byName(kids[index], name)
      if (found) return found
    }
    return null
  }

  // Scroll the real delegate into view and read it back: id, texts, geometry.
  function rowAt(list, index) {
    list.positionViewAtIndex(index, ListView.Contain)
    var row = list.itemAtIndex(index)
    if (!row) throw new Error("row " + index + " not instantiated")
    return { row: row, id: row.objectName.split(":")[1],
             name: byName(row, "deckRowName"),
             counts: byName(row, "deckRowCounts"),
             area: byName(row, "deckRowArea") }
  }

  function finish(extra) {
    var payload = extra || {}
    if (test.renderTo !== "") {
      var panel = byName(overlay, "testPanel")
      var target = test.renderTo
      test.renderTo = ""
      if (!panel || !panel.grabToImage(function(result) {
        test.report = result.saveToFile(target)
            ? { ok: true, saved: target, extra: payload } : { failure: "grab save failed" }
      })) test.report = { failure: "grab refused" }
      return
    }
    test.report = { ok: true, extra: payload }
  }

  Window {
    id: win
    visible: true
    width: 1280
    height: 800
    color: "#05070e"
    App.Keycade { id: overlay; anchors.fill: parent }
  }

  Timer {
    interval: 25
    running: true
    repeat: true
    onTriggered: {
      if (test.exercised || !overlay.stateReady || overlay.groundLoading
          || !overlay.deckDefinitions.length) return
      if (test.phase === 0) { overlay.view = "home"; test.phase = 1; return }
      if (test.phase === 1) { overlay.testI18n.locale = __LOCALE__; test.phase = 2; return }
      if (test.phase === 2) { test.phase = 3; return } // settle locale/layout
      test.exercised = true
      try {
        test.check(overlay.view === "home", "home view")
        __BODY__
        test.finish({})
      } catch (error) { test.report = { failure: String(error) } }
    }
  }

  Timer {
    interval: 25
    running: true
    repeat: true
    onTriggered: {
      if (!test.report) return
      if (overlay.testStore.currentOperation || overlay.testStore.operations.length) return
      console.log("DECK-UI-RESULT " + JSON.stringify(test.report))
      Qt.quit()
    }
  }

  Timer {
    interval: 15000
    running: true
    onTriggered: { console.log('DECK-UI-RESULT {"failure":"timeout"}'); Qt.quit() }
  }
}
'''


class DeckHomeUiTests(unittest.TestCase):
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
                        XDG_RUNTIME_DIR=str(runtime), QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="software")
        RENDER_DIR.mkdir(parents=True, exist_ok=True)

    def write_state(self, kind, value):
        subprocess.run([str(ROOT / "bin/state-store"), "write", kind], env=self.env,
                       input=json.dumps(value) + "\n", text=True, capture_output=True, check=True, timeout=5)

    def write_decks(self, decks):
        config = self.home / "config/omarchy/keycade"
        config.mkdir(parents=True, exist_ok=True)
        (config / "decks.json").write_text(json.dumps({"schemaVersion": 1, "decks": decks}))

    def write_raw_decks(self, text):
        config = self.home / "config/omarchy/keycade"
        config.mkdir(parents=True, exist_ok=True)
        (config / "decks.json").write_text(text)

    def launch(self, body, render_to="", locale="en"):
        # Same isolation as the deck-session integration: test-only aliases,
        # no native window and no compositor connection. Here the panel stays
        # a sized, visible Item inside an offscreen window so the real home
        # delegates lay out and render. The locale is applied the way
        # maybeShowHome() applies the saved one once state is ready.
        qml = (ROOT / "Keycade.qml").read_text().replace("  id: root\n", """  id: root
  property alias testStore: store
  property alias testGuard: guard
  property alias testI18n: i18n
""", 1)
        self.assertIn(PANEL, qml)
        qml = qml.replace(PANEL, '''  Item {
    id: panel
    objectName: "testPanel"
    anchors.fill: parent''')
        (self.app / "Keycade.qml").write_text(qml)
        shell = self.home / "shell.qml"
        shell.write_text(SHELL.replace("__BODY__", body)
                              .replace("__RENDER_TO__", json.dumps(render_to))
                              .replace("__LOCALE__", json.dumps(locale)))
        completed = subprocess.run(["/usr/bin/quickshell", "--no-color", "--path", str(shell)],
                                   env=self.env, capture_output=True, text=True, timeout=30)
        output = completed.stdout + completed.stderr
        self.assertEqual(completed.returncode, 0, output)
        reports = [line.split("DECK-UI-RESULT ", 1)[1] for line in output.splitlines()
                   if "DECK-UI-RESULT " in line]
        self.assertEqual(len(reports), 1, output)
        report = json.loads(reports[0])
        self.assertNotIn("failure", report, output)
        return report

    def mastered_entry(self):
        return {"state": "mastered", "guidedCompleted": True, "dueAt": 0, "dueRun": 0,
                "intervalStep": 2, "firstTryAttempts": 2, "firstTryCorrect": 2,
                "recentFirstTry": [True, True], "reactions": [300, 320],
                "successfulRuns": [38, 39], "lastSuccessfulRun": 39, "lastSeenAt": 1, "lapseCount": 0}

    def test_starters_order_localized_names_and_live_start(self):
        # No decks.json: the shipped starters plus the reserved all deck.
        self.write_state("settings", {"schemaVersion": 4, "activeDeck": "all", "locale": "zh-CN",
                                      "feedbackSound": False, "countdownSound": False,
                                      "excludedBindings": [], "deckCards": {}})
        self.write_state("stats", {"schemaVersion": 5, "runSequence": 40,
                                   "bindings": {IDS[0]: self.mastered_entry(), IDS[1]: self.mastered_entry()},
                                   "decks": {"all": {"runs": 2}}})
        self.launch('''
          var list = test.byName(overlay, "deckList")
          test.check(list, "deck list exists")
          test.check(list.count === 5 && list.model.length === 5, "starters plus all")
          test.check(list.clip === true, "list clipped")
          test.check(list.width <= 470 && list.height <= 132, "list bounded")
          var expectedNames = ["全部", "导航", "LSP 与诊断", "搜索与查找", "Git"]
          var expectedIds = ["all", "navigation", "lsp", "search", "git"]
          var total = overlay.cardsForDeck("all").length
          test.check(total > 100, "real corpus")
          for (var i = 0; i < 5; i++) {
            var entry = test.rowAt(list, i)
            test.check(entry.id === expectedIds[i], "row " + i + " id: " + entry.id)
            test.check(entry.name.text === expectedNames[i], "row " + i + " localized name: [" + entry.name.text + "] locale=" + overlay.testI18n.locale)
            test.check(entry.name.textFormat === Text.PlainText, "row " + i + " plain text")
            test.check(entry.row.width <= list.width, "row " + i + " within list")
            test.check(entry.counts.x + entry.counts.width <= entry.row.width + 1, "row " + i + " counts inside")
          }
          var allRow = test.rowAt(list, 0)
          test.check(allRow.counts.text === "2/" + total, "live mastery/total on all: " + allRow.counts.text)
          test.check(overlay.deckProgress.all.mastered === 2 && overlay.deckProgress.all.total === total,
                     "progress model matches")
          test.check(test.byName(overlay, "groundBadge").text === "全部", "header badge localized selected deck")
          test.check(test.byName(overlay, "emptyDeckHint").visible === false, "no hint on non-empty")
          test.check(test.byName(overlay, "deckConfigNote").visible === false, "no config note")
          var history = JSON.stringify(overlay.testStore.stats.bindings)
          var nav = test.rowAt(list, 1)
          nav.area.clicked(null)
          test.check(overlay.deckId === "navigation" && overlay.view === "home", "row click selects, stays home")
          test.check(overlay.testGuard.plays === 0 && overlay.testStore.stats.runSequence === 40,
                     "selection allocates nothing")
          test.check(overlay.testStore.settings.activeDeck === "navigation", "selection persisted")
          test.check(JSON.stringify(overlay.testStore.stats.bindings) === history, "history untouched")
          test.check(test.byName(overlay, "groundBadge").text === "导航", "badge follows selection")
          var start = test.byName(overlay, "startButtonArea")
          test.check(start.enabled === true && overlay.startBlocked === false, "start enabled on non-empty")
          start.clicked(null)
          test.check(overlay.view === "playing" && overlay.deck.length > 0, "start deals")
          test.check(overlay.sessionSize === overlay.deck.length && overlay.sessionSize <= 24, "sized to deck")
          test.check(overlay.testGuard.plays === 1 && overlay.activeRunId === 41, "run began with fresh identity")
          overlay.leaveRun()
          test.check(overlay.view === "home" && overlay.resumeAvailable, "home with resume")
          var resume = test.byName(overlay, "startButtonArea")
          test.check(resume.enabled === true, "resume enabled")
          resume.clicked(null)
          test.check(overlay.view === "playing", "resumed through the same control")
          overlay.leaveRun()
        ''', "", "zh-CN")

    def test_user_decks_order_markup_geometry_empty_refusal_live_updates(self):
        # 34 declarations: the reader accepts 32, rejects and counts the last 2.
        decks = [{"id": "zz-first", "name": "Zed First", "seed": {"categories": ["git"]}},
                 {"id": "markup", "name": MARKUP_NAME},
                 {"id": "long", "name": LONG_NAME},
                 {"id": "empty", "name": "Empty"},
                 {"id": "full", "name": "Full House", "seed": {"categories": ["lsp"]}}]
        decks += [{"id": f"deck-{n:02}", "name": f"Deck {n:02}"} for n in range(5, 34)]
        self.write_decks(decks)
        self.write_state("settings", {"schemaVersion": 4, "activeDeck": "empty", "locale": "en",
                                      "feedbackSound": False, "countdownSound": False,
                                      "excludedBindings": [], "deckCards": {}})
        learning = {"state": "learning", "guidedCompleted": True, "dueAt": 0, "dueRun": 0,
                    "intervalStep": 1, "firstTryAttempts": 1, "firstTryCorrect": 1,
                    "recentFirstTry": [True], "reactions": [300],
                    "successfulRuns": [39], "lastSuccessfulRun": 39, "lastSeenAt": 1, "lapseCount": 0}
        self.write_state("stats", {"schemaVersion": 5, "runSequence": 40,
                                   "bindings": {IDS[2]: learning}, "decks": {}})
        self.assertEqual(len(LONG_NAME), 48)
        self.launch('''
          var list = test.byName(overlay, "deckList")
          test.check(list, "deck list exists")
          test.check(list.count === 33 && list.model.length === 33, "all plus 32 accepted declarations")
          test.check(overlay.deckId === "empty", "saved empty deck selected")
          test.check(overlay.startRefusal === "empty-deck" && overlay.startBlocked, "refusal armed")
          var hint = test.byName(overlay, "emptyDeckHint")
          test.check(hint.visible === true, "empty hint visible")
          test.check(hint.text === "EMPTY DECK — ADD CARDS WITH THE BROWSE DRAWER (COMING SOON)", "hint copy")
          var note = test.byName(overlay, "deckConfigNote")
          test.check(note.visible === true && note.text === "DECKS CONFIG: 2 REJECTED", "rejected count note")
          var start = test.byName(overlay, "startButtonArea")
          test.check(start.enabled === false, "start truly disabled on empty deck")
          test.check(test.byName(overlay, "groundBadge").text === "Empty", "badge shows selected user deck")
          var history = JSON.stringify(overlay.testStore.stats.bindings)
          overlay.startPrimary() // the exact call the home Enter handler makes
          test.check(overlay.view === "home" && overlay.startRefusal === "empty-deck", "Enter path refused")
          test.check(overlay.testGuard.plays === 0 && overlay.testStore.stats.runSequence === 40,
                     "no identity allocated on refusal")
          test.check(JSON.stringify(overlay.testStore.stats.bindings) === history, "history untouched")
          var ids = []
          for (var i = 0; i < 33; i++) ids.push(test.rowAt(list, i).id)
          test.check(ids[0] === "all" && ids[1] === "zz-first" && ids[2] === "markup" && ids[3] === "long"
                     && ids[4] === "empty" && ids[5] === "full" && ids[6] === "deck-05" && ids[32] === "deck-31",
                     "all first, then declaration order: " + ids.slice(0, 8).join(","))
          var markup = test.rowAt(list, 2)
          test.check(markup.name.text === __MARKUP__, "markup shown literally")
          test.check(markup.name.textFormat === Text.PlainText, "markup plain text")
          var longRow = test.rowAt(list, 3)
          test.check(longRow.name.text === __LONG__, "full 48-codepoint name retained")
          test.check(longRow.name.truncated === true, "long name elided")
          test.check(longRow.name.x + longRow.name.width <= longRow.counts.x, "name never runs under counts")
          test.check(longRow.counts.x + longRow.counts.width <= longRow.row.width + 1, "counts inside row")
          var zed = test.rowAt(list, 1)
          test.check(zed.name.truncated === false, "short name not truncated")
          test.check(Number(zed.counts.text.split("/")[1]) > 0
                     && Number(zed.counts.text.split("/")[1]) === overlay.deckProgress["zz-first"].total,
                     "seeded count matches live model")
          var emptyRow = test.rowAt(list, 4)
          test.check(emptyRow.counts.text === "0/0", "zero cards shown")
          emptyRow.area.clicked(null)
          test.check(overlay.deckId === "empty" && overlay.view === "home", "empty row selectable")
          test.check(overlay.setDeckCard("empty", __LIVEID__, "add"), "live add accepted")
          test.check(overlay.deckProgress.empty.total === 1, "live count")
          test.check(hint.visible === false && start.enabled === true, "controls follow curation")
          test.check(test.rowAt(list, 4).counts.text === "0/1", "row count live")
          Stats.recordFirstTry(overlay.testStore.stats, __LIVEID__, true, 300, 40, 5)
          overlay.refreshProgressCounts()
          test.check(overlay.deckProgress.empty.mastered === 1, "mastery propagated")
          test.check(test.rowAt(list, 4).counts.text === "★ 1/1", "row mastery live")
          start.clicked(null)
          test.check(overlay.view === "playing" && overlay.deck.length === 1 && overlay.sessionSize === 1,
                     "one-card run")
          test.check(overlay.activeRunId === 41 && overlay.testGuard.plays === 1, "identity allocated only now")
          overlay.leaveRun()
          test.check(overlay.view === "home", "back home")
        '''.replace("__MARKUP__", json.dumps(MARKUP_NAME))
           .replace("__LONG__", json.dumps(LONG_NAME))
           .replace("__LIVEID__", json.dumps(IDS[2])))

    def test_invalid_config_note_and_training_continues(self):
        self.write_raw_decks('{"schemaVersion": 1, "decks": [')
        self.write_state("settings", {"schemaVersion": 4, "activeDeck": "all", "locale": "en",
                                      "feedbackSound": False, "countdownSound": False,
                                      "excludedBindings": [], "deckCards": {}})
        self.write_state("stats", {"schemaVersion": 5, "runSequence": 40, "bindings": {}, "decks": {}})
        self.launch('''
          var list = test.byName(overlay, "deckList")
          test.check(list && list.count === 1, "only all on invalid config")
          test.check(overlay.deckConfigReason === "invalid-json", "bounded fallback reason")
          var note = test.byName(overlay, "deckConfigNote")
          test.check(note.visible === true
                     && note.text === "DECKS CONFIG INVALID (invalid-json) — TRAINING ON ALL",
                     "fallback note: " + note.text)
          var row = test.rowAt(list, 0)
          test.check(row.id === "all" && row.name.text === "All", "all listed with starter name")
          test.check(test.byName(overlay, "groundBadge").text === "All", "badge falls back to all")
          test.check(!overlay.startBlocked, "training not blocked")
          test.byName(overlay, "startButtonArea").clicked(null)
          test.check(overlay.view === "playing" && overlay.deck.length > 0, "training on all")
          overlay.leaveRun()
        ''')

    def render_user_config(self, path):
        decks = [{"id": "zz-first", "name": "Zed First", "seed": {"categories": ["git"]}},
                 {"id": "markup", "name": MARKUP_NAME},
                 {"id": "long", "name": LONG_NAME},
                 {"id": "empty", "name": "Empty"},
                 {"id": "full", "name": "Full House", "seed": {"categories": ["lsp"]}}]
        decks += [{"id": f"deck-{n:02}", "name": f"Deck {n:02}"} for n in range(5, 34)]
        self.write_decks(decks)
        self.write_state("settings", {"schemaVersion": 4, "activeDeck": "empty", "locale": "en",
                                      "feedbackSound": False, "countdownSound": False,
                                      "excludedBindings": [], "deckCards": {}})
        self.write_state("stats", {"schemaVersion": 5, "runSequence": 40,
                                   "bindings": {IDS[0]: self.mastered_entry()},
                                   "decks": {"all": {"runs": 2}}})
        return self.launch('''
          var list = test.byName(overlay, "deckList")
          test.check(list && list.count === 33, "list populated")
          test.check(overlay.deckId === "empty", "empty deck selected")
          test.check(test.byName(overlay, "emptyDeckHint").visible === true, "hint rendered")
          list.positionViewAtIndex(0, ListView.Beginning)
        ''', str(path), "en")

    def test_render_home_user_config(self):
        target = RENDER_DIR / "home-user-en.png"
        target.unlink(missing_ok=True)
        report = self.render_user_config(target)
        self.assertEqual(report.get("saved"), str(target))
        self.assertGreater(target.stat().st_size, 1000)
        print(f"render saved: {target}")

    def test_render_home_starters_zh(self):
        self.write_state("settings", {"schemaVersion": 4, "activeDeck": "lsp", "locale": "zh-CN",
                                      "feedbackSound": False, "countdownSound": False,
                                      "excludedBindings": [], "deckCards": {}})
        self.write_state("stats", {"schemaVersion": 5, "runSequence": 40,
                                   "bindings": {IDS[0]: self.mastered_entry()},
                                   "decks": {"all": {"runs": 2}}})
        target = RENDER_DIR / "home-starters-zh.png"
        target.unlink(missing_ok=True)
        report = self.launch('''
          var list = test.byName(overlay, "deckList")
          test.check(list && list.count === 5, "starters rendered")
          test.check(overlay.deckId === "lsp", "lsp selected")
          test.check(test.byName(overlay, "groundBadge").text === "LSP 与诊断", "badge rendered localized")
        ''', str(target), "zh-CN")
        self.assertEqual(report.get("saved"), str(target))
        self.assertGreater(target.stat().st_size, 1000)
        print(f"render saved: {target}")


if __name__ == "__main__":
    unittest.main()
