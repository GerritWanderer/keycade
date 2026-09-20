"""Actual home deck-list and session HUD behaviour, driven through the real
component.

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
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PACK = json.loads((ROOT / "assets/packs/lazyvim.json").read_text())
IDS = ["lazyvim/" + card["localId"] for card in PACK["bindings"] if not card["extras"]][:8]
RENDER_DIR = Path("/tmp/keycade-lazyvim-wp7a-renders")
WP8_RENDER_DIR = Path("/tmp/keycade-lazyvim-wp8-renders")
# Expected UI copy comes from the shipped catalogs, so these assertions track
# the actual translations instead of a second hardcoded snapshot of them.
LOCALES = {path.stem: json.loads(path.read_text(encoding="utf-8"))
           for path in (ROOT / "assets" / "locales").glob("*.json")}
EN = LOCALES["en"]
ZH = LOCALES["zh-CN"]
EMPTY_HINT = EN["emptyDeckHint"]
LONG_NAME = "Deck" + "名" * 44  # exactly 48 codepoints, multilingual
MARKUP_NAME = "<b>Nemesis</b> & <i>marks</i>"


def render_copy(locale, key, **values):
    # Same substitution shape as I18n.t: {field} placeholders, one pass.
    template = locale[key]
    for field, value in values.items():
        template = template.replace("{" + field + "}", str(value))
    return template

GUARD = '''import QtQuick
Item {
  property var window: null
  property bool keyboardFocused: false
  property bool wantsFocus: false
  property bool active: true
  property int plays: 0
  property int lastMask: 0
  property int inputUpdates: 0
  signal ready()
  signal blocked(string message)
  signal closed()
  function begin() { ready() }
  function pause() {}
  function play() { plays++ }
  function updateInput(mask) { lastMask = mask; inputUpdates++ }
  function requestClose() { closed() }
  function fail(message) { blocked(message) }
}
'''

PANEL = '''  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "keycade-lazyvim"
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
  property int step: 0
  property var data: ({})
  property var report: null
  function later() { test.exercised = false }
  __HELPERS__
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

  // Bounds against the decorated home frame itself, not the window: the
  // frame stays inside the available screen area (HUD above, footer below)
  // and every named visible item stays inside the frame, margin pixels clear
  // of its edge (the dotted inner frame sits 7px in, the solid border at 4).
  function homeBounds(names, margin) {
    var inset = margin === undefined ? 7 : margin
    var card = byName(overlay, "screenCard")
    var area = byName(overlay, "screenArea")
    check(card && area, "frame selectors")
    var cardAt = card.mapToItem(area, 0, 0)
    check(cardAt.x >= 4 && cardAt.y >= 4
          && cardAt.x + card.width <= area.width - 4
          && cardAt.y + card.height <= area.height - 4,
          "home frame within available area: " + cardAt.x + "," + cardAt.y
          + " " + card.width + "x" + card.height + " of " + area.width + "x" + area.height)
    var checked = []
    for (var i = 0; i < names.length; i++) {
      var item = byName(overlay, names[i])
      if (!item || !item.visible) continue
      var pos = item.mapToItem(card, 0, 0)
      check(pos.x >= inset && pos.y >= inset
            && pos.x + item.width <= card.width - inset
            && pos.y + item.height <= card.height - inset,
            names[i] + " inside home frame: " + pos.x + "," + pos.y + " "
            + item.width + "x" + item.height + " of " + card.width + "x" + card.height)
      checked.push(names[i])
    }
    return checked
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
    width: __WIDTH__
    height: __HEIGHT__
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
        if (test.step === 0) test.check(overlay.view === "home", "home view")
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


class DeckUiHarness(unittest.TestCase):
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
        config = self.home / "config/omarchy/keycade-lazyvim"
        config.mkdir(parents=True, exist_ok=True)
        (config / "decks.json").write_text(json.dumps({"schemaVersion": 1, "decks": decks}))

    def write_raw_decks(self, text):
        config = self.home / "config/omarchy/keycade-lazyvim"
        config.mkdir(parents=True, exist_ok=True)
        (config / "decks.json").write_text(text)

    def launch(self, body, render_to="", locale="en", helpers="", size=(1280, 800)):
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
                              .replace("__LOCALE__", json.dumps(locale))
                              .replace("__HELPERS__", helpers)
                              .replace("__WIDTH__", str(size[0]))
                              .replace("__HEIGHT__", str(size[1])))
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


class DeckHomeUiTests(DeckUiHarness):
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
          test.check(hint.text === __EMPTYHINT__, "hint copy")
          var note = test.byName(overlay, "deckConfigNote")
          test.check(note.visible === true && note.text === __NOTE2__, "rejected count note")
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
           .replace("__LIVEID__", json.dumps(IDS[2]))
           .replace("__EMPTYHINT__", json.dumps(EN["emptyDeckHint"]))
           .replace("__NOTE2__", json.dumps(render_copy(EN, "deckConfigRejected", count=2))))

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
                     && note.text === __INVALID__,
                     "fallback note: " + note.text)
          var row = test.rowAt(list, 0)
          test.check(row.id === "all" && row.name.text === "All", "all listed with starter name")
          test.check(test.byName(overlay, "groundBadge").text === "All", "badge falls back to all")
          test.check(!overlay.startBlocked, "training not blocked")
          test.byName(overlay, "startButtonArea").clicked(null)
          test.check(overlay.view === "playing" && overlay.deck.length > 0, "training on all")
          overlay.leaveRun()
        '''.replace("__INVALID__", json.dumps(render_copy(EN, "deckConfigInvalid",
                                                          reason="invalid-json"))))

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
          // The wide home keeps its intro and still fits inside the frame.
          var home = test.byName(overlay, "homeArea")
          test.check(home && home.compact === false, "wide home is not compact")
          test.check(test.byName(overlay, "homeTitle").visible === true
                     && test.byName(overlay, "decksTitleLabel").visible === true,
                     "wide home keeps the intro")
          var inside = test.homeBounds(["homeStatus", "homeTitle", "decksTitleLabel",
                                        "deckListFrame", "deckConfigNote",
                                        "emptyDeckHint", "startButton"])
          test.check(inside.length === 7, "wide essentials inside frame: " + inside.join(","))
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

    def test_chinese_empty_hint_rejection_note_and_bounded_render(self):
        # The WP8 localized home copy, asserted on the actual component in
        # zh-CN and rendered in a small bounded frame for visual inspection.
        decks = [{"id": "empty", "name": "Empty"}, {"id": "full", "name": "Full House",
                  "seed": {"categories": ["lsp"]}}]
        decks += [{"id": f"deck-{n:02}", "name": f"Deck {n:02}"} for n in range(3, 34)]
        self.write_decks(decks)  # 33 declarations: 32 accepted, 1 rejected
        self.write_state("settings", {"schemaVersion": 4, "activeDeck": "empty", "locale": "zh-CN",
                                      "feedbackSound": False, "countdownSound": False,
                                      "excludedBindings": [], "deckCards": {}})
        self.write_state("stats", {"schemaVersion": 5, "runSequence": 40, "bindings": {}, "decks": {}})
        WP8_RENDER_DIR.mkdir(parents=True, exist_ok=True)
        target = WP8_RENDER_DIR / "home-empty-zh-760x600.png"
        target.unlink(missing_ok=True)
        report = self.launch('''
          var hint = test.byName(overlay, "emptyDeckHint")
          test.check(hint.visible === true && hint.text === __HINT__, "zh empty hint: " + hint.text)
          test.check(hint.textFormat === Text.PlainText, "hint plain text")
          var note = test.byName(overlay, "deckConfigNote")
          test.check(note.visible === true && note.text === __NOTE__, "zh rejected note: " + note.text)
          var browse = test.byName(overlay, "browseButtonArea")
          test.check(browse && browse.enabled, "browse available on home")
          var list = test.byName(overlay, "deckList")
          test.check(list && list.count === 33, "all plus 32 accepted")
          var first = test.rowAt(list, 0)
          test.check(first.id === "all" && first.name.text === "全部", "all pinned, localized")
          test.check(test.byName(overlay, "groundBadge").text === "Empty", "user name as-is")
          var panel = test.byName(overlay, "testPanel")
          test.check(panel.width === 760 && panel.height === 600, "bounded frame")
          // The actual compact home layout: the frame stays between HUD and
          // footer and every essential item stays inside the frame.
          var home = test.byName(overlay, "homeArea")
          test.check(home && home.compact === true, "compact home detected")
          test.check(test.byName(overlay, "homeTitle").visible === false
                     && test.byName(overlay, "decksTitleLabel").visible === false,
                     "only the decorative intro yields")
          var startArea = test.byName(overlay, "startButtonArea")
          test.check(startArea && startArea.enabled === false, "start disabled on empty compact home")
          var inside = test.homeBounds(["homeStatus", "deckListFrame", "deckConfigNote",
                                        "emptyDeckHint", "startButton"])
          test.check(inside.length === 5, "all essential items checked: " + inside.join(","))
          test.check(test.rowAt(list, 32).id === "deck-32", "compact list still scrolls to the end")
          list.positionViewAtIndex(0, ListView.Beginning) // render the repro from the top
        '''.replace("__HINT__", json.dumps(ZH["emptyDeckHint"]))
           .replace("__NOTE__", json.dumps(render_copy(ZH, "deckConfigRejected", count=1))),
           str(target), "zh-CN", size=(760, 600))
        self.assertEqual(report.get("saved"), str(target))
        self.assertGreater(target.stat().st_size, 1000)
        print(f"render saved: {target}")
    def test_compact_english_home_bounds_refusal_and_resume(self):
        # The same 760x600 compact repro in English, driven further: refusal,
        # compact row selection, a real run, and the resumable two-button home.
        decks = [{"id": "empty", "name": "Empty"}, {"id": "zz-first", "name": "Zed First",
                  "seed": {"categories": ["git"]}}, {"id": "full", "name": "Full House",
                  "seed": {"categories": ["lsp"]}}]
        decks += [{"id": f"deck-{n:02}", "name": f"Deck {n:02}"} for n in range(4, 35)]
        self.write_decks(decks)  # 34 declarations: 32 accepted, 2 rejected
        self.write_state("settings", {"schemaVersion": 4, "activeDeck": "empty", "locale": "en",
                                      "feedbackSound": False, "countdownSound": False,
                                      "excludedBindings": [], "deckCards": {}})
        self.write_state("stats", {"schemaVersion": 5, "runSequence": 40, "bindings": {}, "decks": {}})
        WP8_RENDER_DIR.mkdir(parents=True, exist_ok=True)
        target = WP8_RENDER_DIR / "home-empty-en-760x600.png"
        target.unlink(missing_ok=True)
        report = self.launch('''
          var home = test.byName(overlay, "homeArea")
          test.check(home && home.compact === true, "compact home detected")
          var list = test.byName(overlay, "deckList")
          test.check(list && list.count === 33, "all rows modelled at compact")
          test.check(list.height >= 30 && list.height <= 96, "compact list bounded: " + list.height)
          var hint = test.byName(overlay, "emptyDeckHint")
          test.check(hint.visible === true && hint.text === __HINT__, "en hint: " + hint.text)
          var note = test.byName(overlay, "deckConfigNote")
          test.check(note.visible === true && note.text === __NOTE__, "en note: " + note.text)
          var inside = test.homeBounds(["homeStatus", "deckListFrame", "deckConfigNote",
                                        "emptyDeckHint", "startButton"])
          test.check(inside.length === 5, "essentials inside frame")
          var start = test.byName(overlay, "startButtonArea")
          test.check(start.enabled === false, "start disabled on empty compact home")
          overlay.startPrimary() // the exact call the home Enter handler makes
          test.check(overlay.view === "home" && overlay.startRefusal === "empty-deck"
                     && overlay.testStore.stats.runSequence === 40 && overlay.testGuard.plays === 0,
                     "refused at compact, nothing allocated")
          test.check(test.rowAt(list, 32).id === "deck-32", "compact list scrolls to the end")
          list.positionViewAtIndex(0, ListView.Beginning) // render the repro from the top
        '''.replace("__HINT__", json.dumps(EN["emptyDeckHint"]))
           .replace("__NOTE__", json.dumps(render_copy(EN, "deckConfigRejected", count=2))),
           str(target), "en", size=(760, 600))
        self.assertEqual(report.get("saved"), str(target))
        self.assertGreater(target.stat().st_size, 1000)
        print(f"render saved: {target}")
        # State persists across launches: still on the empty deck.
        resume_target = WP8_RENDER_DIR / "home-resume-en-760x600.png"
        resume_target.unlink(missing_ok=True)
        report = self.launch('''
          var home = test.byName(overlay, "homeArea")
          test.check(home.compact === true, "compact")
          test.check(overlay.deckId === "empty" && overlay.startRefusal === "empty-deck",
                     "still on the empty deck")
          var list = test.byName(overlay, "deckList")
          var git = test.rowAt(list, 2)
          test.check(git.id === "zz-first", "seeded row present")
          git.area.clicked(null)
          test.check(overlay.deckId === "zz-first" && overlay.view === "home",
                     "compact row selects, stays home")
          var start = test.byName(overlay, "startButtonArea")
          test.check(start.enabled === true, "start enabled on non-empty compact home")
          test.check(test.byName(overlay, "emptyDeckHint").visible === false, "hint settles")
          start.clicked(null)
          test.check(overlay.view === "playing" && overlay.deck.length > 0, "run started at compact")
          overlay.leaveRun()
          test.check(overlay.view === "home" && overlay.resumeAvailable, "resumable compact home")
          var fresh = test.byName(overlay, "startFreshArea")
          test.check(fresh && fresh.enabled === true, "fresh enabled")
          var inside = test.homeBounds(["homeStatus", "deckListFrame", "deckConfigNote",
                                        "startButton", "startFreshButton"])
          test.check(inside.length === 5, "resumable controls inside frame")
          // The Loader swapped the home card out during the run: re-fetch.
          var resume = test.byName(overlay, "startButtonArea")
          resume.clicked(null)
          test.check(overlay.view === "playing", "resumed through the same control")
          overlay.leaveRun()
          test.check(overlay.view === "home" && overlay.resumeAvailable, "home resumable for render")
        ''', str(resume_target), "en", size=(760, 600))
        self.assertEqual(report.get("saved"), str(resume_target))
        self.assertGreater(resume_target.stat().st_size, 1000)
        print(f"render saved: {resume_target}")

    def test_compact_locked_out_home_geometry_en_zh(self):
        # Locked-out branch (every shortcut excluded) at 760x600 with a
        # visible config rejection. Stored exclusions cap at 64 entries and a
        # real corpus never gets that small, so the temp copy's compiled pack
        # is regenerated from a trimmed three-card source with the real
        # generator; loading, exclusion, eligibility and lockout all run their
        # production path against it. The headline and recovery instructions
        # must stay visible AND fit inside the frame.
        decks = [{"id": "empty", "name": "Empty"}]
        decks += [{"id": f"deck-{n:02}", "name": f"Deck {n:02}"} for n in range(2, 34)]
        WP8_RENDER_DIR.mkdir(parents=True, exist_ok=True)
        for locale, catalog in (("en", EN), ("zh-CN", ZH)):
            with self.subTest(locale=locale):
                self.setUp()
                packs = json.loads((self.app / "assets/packs/lazyvim.json").read_text())
                keep = [card for card in packs["bindings"] if not card["extras"]][:3]
                packs["bindings"] = keep
                (self.app / "assets/packs/lazyvim.json").write_text(json.dumps(packs))
                (self.app / "tools").mkdir()
                shutil.copy(ROOT / "tools/build_packs.py", self.app / "tools/build_packs.py")
                # The generator resolves its root from its own file location,
                # so this recompiles only the temp copy's lib/Packs.js.
                subprocess.run([sys.executable, str(self.app / "tools/build_packs.py")],
                               check=True, capture_output=True, timeout=30)
                exclusions = ["lazyvim:" + card["localId"] for card in keep]
                self.write_decks(decks)  # 33 declarations: 32 accepted, 1 rejected
                self.write_state("settings", {"schemaVersion": 4, "activeDeck": "all", "locale": locale,
                                              "feedbackSound": False, "countdownSound": False,
                                              "excludedBindings": exclusions, "deckCards": {}})
                self.write_state("stats", {"schemaVersion": 5, "runSequence": 40,
                                           "bindings": {}, "decks": {}})
                suffix = "zh" if locale == "zh-CN" else "en"
                target = WP8_RENDER_DIR / f"home-locked-{suffix}-760x600.png"
                target.unlink(missing_ok=True)
                report = self.launch('''
                  test.check(overlay.trainingLockedOut === true, "locked out")
                  test.check(overlay.startBlocked, "nothing to deal")
                  var home = test.byName(overlay, "homeArea")
                  test.check(home && home.compact === true, "compact locked-out home")
                  var title = test.byName(overlay, "homeTitle")
                  test.check(title.visible === true && title.text === __TITLE__,
                             "locked-out headline stays visible: " + title.text)
                  test.check(title.truncated === false, "headline not clipped")
                  var hint = test.byName(overlay, "allExcludedHint")
                  test.check(hint.visible === true && hint.text === __HINT__, "recovery copy")
                  test.check(hint.truncated === false, "recovery instructions fully visible")
                  var note = test.byName(overlay, "deckConfigNote")
                  test.check(note.visible === true && note.text === __NOTE__, "config note")
                  var inside = test.homeBounds(["homeStatus", "homeTitle", "allExcludedHint",
                                                "deckConfigNote", "deckListFrame"])
                  test.check(inside.length === 5, "locked-out essentials inside frame: "
                             + inside.join(","))
                  var list = test.byName(overlay, "deckList")
                  test.check(list.count === 33, "decks still listed")
                  test.check(test.rowAt(list, 0).counts.text === "0/0",
                             "excluded cards absent from every count")
                  test.check(test.rowAt(list, 32).id === "deck-32", "locked-out list scrolls")
                  list.positionViewAtIndex(0, ListView.Beginning) // render from the top
                '''.replace("__TITLE__", json.dumps(catalog["allExcluded"]))
                   .replace("__HINT__", json.dumps(catalog["allExcludedHint"]))
                   .replace("__NOTE__", json.dumps(render_copy(catalog, "deckConfigRejected",
                                                               count=1))),
                   str(target), locale, size=(760, 600))
                self.assertEqual(report.get("saved"), str(target))
                self.assertGreater(target.stat().st_size, 1000)
                print(f"render saved: {target}")


class DeckHudUiTests(DeckUiHarness):
    """Rendered session HUD progress against live session sizes (task 5.4).

    The denominator is read back from the actual DotNumber cell via its stable
    selector, not from the engine property the cell is bound to. Reads wait one
    pump (test.later) after each mutation so the Repeater model and delegates
    have re-evaluated before the rendered string is sampled.
    """

    HUD = '''
  function hudProgress() {
    var cell = byName(overlay, "hudValue:progress")
    check(cell, "progress HUD datum exists")
    return String(cell.value)
  }
'''

    def read_state(self, kind):
        return json.loads((self.home / f"state/omarchy/keycade-lazyvim/{kind}.json").read_text())

    def prepare_tiny_deck(self):
        self.write_decks([{"id": "tiny", "name": "Tiny Seven"}])
        self.write_state("settings", {"schemaVersion": 4, "activeDeck": "tiny", "locale": "en",
                                      "feedbackSound": False, "countdownSound": False,
                                      "excludedBindings": [],
                                      "deckCards": {"tiny": {"added": IDS[:7], "removed": []}}})
        self.write_state("stats", {"schemaVersion": 5, "runSequence": 40, "bindings": {}, "decks": {}})

    def test_progress_denominator_tracks_live_resumed_and_shrunk_session(self):
        self.prepare_tiny_deck()
        self.launch('''
          if (test.step === 0) {
            test.check(test.hudProgress() === "00 / 0", "no active session yet: [" + test.hudProgress() + "]")
            test.check(overlay.selectDeck("all"), "all selectable")
            test.byName(overlay, "startButtonArea").clicked(null)
            test.check(overlay.view === "playing" && overlay.sessionSize === 24,
                       "big deck capped at 24: " + overlay.sessionSize)
            test.step = 1; test.later(); return
          }
          if (test.step === 1) {
            test.check(test.hudProgress() === "00 / 24", "big deck HUD: [" + test.hudProgress() + "]")
            overlay.leaveRun()
            test.check(overlay.selectDeck("tiny") && !overlay.resumeAvailable,
                       "foreign session not adopted")
            test.byName(overlay, "startButtonArea").clicked(null)
            test.check(overlay.view === "playing" && overlay.sessionSize === 7,
                       "small deck dealt whole: " + overlay.sessionSize)
            test.step = 2; test.later(); return
          }
          if (test.step === 2) {
            test.check(test.hudProgress() === "00 / 7", "small deck HUD: [" + test.hudProgress() + "]")
            overlay.hitCurrent()
            test.step = 3; test.later(); return
          }
          if (test.step === 3) {
            test.check(test.hudProgress() === "01 / 7", "completed hit reflected: [" + test.hudProgress() + "]")
            overlay.advanceCard()
            overlay.leaveRun()
            test.check(overlay.resumeAvailable && overlay.deckId === "tiny", "interrupted run resumable")
          }
        ''', helpers=self.HUD)
        # Exact resume: offset one plus six remaining cards keeps the dealt size.
        self.launch('''
          if (test.step === 0) {
            test.check(overlay.deckId === "tiny" && overlay.resumeAvailable, "tiny session pending")
            test.check(overlay.sessionSize === 7, "adopted exact size")
            test.step = 1; test.later(); return
          }
          if (test.step === 1) {
            test.check(test.hudProgress() === "01 / 7",
                       "home adopts resumed progress: [" + test.hudProgress() + "]")
            overlay.resumeRun()
            test.check(overlay.view === "playing" && overlay.runOffset === 1
                       && overlay.deck.length === 6, "exact resume geometry")
            test.step = 2; test.later(); return
          }
          if (test.step === 2) {
            test.check(test.hudProgress() === "01 / 7", "resumed HUD exact: [" + test.hudProgress() + "]")
            overlay.leaveRun()
          }
        ''', helpers=self.HUD)
        # Approved D7 shrink: a remaining card leaves the deck before resume.
        session = self.read_state("session")
        self.assertEqual(session["offset"], 1)
        settings = self.read_state("settings")
        settings["deckCards"]["tiny"]["removed"] = [session["cards"][0]["bindingId"]]
        self.write_state("settings", settings)
        self.launch('''
          if (test.step === 0) {
            test.check(overlay.deckId === "tiny" && overlay.resumeAvailable, "shrunk session pending")
            test.check(overlay.sessionSize === 6, "adopted shrunk size")
            test.step = 1; test.later(); return
          }
          if (test.step === 1) {
            test.check(test.hudProgress() === "01 / 6",
                       "home shows shrunk denominator: [" + test.hudProgress() + "]")
            overlay.resumeRun()
            test.check(overlay.view === "playing" && overlay.runOffset === 1
                       && overlay.deck.length === 5, "shrunk resume keeps the nonzero offset")
            test.step = 2; test.later(); return
          }
          if (test.step === 2) {
            test.check(test.hudProgress() === "01 / 6", "shrunk HUD: [" + test.hudProgress() + "]")
            test.data.excluded = overlay.currentBinding.id
            overlay.excludeCurrentBinding()
            test.check(overlay.excludeStampVisible, "in-run exclusion accepted")
            overlay.dropExcludedCard(test.data.excluded)
            test.check(overlay.sessionSize === 5, "in-run shrink keeps offset plus remaining")
            test.step = 3; test.later(); return
          }
          if (test.step === 3) {
            test.check(test.hudProgress() === "01 / 5", "in-run shrink HUD: [" + test.hudProgress() + "]")
            overlay.leaveRun()
          }
        ''', helpers=self.HUD)


if __name__ == "__main__":
    unittest.main()
