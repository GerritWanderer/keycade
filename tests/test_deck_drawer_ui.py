"""Browse-and-Pick through real delegates, store, reader and session handlers.

Only the shared headless panel/focus substitutions are used. All configuration,
state writes and render evidence live under temporary paths, never personal HOME.
"""
import json
from pathlib import Path
import unittest

from test_deck_ui import DeckUiHarness, IDS, LONG_NAME, MARKUP_NAME, EN, ZH, render_copy

RENDERS = Path("/tmp/keycade-lazyvim-wp7b-renders")
WP8_RENDERS = Path("/tmp/keycade-lazyvim-wp8-renders")
EXTRA = "lazyvim.plugins.extras.editor.harpoon2"

# Expected copy is read from the shipped catalogs (see test_deck_ui), never
# re-hardcoded here, so the assertions track the actual translations.
COPY = {"add": EN["browseAdd"], "added": EN["browseInDeckAdded"],
        "seeded": EN["browseInDeckSeeded"], "allReadOnly": EN["browseAllReadOnly"],
        "targetMissing": EN["browseTargetMissing"], "capacityRefused": EN["browseCapacityRefused"]}

HELPERS = '''
  function openBrowse() {
    var button = byName(overlay, "browseButtonArea")
    check(button && button.enabled, "Browse available")
    button.clicked(null)
    check(overlay.browseOpen, "real toggle opened drawer")
  }
  function pickTarget(id) {
    byName(overlay, "browseTargetArea").clicked(null)
    var list = byName(overlay, "browseTargets")
    list.forceLayout()
    var index = overlay.deckDefinitions.map(function(d) { return d.id }).indexOf(id)
    check(index >= 0, "target declared")
    list.positionViewAtIndex(index, ListView.Contain)
    list.forceLayout()
    var row = list.itemAtIndex(index)
    check(row, "target instantiated")
    byName(row, "browseTargetPick").clicked(null)
    check(overlay.browseTargetId === id && !overlay.browseTargetsOpen, "target picked")
  }
  function chip(listName, value) {
    var list = byName(overlay, listName)
    var index = list.model.indexOf(value)
    check(index >= 0, "chip exists: " + value)
    list.positionViewAtIndex(index, ListView.Contain)
    list.forceLayout()
    byName(list.itemAtIndex(index), "browseChipArea").clicked(null)
  }
  function row(id) {
    var list = byName(overlay, "browseList")
    var index = overlay.browseRows.indexOf(id)
    check(index >= 0, "card visible: " + id)
    list.forceLayout()
    list.positionViewAtIndex(index, ListView.Contain)
    list.forceLayout()
    var item = list.itemAtIndex(index)
    check(item && item.modelData === id, "actual corpus delegate")
    return item
  }
  function toggleCard(id) {
    var item = row(id)
    var area = byName(item, "browseMembershipArea")
    check(area.enabled, "row action enabled")
    area.clicked(null)
  }
  function label(id) { return byName(row(id), "browseMembership").text }
  function key(key, modifiers, released) {
    var catcher = byName(overlay, "keyCatcher")
    var event = { key: key, modifiers: modifiers || 0, isAutoRepeat: false, accepted: false }
    if (released) catcher.handleReleased(event)
    else catcher.handlePressed(event)
    return event
  }
'''


class DeckDrawerUiTests(DeckUiHarness):
    def setUp(self):
        super().setUp()
        RENDERS.mkdir(exist_ok=True)
        self.write_decks([
            {"id": "nemesis", "name": "Nemesis"},
            {"id": "lsp", "name": "LSP", "seed": {"categories": ["lsp", "diagnostics"]}},
            {"id": "seeded", "name": "Seeded", "seed": {"categories": ["git"]}},
        ])
        self.settings = {"schemaVersion": 4, "activeDeck": "nemesis", "locale": "en",
                         "feedbackSound": False, "countdownSound": False,
                         "excludedBindings": [], "deckCards": {}}
        self.write_state("settings", self.settings)
        self.write_state("stats", {"schemaVersion": 5, "runSequence": 40,
                                   "bindings": {IDS[0]: self.mastered_entry()},
                                   "decks": {"nemesis": {"runs": 3}}})

    def run_ui(self, body, render_to="", size=(1280, 800), locale="en"):
        return self.launch(body, str(render_to), locale=locale, helpers=HELPERS, size=size)

    def test_filters_custom_added_changed_active_extras_and_membership(self):
        config = self.home / ".config/nvim"
        (config / "lua/config").mkdir(parents=True)
        (config / "lazyvim.json").write_text(json.dumps({"extras": [EXTRA]}))
        (config / "lua/config/keymaps.lua").write_text(
            'vim.keymap.set("n", "gd", rhs, { desc = "Changed definition" })\n'
            'vim.keymap.set("n", "gZ", rhs, { desc = "<b>Custom</b> & prompt" })\n')
        self.run_ui('''
          test.openBrowse()
          test.chip("browseCategories", "lsp")
          test.check(overlay.browseRows.length > 0, "category has cards")
          test.check(overlay.browseRows.every(function(id) { return overlay.browseCard(id).category === "lsp" }),
                     "category filters actual metadata")
          test.chip("browseCategories", "")
          test.chip("browseSources", "custom")
          test.check(overlay.browseRows.length === 2, "added AND changed custom maps")
          test.check(overlay.browseRows.indexOf("lazyvim/normal/gd") !== -1, "changed row included")
          test.check(overlay.browseRows.indexOf("lazyvim/normal/gZ") !== -1, "added row included")
          var custom = test.row("lazyvim/normal/gZ")
          test.check(test.byName(custom, "browsePrompt").text === "<b>Custom</b> & prompt", "literal prompt")
          test.check(test.byName(custom, "browsePrompt").textFormat === Text.PlainText, "plain prompt")
          test.check(test.byName(custom, "browseNotation").text === "gZ", "notation")
          test.check(test.byName(custom, "browseBadges").text.indexOf(overlay.testI18n.t("context_normal")) === 0, "translated context")
          test.toggleCard("lazyvim/normal/gZ")
          test.byName(test.byName(overlay, "browseInDeck"), "browseChipArea").clicked(null)
          test.check(overlay.browseRows.length === 1 && overlay.browseRows[0] === "lazyvim/normal/gZ", "membership conjunction")
          test.chip("browseCategories", "lsp")
          test.check(overlay.browseRows.length === 0, "category AND custom AND membership")
          test.chip("browseCategories", "")
          test.byName(test.byName(overlay, "browseAllCards"), "browseChipArea").clicked(null)
          test.chip("browseSources", "__EXTRA__")
          test.check(overlay.browseExtras.length === 1 && overlay.browseExtras[0] === "__EXTRA__", "only active pack extra")
          test.check(overlay.browseRows.length > 0 && overlay.browseRows.every(function(id) {
            return overlay.browseCard(id).extras.indexOf("__EXTRA__") !== -1
          }), "extra filters real corpus")
          test.chip("browseSources", "")
          test.check(overlay.browseRows.length === overlay.eligibleCorpus.length, "all sources restored")
        '''.replace("__EXTRA__", EXTRA))

    def test_three_membership_states_other_badges_history_and_readonly_all(self):
        self.run_ui('''
          var COPY = __COPY__
          test.openBrowse()
          var history = JSON.stringify(overlay.testStore.stats)
          var session = JSON.stringify(overlay.testStore.session)
          var id = "lazyvim/normal/gd"
          test.check(test.label(id) === COPY.add, "out state")
          var badges = test.byName(test.row(id), "browseBadges")
          test.check(badges.text.indexOf("All") !== -1 && badges.text.indexOf("LSP") !== -1, "other-deck badges all + lsp")
          test.toggleCard(id)
          test.check(test.label(id) === COPY.added, "added state")
          test.check(overlay.deckProgress.nemesis.total === 1, "live target count")
          test.toggleCard(id)
          test.check(test.label(id) === COPY.add, "added reset")
          test.check(overlay.testStore.settings.deckCards.nemesis.added.length === 0
                     && overlay.testStore.settings.deckCards.nemesis.removed.length === 0, "reset clears overrides")
          test.pickTarget("lsp")
          test.check(overlay.deckId === "nemesis" && overlay.testStore.settings.activeDeck === "nemesis", "target independent from study")
          test.check(test.label(id) === COPY.seeded, "seeded state")
          test.toggleCard(id)
          test.check(test.label(id) === COPY.add, "pruned seed is out")
          test.check(overlay.testStore.settings.deckCards.lsp.removed.indexOf(id) !== -1, "seed pruned")
          test.check(overlay.cardsForDeck("all").some(function(card) { return card.id === id }), "per-deck prune not global")
          test.toggleCard(id)
          test.check(test.label(id) === COPY.seeded, "pruned seed restored")
          test.check(overlay.testStore.settings.deckCards.lsp.added.length === 0
                     && overlay.testStore.settings.deckCards.lsp.removed.length === 0, "no added+removed collision")
          test.pickTarget("all")
          var before = JSON.stringify(overlay.testStore.settings)
          var area = test.byName(test.row(id), "browseMembershipArea")
          test.check(!area.enabled, "all action disabled")
          area.clicked(null) // even synthetic click cannot write reserved all
          test.check(JSON.stringify(overlay.testStore.settings) === before, "all read-only")
          test.check(test.byName(overlay, "browseNotice").text === COPY.allReadOnly, "friendly choose-target hint")
          test.check(JSON.stringify(overlay.testStore.stats) === history, "mastery and history byte-identical")
          test.check(JSON.stringify(overlay.testStore.session) === session, "session untouched")
          test.check(overlay.testGuard.plays === 0 && overlay.testStore.stats.runSequence === 40, "no allocation")
        '''.replace("__COPY__", json.dumps(COPY)))

    def test_exclusions_missing_target_and_config_change_fail_closed(self):
        self.settings["excludedBindings"] = ["lazyvim:normal/gd"]
        self.settings["deckCards"] = {"nemesis": {"added": ["lazyvim/normal/gd"], "removed": []},
                                      "orphan": {"added": [IDS[0]], "removed": []}}
        self.write_state("settings", self.settings)
        self.run_ui('''
          test.openBrowse()
          var before = JSON.stringify(overlay.testStore.settings)
          var history = JSON.stringify(overlay.testStore.stats)
          test.check(overlay.browseRows.indexOf("lazyvim/normal/gd") === -1, "excluded absent from drawer")
          overlay.deckDefinitions.forEach(function(d) {
            test.check(!overlay.cardsForDeck(d.id).some(function(card) { return card.id === "lazyvim/normal/gd" }), "excluded absent every deck")
          })
          test.check(overlay.otherDecks("lazyvim/normal/gd", "nemesis").length === 0, "excluded no badges")
          test.check(!overlay.toggleBrowseCard("lazyvim/normal/gd"), "cannot add excluded")
          test.chip("browseCategories", "lsp")
          test.check(overlay.browseRows.indexOf("lazyvim/normal/gd") === -1, "chips cannot restore exclusion")
          overlay.deckDefinitions = overlay.deckDefinitions.filter(function(d) { return d.id !== "nemesis" })
          test.check(overlay.browseTarget === null, "removed target stays missing, no silent fallback")
          test.check(test.byName(overlay, "browseNotice").text === __TARGET_MISSING__, "missing target notice")
          test.check(!overlay.toggleBrowseCard("lazyvim/normal/gr"), "missing target refuses")
          overlay.chooseBrowseTarget("orphan")
          test.check(overlay.browseTargetId === "nemesis", "inert orphan cannot be selected")
          test.check(JSON.stringify(overlay.testStore.settings) === before, "config changes cause no curation writes")
          test.check(JSON.stringify(overlay.testStore.stats) === history, "excluded history retained")
          test.pickTarget("lsp")
          test.check(overlay.browseTarget !== null, "can choose valid replacement")
        '''.replace("__TARGET_MISSING__", json.dumps(COPY["targetMissing"])))

    def test_budget_refusal_visible_nonfatal_and_state_bytes_unchanged(self):
        # Valid, almost-full retained orphan deltas exercise the actual 24 KiB
        # atomic limit, not a stubbed refusal or a rewritten storage formula.
        cards = ["lazyvim/normal/" + str(i) + "x" * 2000 for i in range(12)]
        delta = {"orphan": {"added": cards, "removed": []}}
        slack = 24570 - len(json.dumps(delta, separators=(",", ":")).encode())
        cards.append("lazyvim/" + "z" * (slack - 11))
        self.assertEqual(len(json.dumps(delta, separators=(",", ":")).encode()), 24570)
        self.settings["deckCards"] = delta
        self.write_state("settings", self.settings)
        self.run_ui('test.check(overlay.testStore.ready, "canonical startup")')
        path = self.home / "state/omarchy/keycade-lazyvim/settings.json"
        before = path.read_bytes()
        self.run_ui('''
          test.openBrowse()
          var before = JSON.stringify(overlay.testStore.settings.deckCards)
          test.toggleCard("lazyvim/normal/gd")
          test.check(test.label("lazyvim/normal/gd") === __ADD__, "refusal retains row membership")
          test.check(overlay.testStore.deckCardsRefusal === "deck-cards-limit", "real store budget refused")
          var notice = test.byName(overlay, "browseNotice")
          test.check(notice.visible && notice.text === __CAPACITY__, "visible nonfatal refusal")
          test.check(notice.maximumLineCount === 2 && notice.textFormat === Text.PlainText, "bounded refusal")
          test.check(JSON.stringify(overlay.testStore.settings.deckCards) === before, "deltas unmodified")
          test.check(overlay.view === "home" && overlay.browseOpen, "still usable, not blocked")
          test.check(overlay.testStore.stats.runSequence === 40, "identity unchanged")
        '''.replace("__CAPACITY__", json.dumps(COPY["capacityRefused"]))
           .replace("__ADD__", json.dumps(COPY["add"])))
        self.assertEqual(path.read_bytes(), before)

    def test_availability_modal_input_menu_coordination_and_saved_resume_shrink(self):
        self.settings["activeDeck"] = "lsp"
        self.write_state("settings", self.settings)
        self.run_ui('''
          if (test.step === 0) {
            var menus = ["sound", "language", "theme", "excluded"]
            menus.forEach(function(menu) {
              test.byName(overlay, menu + "ButtonArea").clicked(null)
              test.check(overlay[menu + "MenuOpen"] && !overlay.browseOpen, "menu replaces drawer: " + menu)
              test.openBrowse()
              test.check(!overlay[menu + "MenuOpen"], "opening closes menu: " + menu)
            })
            test.check(overlay.browseTargetId === "lsp", "target initializes from studying deck")
            var sequence = overlay.testStore.stats.runSequence
            var event = test.key(Qt.Key_Return, Qt.ControlModifier, false)
            test.check(event.accepted && overlay.testGuard.lastMask !== 0, "Enter swallowed after modifier bookkeeping")
            test.key(Qt.Key_Return, 0, true)
            test.check(overlay.testGuard.lastMask === 0, "release clears modifier mask")
            test.check(!test.byName(overlay, "startButtonArea").enabled, "underlying start disabled")
            test.byName(overlay, "startButtonArea").clicked(null)
            overlay.startRun()
            overlay.resumeRun()
            test.check(overlay.view === "home" && overlay.testStore.stats.runSequence === sequence, "Enter/clickthrough cannot allocate")
            test.byName(overlay, "browseTargetArea").clicked(null)
            test.key(Qt.Key_Escape, 0, false)
            test.key(Qt.Key_Escape, 0, true)
            test.check(overlay.browseOpen && !overlay.browseTargetsOpen && !overlay.escapeDown, "Escape first closes selector only")
            test.key(Qt.Key_Escape, 0, false)
            test.key(Qt.Key_Escape, 0, true)
            test.check(!overlay.browseOpen && overlay.view === "home", "Escape closes drawer, not overlay")
            test.byName(overlay, "startButtonArea").clicked(null)
            test.check(overlay.view === "playing" && !test.byName(overlay, "browseButtonArea").enabled, "Browse disabled in play")
            test.byName(overlay, "browseButtonArea").clicked(null)
            test.check(!overlay.browseOpen && overlay.view === "playing", "no pause transition")
            // A real answer and completed offset, then leave through existing path.
            overlay.hitCurrent()
            test.step = 1; test.later(); return
          }
          if (test.step === 1) {
            if (overlay.cardIndex === 0) { test.later(); return }
            // New cards are guided first, so finish a real learning retest
            // before asserting nonzero recall score survives curation/resume.
            if (overlay.correct === 0) {
              if (!overlay.cardLocked) overlay.hitCurrent()
              test.later(); return
            }
            overlay.leaveRun()
            test.data.identity = overlay.activeRunId
            test.data.score = overlay.correct
            test.data.attempts = overlay.attempts
            test.data.offset = overlay.testStore.session.offset
            test.check(test.data.offset > 0 && test.data.score > 0, "nonzero completed score/offset fixture")
            test.data.session = JSON.stringify(overlay.testStore.session)
            test.data.history = JSON.stringify(overlay.testStore.stats)
            test.data.id = overlay.testStore.session.cards[0].bindingId
            test.data.remaining = overlay.testStore.session.cards.length
            test.openBrowse()
            test.toggleCard(test.data.id)
            test.check(overlay.resumeAvailable, "saved run still resumable")
            test.check(JSON.stringify(overlay.testStore.session) === test.data.session, "curation doesn't rewrite saved session")
            test.check(JSON.stringify(overlay.testStore.stats) === test.data.history, "curation preserves score/history")
            test.byName(test.byName(overlay, "browseClose"), "browseChipArea").clicked(null)
            test.byName(overlay, "startButtonArea").clicked(null)
            test.check(overlay.view === "playing" && overlay.activeRunId === test.data.identity, "resume retains identity")
            test.check(overlay.correct === test.data.score && overlay.attempts === test.data.attempts, "resume retains score")
            test.check(overlay.deck.length < test.data.remaining
                       && !overlay.deck.some(function(c) { return c.binding.id === test.data.id }), "playable queue shrinks")
            test.check(overlay.runOffset === test.data.offset && overlay.sessionSize === overlay.runOffset + overlay.deck.length,
                       "shrunken session preserves completed offset")
            overlay.leaveRun()
            overlay.view = "summary"
            test.openBrowse()
            test.check(overlay.view === "home", "summary returns home before curation")
            overlay.closeBrowse()
            overlay.view = "mastery"
            test.openBrowse()
            test.check(overlay.view === "home", "mastery returns home before curation")
            test.check(overlay.testStore.stats.runSequence === test.data.identity, "no extra global allocation")
          }
        ''')

    def test_scroll_stability_and_in_deck_removal(self):
        self.run_ui('''
          if (test.step === 0) {
            test.openBrowse()
            var list = test.byName(overlay, "browseList")
            test.check(list.count > 100 && list.clip, "bounded real corpus")
            test.data.id = overlay.browseRows[Math.floor(overlay.browseRows.length / 2)]
            var row = test.row(test.data.id)
            test.data.y = list.contentY
            test.check(test.data.y > 300, "scrolled well beyond top")
            test.byName(row, "browseMembershipArea").clicked(null)
            test.step = 1; test.later(); return
          }
          var list = test.byName(overlay, "browseList")
          test.check(Math.abs(list.contentY - test.data.y) < 1, "membership change preserves scroll after layout")
          test.check(list.contentItem.children.length < list.count / 2, "corpus virtualized, not a repeater")
          test.byName(test.byName(overlay, "browseInDeck"), "browseChipArea").clicked(null)
          test.check(overlay.browseRows.length === 1, "in-deck one row")
          test.toggleCard(test.data.id)
          test.check(overlay.browseRows.length === 0, "reset legitimately disappears in membership filter")
        ''')

    def test_all_33_targets_plain_text_geometry_small_frame_and_render(self):
        decks = [{"id": "nemesis", "name": "Nemesis"}, {"id": "markup", "name": MARKUP_NAME},
                 {"id": "long", "name": LONG_NAME}]
        decks += [{"id": f"deck-{i}", "name": f"Deck {i}"} for i in range(3, 32)]
        self.write_decks(decks)
        target = RENDERS / "drawer-760x600.png"
        report = self.run_ui('''
          if (test.step === 0) {
            test.openBrowse()
            test.step = 1; test.later(); return
          }
          test.byName(overlay, "browseTargetArea").clicked(null)
          var list = test.byName(overlay, "browseTargets")
          list.forceLayout()
          test.check(list.count === 33 && list.clip, "all 33 targets bounded")
          for (var i = 0; i < 33; i++) {
            list.positionViewAtIndex(i, ListView.Contain); list.forceLayout()
            var row = list.itemAtIndex(i)
            test.check(row, "target reachable " + i)
            var name = test.byName(row, "browseTargetLabel")
            test.check(name.textFormat === Text.PlainText && name.width <= row.width, "target safe and bounded")
            test.byName(row, "browseTargetPick").clicked(null)
            test.check(overlay.browseTargetId === overlay.deckDefinitions[i].id, "every target selectable")
            overlay.browseTargetsOpen = true
          }
          test.pickTarget("long")
          test.check(test.byName(overlay, "browseTargetName").truncated, "long selected target elided")
          test.pickTarget("nemesis")
          test.toggleCard("lazyvim/normal/gd")
          var drawer = test.byName(overlay, "browseDrawer")
          var panel = test.byName(overlay, "testPanel")
          var position = drawer.mapToItem(panel, 0, 0)
          test.check(position.x >= 0 && position.y >= 0 && position.y + drawer.height <= panel.height,
                     "drawer inside small visible frame")
          var controls = test.byName(overlay, "topControls")
          var brand = test.byName(overlay, "topBrand")
          test.check(brand.x + brand.width <= controls.x, "brand and controls never overlap")
          test.check(controls.height <= controls.parent.height, "wrapped top controls fit")
          test.check(test.byName(overlay, "browseList").height > 100, "usable scroll viewport")
          test.check(overlay.deckId === "nemesis" && overlay.testStore.stats.runSequence === 40, "target choices never switch/start run")
        ''', target, (760, 600))
        self.assertEqual(report.get("saved"), str(target))
        self.assertGreater(target.stat().st_size, 1000)
        print(f"render saved: {target}")

    def test_render_seeded_and_added_rows(self):
        self.settings["deckCards"] = {"lsp": {"added": [IDS[0]], "removed": []}}
        self.write_state("settings", self.settings)
        target = RENDERS / "drawer-membership-1280x800.png"
        report = self.run_ui('''
          if (test.step === 0) {
            test.openBrowse()
            test.pickTarget("lsp")
            test.byName(test.byName(overlay, "browseInDeck"), "browseChipArea").clicked(null)
            test.step = 1; test.later(); return
          }
          test.check(overlay.browseRows.length > 1, "membership render rows populated")
        ''', target)
        self.assertEqual(report.get("saved"), str(target))
        self.assertGreater(target.stat().st_size, 1000)
        print(f"render saved: {target}")

    def test_render_drawer_chinese_bounded_frame(self):
        # WP8: the localized drawer asserted on actual delegates in zh-CN and
        # rendered inside the smallest supported frame for visual inspection.
        WP8_RENDERS.mkdir(exist_ok=True)
        target = WP8_RENDERS / "drawer-zh-760x600.png"
        target.unlink(missing_ok=True)
        report = self.run_ui('''
          var ZH = __ZH__
          if (test.step === 0) {
            test.openBrowse()
            test.step = 1; test.later(); return
          }
          test.check(overlay.testI18n.locale === "zh-CN", "zh-CN active")
          test.check(test.byName(overlay, "browseTargetName").text === ZH.targetNemesis,
                     "zh target selector: " + test.byName(overlay, "browseTargetName").text)
          test.check(test.byName(overlay, "browseAllCards").label === ZH.allCards, "zh all-cards chip")
          test.check(test.byName(overlay, "browseInDeck").label === ZH.inDeck, "zh in-deck chip")
          test.check(test.byName(overlay, "browseClose").label === ZH.close, "zh close chip")
          test.check(test.label("lazyvim/normal/gd") === ZH.add, "zh add action")
          test.toggleCard("lazyvim/normal/gd")
          test.check(test.label("lazyvim/normal/gd") === ZH.added, "zh added action")
          test.pickTarget("all")
          test.check(test.byName(overlay, "browseNotice").text === ZH.allReadOnly, "zh read-only notice")
          test.check(test.byName(overlay, "browseNotice").textFormat === Text.PlainText, "notice plain text")
          var drawer = test.byName(overlay, "browseDrawer")
          var panel = test.byName(overlay, "testPanel")
          var position = drawer.mapToItem(panel, 0, 0)
          test.check(panel.width === 760 && panel.height === 600, "bounded frame")
          test.check(position.x >= 0 && position.y >= 0 && position.y + drawer.height <= panel.height,
                     "drawer inside bounded frame")
        '''.replace("__ZH__", json.dumps({
            "targetNemesis": render_copy(ZH, "browseTarget", name="Nemesis"),
            "allCards": ZH["browseAllCards"], "inDeck": ZH["browseInDeck"],
            "close": ZH["browseClose"], "add": ZH["browseAdd"],
            "added": ZH["browseInDeckAdded"], "allReadOnly": ZH["browseAllReadOnly"]},
            ensure_ascii=False)), target, (760, 600), "zh-CN")
        self.assertEqual(report.get("saved"), str(target))
        self.assertGreater(target.stat().st_size, 1000)
        print(f"render saved: {target}")


if __name__ == "__main__":
    unittest.main()
