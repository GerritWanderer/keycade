import QtQuick
import QtTest
import "../../lib"
import "../../lib/sources"
import "../../lib/AnswerMatcher.js" as AnswerMatcher
import "../../lib/InputNormalizer.js" as Normalizer
import "../../lib/Profiles.js" as Profiles
import "../../lib/TextKey.js" as TextKey
import "../../lib/Scheduler.js" as Scheduler
import "../../lib/Stats.js" as Stats
import "../../lib/Session.js" as Session
import "../../lib/DotFont.js" as DotFont
import "../../lib/Palettes.js" as Palettes
import "../fixtures/text-keys.js" as TextKeys
import "../../lib/sources/pack/Eligibility.js" as PackEligibility
import "../../lib/Packs.js" as Packs

TestCase {
  name: "KeycadeAlgorithms"

  I18n { id: testI18n }

  function test_compiledLocalesSwitchAndFailClosedToEnglish() {
    testI18n.locale = "en"
    compare(testI18n.t("start"), "PRESS ENTER TO START")
    testI18n.locale = "zh-CN"
    compare(testI18n.t("start"), "按回车开始对局")
    testI18n.locale = "../../untrusted"
    compare(testI18n.t("start"), "PRESS ENTER TO START")
  }

  function binding(overrides) {
    var base = {
      modMask: 64,
      key: "3",
      keycode: 0,
      matchMode: "logical",
      flags: [],
      dontInhibit: false,
      allowInputCapture: false,
      dispatcher: "workspace",
      arg: "3",
      description: "Switch to workspace 3",
      submap: ""
    }
    for (var key in overrides) base[key] = overrides[key]
    return base
  }

  function test_inputFilterKeepsModifiersSeparateFromTextJudging() {
    compare(Normalizer.modifierMask(0), 0)
    compare(Normalizer.modifierMask(qtShift), 1)
    compare(Normalizer.modifierMask(qtCtrl), 4)
    compare(Normalizer.modifierMask(qtAlt), 8)
    compare(Normalizer.modifierMask(qtSuper), 64)
    compare(Normalizer.modifierMask(qtShift | qtCtrl | qtAlt | qtSuper), 77)
    compare(Normalizer.modifierMask(0x20000000), 0) // Keypad is not a held modifier.
    for (var key = 0x01000020; key <= 0x01000023; key++)
      verify(Normalizer.isModifier(key))
    verify(!Normalizer.isModifier(Qt.Key_Escape))
    verify(!Normalizer.isModifier(Qt.Key_G))
    verify(!Normalizer.isModifier(Qt.Key_Space))
    verify(!Normalizer.isModifier(0))
    verify(!Normalizer.isModifier(undefined))
  }

  function test_excludedListIsBoundedOnBothAxes() {
    var many = []
    for (var i = 0; i < 100; i++) many.push("hyprland:64|K|workspace|" + i)
    compare(Session.excludedList(many).length, 64)

    var long = ["hyprland:" + new Array(2400).join("a")]
    compare(Session.excludedList(long).length, 0)

    var heavy = []
    for (var j = 0; j < 64; j++) heavy.push("hyprland:" + new Array(300).join("b") + j)
    var bounded = Session.excludedList(heavy)
    verify(bounded.length < 64)
    verify(JSON.stringify(bounded).length <= 8 * 1024)

    compare(Session.excludedList(["hyprland:__proto__"]).length, 0)
    compare(Session.excludedList(["hyprland:constructor"]).length, 0)
    compare(Session.excludedList(["HYPRLAND:64|K|workspace|1"]).length, 0)
    compare(Session.excludedList(["64|K|workspace|1"]).length, 0)
    compare(Session.excludedList([17, null, {}]).length, 0)
    compare(Session.excludedList("not an array").length, 0)
    compare(Session.excludedList(["hyprland:a", "hyprland:a"]).length, 1)
  }

  function test_excludedListAddAndRemoveRespectTheCap() {
    var list = Session.withExclusion([], "hyprland", "64|K|workspace|1")
    compare(list.length, 1)
    compare(list[0], "hyprland:64|K|workspace|1")
    // Adding the same bind twice is a no-op, not a second entry.
    compare(Session.withExclusion(list, "hyprland", "64|K|workspace|1").length, 1)

    var full = []
    for (var i = 0; i < 64; i++) full.push("hyprland:64|K|workspace|" + i)
    compare(Session.withExclusion(full, "hyprland", "64|K|other|1"), null)
    compare(Session.withExclusion([], "hyprland", "__proto__"), null)
    compare(Session.withExclusion([], "Hyprland", "64|K|workspace|1"), null)

    compare(Session.withoutExclusion(list, "hyprland", "64|K|workspace|1").length, 0)
    compare(Session.withoutExclusion(list, "hyprland", "64|K|missing|1").length, 1)
    compare(Session.withoutExclusion(list, "lazyvim", "64|K|workspace|1").length, 1)
  }

  function test_foreignExclusionsRemainRetainedAndInert() {
    var foreign = ["hyprland", "herdr", "tmux", "vim", "neovim", "future-supply"]
    var values = ["lazyvim:normal/<leader>ff"]
    for (var index = 0; index < foreign.length; index++)
      values.push(foreign[index] + ":normal/a:b/c")
    compare(JSON.stringify(Session.excludedList(values)), JSON.stringify(values))
    var active = Session.excludedSet(values, Profiles.defaultId())
    compare(Object.getPrototypeOf(active), null)
    compare(Object.keys(active).join(","), "normal/<leader>ff")
    // Curation of a current exclusion never clears another namespace.
    var removed = Session.withoutExclusion(values, "lazyvim", "normal/<leader>ff")
    compare(JSON.stringify(removed), JSON.stringify(values.slice(1)))
    var restored = Session.withExclusion(removed, "lazyvim", "normal/<leader>ff")
    compare(restored.length, values.length)
    for (var second = 0; second < foreign.length; second++)
      verify(Session.excludedSet(restored, foreign[second])["normal/a:b/c"])
    compare(Session.excludedList(["constructor:x", "prototype:x", "__proto__:x"]).length, 0)
  }

  // The HUD draws these cells itself, so a row wider than five bits or a
  // glyph with the wrong number of rows would silently deform the digit.
  function test_dotFontGlyphsAreFiveBySeven() {
    var supported = DotFont.supported()
    compare(supported.length, 14)
    for (var i = 0; i < supported.length; i++) {
      var rows = DotFont.glyph(supported[i])
      compare(rows.length, 7, supported[i])
      for (var j = 0; j < rows.length; j++) {
        verify(rows[j] >= 0)
        verify(rows[j] <= 0x1f)
      }
    }
    for (var digit = 0; digit <= 9; digit++)
      verify(supported.indexOf(String(digit)) !== -1)

    // Unknown input renders blank instead of throwing: this feeds a decoration.
    var blank = DotFont.glyph("W")
    compare(blank.length, 7)
    for (var k = 0; k < blank.length; k++) compare(blank[k], 0)
    compare(DotFont.glyph(undefined).length, 7)
    compare(DotFont.glyph("__proto__")[0], 0)
  }

  // Every palette has to answer for every role: a missing one would render as
  // a transparent colour rather than failing, and an unknown theme name from a
  // newer settings file must land somewhere legible instead of nowhere.
  function test_everyPaletteDefinesEveryRole() {
    var names = Palettes.names()
    compare(names.length, 5)
    verify(names.indexOf("tokyo") !== -1)
    verify(names.indexOf("gruvbox") !== -1)
    for (var i = 0; i < names.length; i++) {
      var palette = Palettes.palette(names[i])
      for (var j = 0; j < Palettes.roles.length; j++) {
        var value = palette[Palettes.roles[j]]
        verify(typeof value === "string", names[i] + "." + Palettes.roles[j])
        verify(/^#[0-9a-f]{6}$/.test(value), names[i] + "." + Palettes.roles[j] + " = " + value)
      }
      verify(Palettes.supported(names[i]))
    }
    verify(!Palettes.supported("no-such-theme"))
    verify(!Palettes.supported(""))
    verify(!Palettes.supported(undefined))
    verify(Palettes.supported(Palettes.defaultName()))
    compare(Palettes.palette("no-such-theme"), Palettes.palette(Palettes.defaultName()))
    compare(Palettes.palette("__proto__"), Palettes.palette(Palettes.defaultName()))
  }

  function test_guidedInputDoesNotAffectFirstTryWindow() {
    var stats = Stats.defaults()
    Stats.recordGuided(stats, "one", 1, 1000)
    compare(Stats.metrics(stats.bindings.one).samples, 0)
    Stats.recordFirstTry(stats, "one", true, 1000, 1, 2000)
    Stats.recordFirstTry(stats, "one", false, -1, 1, 3000)
    compare(Stats.metrics(stats.bindings.one).samples, 2)
    compare(Stats.metrics(stats.bindings.one).accuracy, 0.5)
    Stats.requestGuidance(stats, "one")
    compare(Stats.tier(stats.bindings.one), "guided")
  }

  function test_masteryRequiresTwoRecentCorrectAcrossTwoRunsAndLapses() {
    var sameRun = Stats.defaults()
    Stats.recordGuided(sameRun, "same-run", 1, 1000)
    Stats.recordFirstTry(sameRun, "same-run", true, 900, 1, 2000)
    Stats.recordFirstTry(sameRun, "same-run", true, 850, 1, 3000)
    compare(sameRun.bindings["same-run"].state, "learning")

    var stats = Stats.defaults()
    Stats.recordGuided(stats, "one", 1, 1000)
    Stats.recordFirstTry(stats, "one", true, 900, 1, 2000)
    compare(stats.bindings.one.state, "learning")
    var result = Stats.recordFirstTry(stats, "one", true, 800, 2, 4000)
    verify(result.masteredGained)
    compare(stats.bindings.one.state, "mastered")
    compare(stats.bindings.one.successfulRuns.length, 2)

    result = Stats.recordFirstTry(stats, "one", false, -1, 3, 8000)
    verify(result.lapsed)
    compare(stats.bindings.one.state, "learning")
    compare(stats.bindings.one.lapseCount, 1)

    Stats.recordFirstTry(stats, "one", true, 700, 4, 9000)
    compare(stats.bindings.one.state, "learning")
    result = Stats.recordFirstTry(stats, "one", true, 660, 5, 11000)
    verify(result.masteredGained)
    compare(stats.bindings.one.state, "mastered")
  }

  function test_migrationPromotesLearningProgressUnderTheEasierRule() {
    var stats = Stats.migrate({
      schemaVersion: 3,
      runs: 3,
      bindings: {
        one: {
          state: "learning",
          guidedCompleted: true,
          firstTryAttempts: 3,
          firstTryCorrect: 3,
          recentFirstTry: [true, true, true],
          successfulRuns: [1, 2, 3]
        }
      }
    })
    compare(stats.bindings["hyprland/one"].state, "mastered")
  }

  function test_reactionHistoryKeepsOnlyTheLatestTenSamples() {
    var stats = Stats.defaults()
    Stats.recordGuided(stats, "timed", 1, 100)
    for (var index = 0; index < 12; index++)
      Stats.recordFirstTry(stats, "timed", true, 500 + index * 10, index + 1, 200 + index)
    compare(stats.bindings.timed.reactions.length, 10)
    compare(stats.bindings.timed.reactions[0], 520)
    compare(stats.bindings.timed.reactions[9], 610)
    compare(Stats.percentile75(stats.bindings.timed.reactions), 590)
  }

  function test_lifetimeSummaryAndFirstMasteryMilestone() {
    var stats = Stats.defaults()
    Stats.recordGuided(stats, "first", 1, 100)
    Stats.recordFirstTry(stats, "first", true, 500, 1, 200)
    Stats.recordFirstTry(stats, "first", false, -1, 2, 300)
    Stats.recordGuided(stats, "second", 1, 100)
    Stats.recordFirstTry(stats, "second", true, 900, 1, 200)

    var summary = Stats.aggregate(stats, [{ id: "first" }, { id: "second" }])
    compare(summary.attempts, 3)
    compare(summary.correct, 2)
    compare(summary.accuracy, 67)
    compare(summary.response, 900)

    verify(Stats.noteFirstMastery(stats, "hyprland", 12345, 7))
    var counters = Stats.counters(stats, "hyprland")
    compare(counters.firstMasteryAt, 12345)
    compare(counters.firstMasteryRun, 7)
    verify(!counters.firstMasteryCelebrated)
    verify(!Stats.noteFirstMastery(stats, "hyprland", 23456, 8))
    verify(Stats.markFirstMasteryCelebrated(stats, "hyprland"))
    verify(!Stats.markFirstMasteryCelebrated(stats, "hyprland"))

    compare(Stats.addTrainingTime(stats, "hyprland", 654321), 654321)
    compare(Stats.addTrainingTime(stats, "hyprland", -10), 654321)
    var migrated = Stats.migrate(stats)
    compare(migrated.schemaVersion, 5)
    var migratedCounters = Stats.counters(migrated, "hyprland")
    compare(migratedCounters.totalTrainingMs, 654321)
    compare(migratedCounters.firstMasteryAt, 12345)
    compare(migratedCounters.firstMasteryRun, 7)
    verify(migratedCounters.firstMasteryCelebrated)
  }

  // Every training ground counts its own runs, its own coverage and its own
  // full clear. Sharing them would make "everything mastered" mean whichever
  // ground happened to finish first.
  function test_countersAreKeptPerTrainingGround() {
    var stats = Stats.defaults()
    compare(Stats.completeRun(stats, "hyprland"), 1)
    compare(Stats.completeRun(stats, "hyprland"), 2)
    compare(Stats.completeRun(stats, "lazyvim"), 1)
    compare(Stats.runsOf(stats, "hyprland"), 2)
    compare(Stats.runsOf(stats, "lazyvim"), 1)

    verify(Stats.noteFirstMastery(stats, "hyprland", 100, 2))
    compare(Stats.counters(stats, "lazyvim").firstMasteryAt, 0)
    verify(Stats.noteFirstMastery(stats, "lazyvim", 200, 1))

    // Reading never creates a record: activeRunId is a binding on the stats
    // object, and a read that wrote would mutate state from inside a binding.
    compare(Stats.counters(stats, "tmux").runs, 0)
    compare(stats.decks["tmux"], undefined)
    // A name outside the deck character set is refused outright.
    compare(Stats.completeRun(stats, "__proto__"), 1)
    compare(stats.decks["__proto__"], undefined)
    compare(Object.keys(stats.decks).length, 2)
  }

  function test_qualifiedIdsCarryTheirProfileAndKeepTheLocalPart() {
    compare(Profiles.qualify("hyprland", "64|K|exec|x"), "hyprland/64|K|exec|x")
    compare(Profiles.profileOf("hyprland/64|K|exec|x"), "hyprland")
    compare(Profiles.localOf("hyprland/64|K|exec|x"), "64|K|exec|x")

    // A local id may hold a path of its own, so only the first segment counts.
    compare(Profiles.profileOf("hyprland/64|E|exec|~/.local/bin/tool"), "hyprland")
    compare(Profiles.localOf("hyprland/64|E|exec|~/.local/bin/tool"), "64|E|exec|~/.local/bin/tool")

    // An id written before profiles existed has no readable ground in front
    // of it, which is exactly how it is recognised on the way in.
    compare(Profiles.profileOf("64|E|exec|~/.local/bin/tool"), "")
    compare(Profiles.qualifyLegacy("64|K|exec|x"), "hyprland/64|K|exec|x")
    compare(Profiles.qualifyLegacy("hyprland/64|K|exec|x"), "hyprland/64|K|exec|x")
    compare(Profiles.qualify("Hyprland", "x"), "")
    compare(Profiles.qualify("__proto__", "x"), "")
    compare(Profiles.qualify("constructor", "x"), "")
    compare(Profiles.qualify("prototype", "x"), "")
    // Retired and not-yet-known namespaces are syntactically valid history,
    // not registered supplies. D10 must never depend on known().
    var foreign = ["hyprland", "herdr", "tmux", "vim", "neovim", "lazygit"]
    for (var index = 0; index < foreign.length; index++) {
      var id = foreign[index]
      verify(Profiles.valid(id))
      verify(!Profiles.known(id))
      verify(!Profiles.isPack(id))
      compare(Profiles.qualify(id, "normal/a/b"), id + "/normal/a/b")
      compare(Profiles.profileOf(id + "/normal/a/b"), id)
      compare(Profiles.localOf(id + "/normal/a/b"), "normal/a/b")
      compare(Profiles.qualifyLegacy(id + "/normal/a/b"), id + "/normal/a/b")
    }
  }

  function test_lazyvimIsTheOnlySupplyAndDefault() {
    compare(Profiles.ids().join(","), "lazyvim")
    compare(Profiles.defaultId(), "lazyvim")
    verify(Profiles.known("lazyvim"))
    verify(Profiles.isPack("lazyvim"))
    compare(Profiles.profile("lazyvim").judgeMode, "text")
    compare(Profiles.profile("lazyvim").answerModel, "sequence")
    compare(Profiles.contexts("lazyvim").join(","), "normal,visual,insert,operator")
    compare(Profiles.optionNames("lazyvim").join(","), "leader,localleader")
  }

  function test_v1StatsMigrateWithoutInventingMastery() {
    var migrated = Stats.migrate({
      schemaVersion: 1,
      runs: 9,
      bestScore: 5000,
      bindings: {
        one: {
          attempts: [
            { correct: true, guided: true, at: 1, reactionMs: 900 },
            { correct: true, guided: false, at: 2, reactionMs: 800 },
            { correct: false, guided: false, at: 3 }
          ],
          hits: 2,
          misses: 1,
          guidedHits: 1,
          lastSeen: 3
        }
      }
    })
    compare(migrated.schemaVersion, 5)
    var counters = Stats.counters(migrated, "hyprland")
    compare(counters.runs, 0) // retired counters never become all's progress
    compare(counters.totalTrainingMs, 0)
    compare(counters.firstMasteryAt, 0)
    verify(!counters.firstMasteryCelebrated)
    // The local part of the id is unchanged; only the ground moves in front.
    compare(migrated.bindings["hyprland/one"].state, "learning")
    compare(migrated.bindings["hyprland/one"].firstTryAttempts, 2)
    compare(migrated.bindings["hyprland/one"].firstTryCorrect, 1)
    compare(migrated.bindings["hyprland/one"].successfulRuns.length, 0)
    compare(migrated.bindings.one, undefined)
    compare(migrated.bindings["lazyvim/one"], undefined)
    compare(Object.keys(migrated.decks).length, 0)
  }

  function test_v2StatsPreserveProgressAndGainMilestoneDefaults() {
    var migrated = Stats.migrate({
      schemaVersion: 2,
      runs: 12,
      coverageCursor: 8,
      bindings: {
        one: {
          state: "mastered",
          guidedCompleted: true,
          firstTryAttempts: 6,
          firstTryCorrect: 5,
          recentFirstTry: [true, true, true, true, true],
          reactions: [700, 650],
          successfulRuns: [8, 10, 12],
          lastSuccessfulRun: 12
        }
      }
    })
    compare(migrated.schemaVersion, 5)
    var counters = Stats.counters(migrated, "hyprland")
    compare(counters.runs, 0)
    compare(counters.coverageCursor, 0)
    compare(migrated.bindings["hyprland/one"].state, "mastered")
    compare(migrated.bindings["hyprland/one"].firstTryCorrect, 5)
    compare(migrated.bindings["lazyvim/one"], undefined)
    compare(Object.keys(migrated.decks).length, 0)
    compare(counters.totalTrainingMs, 0)
    compare(counters.firstMasteryAt, 0)
    compare(counters.firstMasteryRun, 0)
    verify(!counters.firstMasteryCelebrated)
  }

  // The upgrade that introduced training grounds must not cost anyone their
  // progress: every stored entry keeps its history, and its id keeps its local
  // part byte for byte, because that is what an exclusion already names.
  function test_v3StatsMoveIntoTheHyprlandGroundWithoutLosingProgress() {
    var localId = "64|K|exec|terminal"
    var migrated = Stats.migrate({
      schemaVersion: 3,
      runs: 12,
      coverageCursor: 8,
      totalTrainingMs: 654321,
      firstMasteryAt: 12345,
      firstMasteryRun: 7,
      firstMasteryCelebrated: true,
      bindings: {
        "64|K|exec|terminal": {
          state: "mastered",
          guidedCompleted: true,
          firstTryAttempts: 6,
          firstTryCorrect: 5,
          recentFirstTry: [true, true],
          reactions: [700, 650],
          successfulRuns: [8, 10],
          lastSuccessfulRun: 12,
          intervalStep: 3
        }
      }
    })
    compare(migrated.schemaVersion, 5)
    var counters = Stats.counters(migrated, "hyprland")
    compare(counters.runs, 0)
    compare(counters.coverageCursor, 0)
    compare(counters.totalTrainingMs, 0)
    compare(counters.firstMasteryAt, 0)
    compare(counters.firstMasteryRun, 0)
    verify(!counters.firstMasteryCelebrated)
    compare(Object.keys(migrated.decks).length, 0)

    var entry = migrated.bindings["hyprland/" + localId]
    compare(Profiles.localOf("hyprland/" + localId), localId)
    compare(entry.state, "mastered")
    compare(entry.firstTryAttempts, 6)
    compare(entry.firstTryCorrect, 5)
    compare(entry.intervalStep, 3)
    compare(entry.successfulRuns.length, 2)

    // Migrating the result again is a no-op rather than a second prefix.
    var again = Stats.migrate(migrated)
    compare(again.schemaVersion, 5)
    compare(Stats.counters(again, "hyprland").runs, 0)
    compare(again.bindings["hyprland/" + localId].firstTryCorrect, 5)
    compare(again.bindings["hyprland/hyprland/" + localId], undefined)
    compare(again.bindings["lazyvim/" + localId], undefined)
    compare(again.decks.all, undefined)
  }

  // The longest id a source can mint still migrates: the local part is bounded
  // before the prefix goes on, not after.
  function test_longLegacyIdsSurviveTheMigrationWithTheirPrefix() {
    var localId = "64|K|exec|" + "x".repeat(2290)
    compare(localId.length, 2300)
    var source = { schemaVersion: 3, runs: 1, bindings: {} }
    source.bindings[localId] = { state: "learning", guidedCompleted: true }
    var migrated = Stats.migrate(source)
    compare(migrated.bindings["hyprland/" + localId].state, "learning")

    var sanitized = Session.sanitize({
      schemaVersion: 1,
      runId: 1,
      cards: [{ bindingId: localId, tier: "learning", queue: "due", remedial: false }]
    })
    compare(sanitized.cards[0].bindingId, "hyprland/" + localId)
  }

  // Progress is now derived from the current corpus rather than stale counts
  // recorded by a ground. Excluding a card changes only that denominator.
  function test_progressIsComputedWithoutPersistingKnownTotals() {
    var stats = Stats.migrate({ schemaVersion: 4,
      bindings: { "lazyvim/one": { state: "mastered" }, "lazyvim/two": { state: "learning" } },
      profiles: { lazyvim: { runs: 3, knownTotal: 10, knownMastered: 99 } } })
    var both = Stats.counts(stats, [{ id: "lazyvim/one" }, { id: "lazyvim/two" }], 1, 4)
    compare(both.total, 2)
    compare(both.mastered, 1)
    var filtered = Stats.counts(stats, [{ id: "lazyvim/one" }], 1, 4)
    compare(filtered.total, 1)
    compare(filtered.mastered, 1)
    compare(Stats.counts(stats, [], 1, 4).total, 0)
    compare(Stats.counters(stats, "all").runs, 3)
    compare(Stats.counters(stats, "all").knownTotal, undefined)
    compare(Stats.counters(stats, "all").knownMastered, undefined)
    var saved = Stats.migrate(stats)
    compare(saved.decks.all.knownTotal, undefined)
    compare(saved.bindings["lazyvim/two"].state, "learning")
  }

  function test_foreignHistorySurvivesWithoutContributingToLazyvim() {
    var foreign = ["hyprland", "herdr", "tmux", "vim", "neovim", "future-supply"]
    var source = Stats.defaults()
    for (var index = 0; index < foreign.length; index++) {
      var name = foreign[index]
      var id = name + "/normal/a:b/c"
      Stats.recordGuided(source, id, 1, 100)
      Stats.recordFirstTry(source, id, true, 500, 1, 200)
      Stats.completeRun(source, name)
    }
    var before = JSON.stringify(source)
    var migrated = Stats.parse(before)
    compare(JSON.stringify(migrated), before)
    compare(Object.getPrototypeOf(migrated.bindings), null)
    compare(Object.getPrototypeOf(migrated.decks), null)
    compare(Stats.runsOf(migrated, "lazyvim"), 0)
    var active = [{ id: "lazyvim/normal/a:b/c" }]
    compare(Stats.aggregate(migrated, active).attempts, 0)
    compare(Stats.counts(migrated, active, 300, 1).mastered, 0)
    for (var second = 0; second < foreign.length; second++) {
      var savedId = foreign[second] + "/normal/a:b/c"
      compare(JSON.stringify(migrated.bindings[savedId]), JSON.stringify(source.bindings[savedId]))
      var session = Session.sanitize({ schemaVersion: 1, profileId: foreign[second], runId: 1,
        currentBindingId: savedId, cards: [{ bindingId: savedId, tier: "learning", queue: "due" }],
        pendingReinforcements: [savedId], runResults: {} })
      compare(session.profileId, foreign[second])
      compare(session.currentBindingId, savedId)
      compare(session.cards[0].bindingId, savedId)
      compare(session.pendingReinforcements[0], savedId)
      verify(!Session.canResume(session, 1, active, 24, "lazyvim"))
    }
  }

  function test_v4StatsDropEntriesWithNoTrainingGround() {
    var migrated = Stats.migrate({
      schemaVersion: 4,
      profiles: { hyprland: { runs: 3 }, "__proto__": { runs: 9 }, "Nope": { runs: 9 } },
      bindings: { "hyprland/kept": { state: "learning" }, "orphan": { state: "learning" } }
    })
    compare(Stats.counters(migrated, "hyprland").runs, 0)
    compare(migrated.decks["__proto__"], undefined)
    compare(migrated.decks["Nope"], undefined)
    compare(Object.keys(migrated.decks).length, 0)
    compare(migrated.bindings["hyprland/kept"].state, "learning")
    compare(migrated.bindings["orphan"], undefined)
  }

  function test_persistedStatsRejectPrototypeKeysAndClampNumbers() {
    var source = JSON.parse('{"schemaVersion":3,"runs":1e100,"bindings":{"__proto__":{"state":"mastered"},"safe":{"firstTryAttempts":1e100,"firstTryCorrect":1e100}}}')
    var migrated = Stats.migrate(source)
    compare(migrated.bindings["__proto__"], undefined)
    compare(migrated.bindings["hyprland/__proto__"], undefined)
    compare(Object.keys(migrated.decks).length, 0)
    compare(migrated.bindings["hyprland/safe"].firstTryAttempts, 1000000000)
    compare(migrated.bindings["hyprland/safe"].firstTryCorrect, 1000000000)
  }

  function test_schedulerSmallDeckDealsEachBindingExactlyOnce() {
    var bindings = []
    for (var index = 0; index < 8; index++) {
      var item = binding({ key: String(index), arg: String(index), description: "Switch to workspace " + index })
      item.id = Profiles.qualify("lazyvim", "scheduler/" + index)
      bindings.push(item)
    }
    var deck = Scheduler.build(bindings, Stats.defaults(), 24)
    compare(deck.length, 8)
    for (var i = 1; i < deck.length; i++) verify(deck[i].binding.id !== deck[i - 1].binding.id)
    var counts = {}
    for (var j = 0; j < deck.length; j++)
      counts[deck[j].binding.id] = Number(counts[deck[j].binding.id] || 0) + 1
    for (var id in counts) compare(counts[id], 1)
  }

  function test_schedulerBalancesCategoriesAcrossTheRun() {
    var categories = ["windows", "workspaces", "system", "applications"]
    var bindings = []
    for (var categoryIndex = 0; categoryIndex < categories.length; categoryIndex++) {
      for (var itemIndex = 0; itemIndex < 2; itemIndex++) {
        var item = binding({
          key: String(categoryIndex * 2 + itemIndex),
          arg: String(categoryIndex * 2 + itemIndex),
          description: categories[categoryIndex] + " " + itemIndex
        })
        item.category = categories[categoryIndex]
        item.id = Profiles.qualify("lazyvim", "scheduler/" + categoryIndex + "/" + itemIndex)
        bindings.push(item)
      }
    }
    var deck = Scheduler.build(bindings, Stats.defaults(), 8)
    var counts = {}
    for (var i = 0; i < deck.length; i++) {
      var name = deck[i].binding.category
      counts[name] = Number(counts[name] || 0) + 1
    }
    for (var j = 0; j < categories.length; j++) compare(counts[categories[j]], 2)
  }

  function test_schedulerKeepsCoverageMovingWithAllQueuesPopulated() {
    var stats = Stats.defaults()
    var bindings = []
    var now = 1000000
    for (var index = 0; index < 60; index++) {
      var item = binding({
        key: String(index),
        arg: String(index),
        description: "Shortcut " + index
      })
      item.id = "hyprland/binding-" + String(index).padStart(2, "0")
      item.category = ["windows", "workspaces", "system", "applications"][index % 4]
      bindings.push(item)
      if (index >= 30 && index < 40) {
        Stats.recordGuided(stats, item.id, 1, now - 100)
        stats.bindings[item.id].dueRun = 1
      } else if (index >= 40 && index < 50) {
        Stats.recordGuided(stats, item.id, 1, now - 100)
        stats.bindings[item.id].dueRun = 99
      } else if (index >= 50) {
        var mastered = Stats.entry(stats, item.id)
        mastered.guidedCompleted = true
        mastered.state = "mastered"
        mastered.dueAt = now + 86400000
      }
    }

    var seen = {}
    for (var run = 1; run <= 5; run++) {
      var deck = Scheduler.build(bindings, stats, 24, { now: now, runId: run, deckId: "coverage" })
      var unseenCards = deck.filter(function(card) { return card.queue === "unseen" })
      compare(unseenCards.length, 6)
      unseenCards.forEach(function(card) {
        seen[card.binding.id] = true
        Scheduler.markCovered(bindings, stats, card.binding.id, "coverage")
        Stats.recordGuided(stats, card.binding.id, run, now)
        stats.bindings[card.binding.id].dueRun = 99
      })
    }
    compare(Object.keys(seen).length, 30)
  }

  function test_schedulerOnlyAdvancesCoverageAfterCardIsShown() {
    var stats = Stats.defaults()
    var bindings = []
    for (var index = 0; index < 10; index++) {
      var item = binding({ key: String(index), arg: String(index), description: "New " + index })
      item.id = "hyprland/new-" + index
      bindings.push(item)
    }
    var deck = Scheduler.build(bindings, stats, 8, { now: 100, runId: 1 })
    compare(Stats.counters(stats, "coverage").coverageCursor, 0)
    Scheduler.markCovered(bindings, stats, deck[0].binding.id, "coverage")
    verify(Stats.counters(stats, "coverage").coverageCursor !== 0)
    compare(Stats.counters(stats, "hyprland").coverageCursor, 0)
  }

  function test_schedulerPrioritizesDueBeforeMaintenance() {
    var stats = Stats.defaults()
    var bindings = []
    for (var index = 0; index < 24; index++) {
      var item = binding({ key: String(index), arg: String(index), description: "Item " + index })
      item.id = "hyprland/item-" + index
      bindings.push(item)
      var progress = Stats.entry(stats, item.id)
      progress.guidedCompleted = true
      progress.state = "mastered"
      progress.dueAt = index < 10 ? 1 : 999999999
    }
    var deck = Scheduler.build(bindings, stats, 10, { now: 100, runId: 1 })
    compare(deck.filter(function(card) { return card.queue === "due" }).length, 10)
    compare(deck.filter(function(card) { return card.queue === "maintenance" }).length, 0)
  }

  function test_remedialReviewIsInsertedAfterThreeToFiveOtherCards() {
    var stats = Stats.defaults()
    var bindings = []
    for (var index = 0; index < 8; index++) {
      var item = binding({ key: String(index), arg: String(index), description: "Review " + index })
      item.id = "hyprland/review-" + index
      bindings.push(item)
    }
    var deck = Scheduler.build(bindings, stats, 8, { now: 100, runId: 1 })
    var updated = Scheduler.insertRemedial(deck, 1, deck[1].binding)
    compare(updated.length, 8)
    var remedialIndex = updated.findIndex(function(card) {
      return card.remedial && card.binding.id === deck[1].binding.id
    })
    verify(remedialIndex - 1 - 1 >= 3)
    verify(remedialIndex - 1 - 1 <= 5)

    var late = Scheduler.insertRemedial(deck, 7, deck[7].binding)
    compare(late.length, 8)
    compare(late.filter(function(card) { return card.remedial }).length, 0)
  }

  function test_remedialReviewNeverExtendsTheRunNearTheEnd() {
    var deck = []
    for (var index = 0; index < 24; index++) {
      var item = binding({ key: String(index), arg: String(index), description: "Card " + index })
      item.id = "fixed-" + index
      deck.push({ binding: item, tier: "learning", queue: "weak", remedial: false })
    }
    var updated = Scheduler.insertRemedial(deck, 21, deck[21].binding)
    compare(updated.length, 24)
    compare(updated.filter(function(card) { return card.remedial }).length, 0)
  }

  function test_remedialReviewReplacesTheLowestPriorityFutureSlot() {
    var deck = []
    for (var index = 0; index < 8; index++) {
      var item = binding({ key: String(index), arg: String(index), description: "Priority " + index })
      item.id = "priority-" + index
      deck.push({
        binding: item,
        tier: index === 6 ? "maintenance" : "learning",
        queue: index === 6 ? "maintenance" : "due",
        remedial: false
      })
    }
    var updated = Scheduler.insertRemedial(deck, 0, deck[0].binding)
    compare(updated.length, 8)
    verify(updated[6].remedial)
    compare(updated[6].binding.id, deck[0].binding.id)
    compare(updated[4].queue, "due")
    compare(updated[5].queue, "due")
  }

  function test_runPlanCountsDistinctNewAndReviewBindings() {
    var first = binding({ key: "1", arg: "1", description: "First" })
    first.id = "first-plan"
    var second = binding({ key: "2", arg: "2", description: "Second" })
    second.id = "second-plan"
    var counts = Scheduler.planCounts([
      { binding: first, tier: "guided", queue: "unseen", remedial: false },
      { binding: first, tier: "guided", queue: "unseen", remedial: false },
      { binding: second, tier: "learning", queue: "due", remedial: false }
    ])
    compare(counts.added, 1)
    compare(counts.review, 1)
  }

  function test_savedSessionRestoresRemainingCardsAndCorrection() {
    var first = binding({ key: "1", arg: "1", description: "First" })
    first.id = "lazyvim/first"
    var second = binding({ key: "2", arg: "2", description: "Second" })
    second.id = "lazyvim/second"
    var deck = [
      { binding: first, tier: "learning", queue: "due", remedial: false },
      { binding: second, tier: "learning", queue: "remedial", remedial: true }
    ]
    var cards = Session.cardsFrom(deck, 1)
    compare(cards.length, 1)
    compare(cards[0].bindingId, "lazyvim/second")
    verify(cards[0].remedial)
    var saved = {
      schemaVersion: 1, profileId: "lazyvim", runId: 4, cards: cards, correctionRequired: true
    }
    verify(Session.canResume(saved, 4, [first, second], 24, "all"))
    verify(!Session.canResume(saved, 5, [first, second], 24, "all"))
    // A legacy LazyVim run maps only to all, not any similarly named deck.
    verify(!Session.canResume(saved, 4, [first, second], 24, "lazyvim"))
    saved.offset = 24
    verify(!Session.canResume(saved, 4, [first, second], 24, "all"))
    var restored = Session.restoreCards(cards, [first, second])
    compare(restored.length, 1)
    compare(restored[0].binding.id, "lazyvim/second")
    verify(restored[0].remedial)
  }

  // Pre-profile sessions keep their historical namespace, but cannot resume
  // into a user deck named after that retired ground.
  function test_sessionsSavedBeforeProfilesRemainInert() {
    var first = binding({ key: "1", arg: "1", description: "First" })
    first.id = "hyprland/first"
    var sanitized = Session.sanitize({
      schemaVersion: 1,
      runId: 4,
      offset: 1,
      cards: [{ bindingId: "first", tier: "learning", queue: "due", remedial: false }],
      currentBindingId: "first",
      pendingReinforcements: ["first"],
      runResults: { "first": { misses: 2, reactions: [800] } }
    })
    compare(Profiles.defaultId(), "lazyvim")
    compare(sanitized.profileId, "hyprland")
    compare(sanitized.cards[0].bindingId, "hyprland/first")
    compare(sanitized.currentBindingId, "hyprland/first")
    compare(sanitized.pendingReinforcements[0], "hyprland/first")
    compare(sanitized.runResults["hyprland/first"].misses, 2)
    verify(!Session.canResume(sanitized, 4, [first], 24, "hyprland"))
    verify(!Session.canResume(sanitized, 4, [first], 24, "lazyvim"))
    compare(sanitized.runResults["lazyvim/first"], undefined)

    // Sanitising twice must not prefix twice.
    var again = Session.sanitize(sanitized)
    compare(again.cards[0].bindingId, "hyprland/first")
    compare(again.runResults["hyprland/first"].misses, 2)
  }

  function test_sessionSanitizerBoundsCollectionsAndDynamicKeys() {
    var cards = []
    for (var index = 0; index < 40; index++)
      cards.push({ bindingId: "binding-" + index, tier: "invalid", queue: "invalid" })
    var saved = JSON.parse('{"schemaVersion":1,"runId":2,"cards":[],"runResults":{"__proto__":{"misses":99}}}')
    saved.cards = cards
    var sanitized = Session.sanitize(saved)
    compare(sanitized.cards.length, 24)
    compare(sanitized.cards[0].tier, "learning")
    compare(sanitized.cards[0].queue, "weak")
    compare(sanitized.runResults["__proto__"], undefined)
  }

  // --- the answer model: a chord is the length-1 case of a sequence ---

  readonly property int qtShift: 0x02000000
  readonly property int qtCtrl: 0x04000000
  readonly property int qtAlt: 0x08000000
  readonly property int qtSuper: 0x10000000

  readonly property var namedEvents: ({
    "CR": { key: 0x01000004, text: "\r" },
    "TAB": { key: 0x01000001, text: "\t" },
    "ESC": { key: 0x01000000, text: "\u001b" },
    "SPACE": { key: 0x20, text: " " },
    "BS": { key: 0x01000003, text: "\b" },
    "DEL": { key: 0x01000007, text: "" },
    "UP": { key: 0x01000013, text: "" },
    "DOWN": { key: 0x01000015, text: "" }
  })

  // The key press a keyboard would actually deliver for one text step. With a
  // modifier down a terminal receives a control character rather than the
  // letter, which is why the step is judged from event.key there.
  function textEvent(step) {
    var mods = Number(step.mods || 0)
    var qtModifiers = 0
    if (mods & 4) qtModifiers |= qtCtrl
    if (mods & 8) qtModifiers |= qtAlt
    if (mods & 64) qtModifiers |= qtSuper
    if (step.named) {
      var named = namedEvents[step.named]
      return { key: named.key, text: mods ? "" : named.text, modifiers: qtModifiers, isAutoRepeat: false }
    }
    var character = String(step.text)
    var upper = character.toUpperCase()
    if (upper !== character.toLowerCase() && upper === character) qtModifiers |= qtShift
    return {
      key: upper.charCodeAt(0),
      text: mods ? "\u0017" : character,
      modifiers: qtModifiers,
      isAutoRepeat: false
    }
  }

  function textAnswer(steps) {
    return { judgeMode: "text", context: "normal", steps: steps }
  }

  function typeAll(answer, steps) {
    var state = AnswerMatcher.begin()
    var verdict = ""
    for (var index = 0; index < steps.length; index++)
      verdict = AnswerMatcher.advance(state, answer, textEvent(steps[index]))
    return { verdict: verdict, cursor: AnswerMatcher.typedSteps(state) }
  }

  // The producer writes these steps into a pack; the consumer judges presses
  // against them. Both sides are held to this one corpus.
  function test_textStepsFromTheSharedCorpusAreAcceptedAndMatched() {
    verify(TextKeys.pairs.length > 20)
    for (var index = 0; index < TextKeys.pairs.length; index++) {
      var notation = TextKeys.pairs[index][0]
      var steps = TextKeys.pairs[index][1]
      compare(JSON.stringify(TextKey.parseNotation(notation)), JSON.stringify(steps), notation)
      for (var stepIndex = 0; stepIndex < steps.length; stepIndex++) {
        var normalized = TextKey.normalizedStep(steps[stepIndex])
        verify(normalized !== null, notation + " step " + stepIndex + " was refused")
        verify(TextKey.matches(normalized, TextKey.normalizeEvent(textEvent(steps[stepIndex]))),
               notation + " step " + stepIndex + " did not match its own key press")
      }
      var result = typeAll(textAnswer(steps), steps)
      compare(result.verdict, "hit", notation)
    }
  }

  function test_runtimeNotationParserKeepsConfigurableKeysAsPlaceholders() {
    var steps = TextKey.parseNotation("<leader>f<localleader>r")
    compare(steps.length, 4)
    compare(steps[0].option, "leader")
    compare(steps[1].text, "f")
    compare(steps[2].option, "localleader")
    compare(steps[3].text, "r")
    compare(TextKey.parseNotation("<Plug>(mine)"), null)
    compare(TextKey.parseNotation("unterminated<"), null)
    var unicode = TextKey.parseNotation("你😀")
    compare(unicode.length, 2)
    compare(unicode[0].text, "你")
    compare(unicode[1].text, "😀")
  }

  // Case is decisive with no modifier held, and is not with one: Vim reads
  // <C-w> and <C-W> as one mapping but g and G as two.
  function test_textModeIsCaseSensitiveOnlyWithoutAModifier() {
    var lower = TextKey.normalizedStep({ mods: 0, text: "g" })
    var upper = TextKey.normalizedStep({ mods: 0, text: "G" })
    verify(TextKey.matches(lower, TextKey.normalizeEvent(textEvent({ mods: 0, text: "g" }))))
    verify(!TextKey.matches(lower, TextKey.normalizeEvent(textEvent({ mods: 0, text: "G" }))))
    verify(TextKey.matches(upper, TextKey.normalizeEvent(textEvent({ mods: 0, text: "G" }))))
    verify(!TextKey.matches(upper, TextKey.normalizeEvent(textEvent({ mods: 0, text: "g" }))))

    var control = TextKey.normalizedStep({ mods: 4, text: "w" })
    verify(TextKey.matches(control, TextKey.normalizeEvent(textEvent({ mods: 4, text: "w" }))))
    verify(TextKey.matches(control, TextKey.normalizeEvent(textEvent({ mods: 4, text: "W" }))))
    // A modifier is part of the answer, so the bare letter is not the answer.
    verify(!TextKey.matches(control, TextKey.normalizeEvent(textEvent({ mods: 0, text: "w" }))))
    verify(!TextKey.matches(TextKey.normalizedStep({ mods: 0, text: "w" }),
                            TextKey.normalizeEvent(textEvent({ mods: 4, text: "w" }))))
  }

  // Shift is never compared: it is already inside the character. A capital
  // reached without Shift - a different layout, a lock - still answers.
  function test_shiftIsNotComparedInTextMode() {
    var step = TextKey.normalizedStep({ mods: 0, text: "G" })
    verify(TextKey.matches(step, TextKey.normalizeEvent(
        { key: 0x47, text: "G", modifiers: qtShift, isAutoRepeat: false })))
    verify(TextKey.matches(step, TextKey.normalizeEvent(
        { key: 0x47, text: "G", modifiers: 0, isAutoRepeat: false })))
  }

  function test_textModeRefusesStepsItCannotJudge() {
    compare(TextKey.normalizedStep({ mods: 0, text: "" }), null)
    compare(TextKey.normalizedStep({ mods: 0, named: "NotAKey" }), null)
    compare(TextKey.normalizedStep(null), null)
    compare(TextKey.normalizedStep([]), null)
    // Named spellings of a character become the character.
    compare(TextKey.normalizedStep({ mods: 0, named: "lt" }).text, "<")
    compare(TextKey.normalizedStep({ mods: 0, named: "Bar" }).text, "|")
    // Every spelling of Enter lands on one name.
    compare(TextKey.normalizedStep({ mods: 0, named: "Return" }).named, "CR")
    compare(TextKey.normalizedStep({ mods: 0, named: "enter" }).named, "CR")
  }

  // A sequence advances one step at a time and only answers on the last one.
  function test_sequenceAdvancesStepByStepAndAnswersOnTheLast() {
    var steps = [{ mods: 0, text: "g" }, { mods: 0, text: "c" }, { mods: 0, text: "c" }]
    var answer = textAnswer(steps)
    var state = AnswerMatcher.begin()
    compare(AnswerMatcher.advance(state, answer, textEvent(steps[0])), "progress")
    compare(AnswerMatcher.typedSteps(state), 1)
    compare(AnswerMatcher.advance(state, answer, textEvent(steps[1])), "progress")
    compare(AnswerMatcher.typedSteps(state), 2)
    compare(AnswerMatcher.advance(state, answer, textEvent(steps[2])), "hit")
    compare(AnswerMatcher.typedSteps(state), 0)
  }

  // A wrong key fails the card whole, not the step: correcting a sequence
  // means typing it again from the start.
  function test_aWrongStepFailsTheWholeCard() {
    var answer = textAnswer([{ mods: 0, text: "g" }, { mods: 0, text: "c" }])
    var state = AnswerMatcher.begin()
    compare(AnswerMatcher.advance(state, answer, textEvent({ mods: 0, text: "g" })), "progress")
    compare(AnswerMatcher.advance(state, answer, textEvent({ mods: 0, text: "x" })), "miss")
    compare(AnswerMatcher.typedSteps(state), 0)
    // And the retype starts over rather than resuming mid-sequence.
    compare(AnswerMatcher.advance(state, answer, textEvent({ mods: 0, text: "c" })), "miss")
    compare(AnswerMatcher.advance(state, answer, textEvent({ mods: 0, text: "g" })), "progress")
    compare(AnswerMatcher.advance(state, answer, textEvent({ mods: 0, text: "c" })), "hit")
  }

  // The card asked for `gc`; `gc` answers it. Waiting to see whether a third
  // key turns it into `gcc` would leave every prefix unanswerable.
  function test_aCompletedSequenceAnswersWithoutWaitingForALongerOne() {
    var answer = textAnswer([{ mods: 0, text: "g" }, { mods: 0, text: "c" }])
    var state = AnswerMatcher.begin()
    AnswerMatcher.advance(state, answer, textEvent({ mods: 0, text: "g" }))
    compare(AnswerMatcher.advance(state, answer, textEvent({ mods: 0, text: "c" })), "hit")
    // Which is exactly why the card that follows has to be deaf for a moment.
    verify(AnswerMatcher.overruns(answer))
    verify(!AnswerMatcher.overruns(textAnswer([{ mods: 0, text: "g" }])))
  }

  function test_unsupportedJudgesFailClosedEvenWithTextShapedSteps() {
    var modes = ["keysym", "physical", "logical", "unknown", "TEXT", "", null, undefined]
    var step = { mods: 0, text: "g" }
    var event = textEvent(step)
    event.nativeScanCode = 42
    for (var index = 0; index < modes.length; index++) {
      var answer = { judgeMode: modes[index], steps: [step], alternates: [[step]] }
      var state = { cursors: [1] }
      compare(AnswerMatcher.judgeMode(answer), "")
      compare(AnswerMatcher.normalizeInput(answer, event), null)
      verify(!AnswerMatcher.stepMatches(answer, step, TextKey.normalizeEvent(event)))
      compare(AnswerMatcher.advance(state, answer, event), "miss")
      compare(AnswerMatcher.typedSteps(state), 0)
      compare(AnswerMatcher.stepCount(answer), 0)
      compare(AnswerMatcher.stepLabels(answer).length, 0)
      compare(AnswerMatcher.alternateLabels(answer).length, 0)
      compare(AnswerMatcher.inputDisplay(answer, event), "")
      verify(!AnswerMatcher.overruns(answer))
    }
    compare(AnswerMatcher.advance(AnswerMatcher.begin(), null, event), "miss")
    // Old chord records cannot be revived just by labelling them text.
    var retired = { modMask: 0, key: "G", keycode: 42, matchMode: "physical" }
    compare(AnswerMatcher.advance(AnswerMatcher.begin(), textAnswer([retired]), event), "miss")
  }

  function test_textJudgingNeverReadsPhysicalCodesOrTranslatesSymbols() {
    var event = { key: Qt.Key_Question, text: "?", modifiers: qtShift }
    Object.defineProperty(event, "nativeScanCode", {
      get: function() { throw new Error("physical input path was accessed") }
    })
    var question = textAnswer([{ mods: 0, text: "?" }])
    compare(AnswerMatcher.advance(AnswerMatcher.begin(), question, event), "hit")
    compare(AnswerMatcher.inputDisplay(question, event), "?")
    compare(AnswerMatcher.advance(AnswerMatcher.begin(),
        textAnswer([{ mods: 0, text: "/" }]), event), "miss")
    var input = AnswerMatcher.normalizeInput(question, event)
    verify(!Object.prototype.hasOwnProperty.call(input, "physicalCode"))
    verify(!Object.prototype.hasOwnProperty.call(input, "logicalKey"))

    // Same text from different physical keys still answers; the right scan
    // code with missing or wrong text never answers a character step.
    var lower = textAnswer([{ mods: 0, text: "g" }])
    var codes = [0, 42, 94]
    for (var index = 0; index < codes.length; index++) {
      var pressed = { key: Qt.Key_G, text: "g", modifiers: 0, nativeScanCode: codes[index] }
      compare(AnswerMatcher.advance(AnswerMatcher.begin(), lower, pressed), "hit")
      pressed.text = ""
      compare(AnswerMatcher.advance(AnswerMatcher.begin(), lower, pressed), "miss")
      pressed.text = "G"
      compare(AnswerMatcher.advance(AnswerMatcher.begin(), lower, pressed), "miss")
    }
    // No scan-code-only fallback for the former special-key workaround.
    var tab = textAnswer([{ mods: 0, named: "TAB" }])
    compare(AnswerMatcher.advance(AnswerMatcher.begin(), tab,
        { key: 0x01ffffff, text: "", nativeScanCode: 23 }), "miss")
    compare(AnswerMatcher.advance(AnswerMatcher.begin(), tab,
        { key: Qt.Key_Tab, text: "\t", nativeScanCode: 0 }), "hit")
  }

  // What a delegate is actually handed. A model value reaches one through
  // QML's variant conversion, which leaves an array-like object rather than an
  // Array - and insisting on Array.isArray silently dropped every step, so
  // each row in the set-aside drawer showed a description beside an empty
  // column where its keys belong.
  function test_answersSurviveTheTripThroughAModel() {
    var step = { mods: 4, text: "w" }
    var converted = { judgeMode: "text", context: "normal", steps: { length: 1, 0: step } }
    compare(AnswerMatcher.stepCount(converted), 1)
    compare(AnswerMatcher.stepLabels(converted)[0].join(" + "), "CTRL + w")
    compare(AnswerMatcher.advance(AnswerMatcher.begin(), converted, textEvent(step)), "hit")

    var sequence = {
      judgeMode: "text", context: "normal",
      steps: { length: 2, 0: { mods: 0, text: "[" }, 1: { mods: 0, text: "w" } }
    }
    compare(AnswerMatcher.stepCount(sequence), 2)
    compare(AnswerMatcher.stepLabels(sequence).map(function(keys) {
      return keys.join(" + ")
    }).join(" › "), "[ › w")
    // And it is still judged, not just drawn.
    var state = AnswerMatcher.begin()
    compare(AnswerMatcher.advance(state, sequence, textEvent({ mods: 0, text: "[" })), "progress")
    compare(AnswerMatcher.advance(state, sequence, textEvent({ mods: 0, text: "w" })), "hit")
  }

  // One action, several ways to reach it. herdr's own listing says
  // "PREFIX + H / ALT + ENTER"; Omarchy gives tmux a prefix2 beside its
  // prefix; vim has D for d$. Marking a spelling the application accepts as
  // wrong would be teaching something untrue, so a card takes any of them.
  function test_aCardAcceptsEveryWayIntoTheSameAction() {
    var answer = {
      judgeMode: "text", context: "normal",
      steps: [{ mods: 0, text: "d" }, { mods: 0, text: "$" }],
      alternates: [[{ mods: 0, text: "D" }]]
    }
    compare(AnswerMatcher.stepCount(answer), 2)
    compare(AnswerMatcher.alternateLabels(answer).join(","), "D")

    // The shown answer.
    var state = AnswerMatcher.begin()
    compare(AnswerMatcher.advance(state, answer, textEvent({ mods: 0, text: "d" })), "progress")
    compare(AnswerMatcher.advance(state, answer, textEvent({ mods: 0, text: "$" })), "hit")

    // The other one, from the first key press.
    state = AnswerMatcher.begin()
    compare(AnswerMatcher.advance(state, answer, textEvent({ mods: 0, text: "D" })), "hit")

    // And something neither accepts is still wrong.
    state = AnswerMatcher.begin()
    compare(AnswerMatcher.advance(state, answer, textEvent({ mods: 0, text: "x" })), "miss")

    // A candidate that diverges partway drops out without taking the other
    // with it: "d" starts the shown answer, "w" is in neither.
    state = AnswerMatcher.begin()
    compare(AnswerMatcher.advance(state, answer, textEvent({ mods: 0, text: "d" })), "progress")
    compare(AnswerMatcher.advance(state, answer, textEvent({ mods: 0, text: "w" })), "miss")
  }

  function test_alternatesSurviveQmlArrayLikeConversion() {
    var alternate = ({ length: 1, 0: { mods: 0, text: "D" } })
    var answer = {
      judgeMode: "text", context: "normal",
      steps: [{ mods: 0, text: "d" }, { mods: 0, text: "$" }],
      alternates: ({ length: 1, 0: alternate })
    }
    compare(AnswerMatcher.alternateLabels(answer).join(","), "D")
    compare(AnswerMatcher.advance(AnswerMatcher.begin(), answer,
                                  textEvent({ mods: 0, text: "D" })), "hit")
  }

  function test_answersAreBoundedInSteps() {
    var steps = []
    for (var index = 0; index < 20; index++) steps.push({ mods: 0, text: "a" })
    compare(AnswerMatcher.stepCount(textAnswer(steps)), 8)
    compare(AnswerMatcher.stepCount({ steps: [] }), 0)
    compare(AnswerMatcher.stepCount(null), 0)
    var state = AnswerMatcher.begin()
    compare(AnswerMatcher.advance(state, { steps: [] }, textEvent({ mods: 0, text: "a" })), "miss")
  }

  // A longer answer takes longer to type. The clamps were chosen for one
  // chord, so the extra per step is added outside them.
  function test_cardTimeGrowsWithTheStepCount() {
    var stats = Stats.defaults()
    var one = binding({ key: "3", arg: "3", description: "Switch to workspace 3" })
    one.id = "lazyvim/one"
    one.answer = textAnswer([{ mods: 0, text: "g" }])
    var three = binding({ key: "4", arg: "4", description: "Switch to workspace 4" })
    three.id = "lazyvim/three"
    three.answer = textAnswer([{ mods: 0, text: "g" }, { mods: 0, text: "c" }, { mods: 0, text: "c" }])

    var learningOne = { binding: one, tier: "learning", queue: "due", remedial: false }
    var learningThree = { binding: three, tier: "learning", queue: "due", remedial: false }
    compare(Scheduler.durationFor(learningOne, stats), 4500)
    compare(Scheduler.durationFor(learningThree, stats), 4500 + 1600)

    var maintenanceOne = { binding: one, tier: "maintenance", queue: "maintenance", remedial: false }
    var maintenanceThree = { binding: three, tier: "maintenance", queue: "maintenance", remedial: false }
    compare(Scheduler.durationFor(maintenanceOne, stats), 3600)
    compare(Scheduler.durationFor(maintenanceThree, stats), 3600 + 1200)

    // A guided card is still untimed however long its answer is.
    compare(Scheduler.durationFor({ binding: three, tier: "guided", queue: "unseen" }, stats), 0)
  }

  // --- packs: the compiled-in table of an application-level ground ---

  PackSource { id: testPack; profileId: "lazyvim" }

  function test_theShippedPackLoadsWithinItsLimits() {
    testPack.options = ({ leader: " " })
    testPack.refresh()
    compare(testPack.error, "")
    verify(testPack.bindings.length > 100)
    compare(testPack.rejected, 0)
    verify(testPack.sourceLabel.length > 0)

    var seen = ({})
    for (var index = 0; index < testPack.bindings.length; index++) {
      var item = testPack.bindings[index]
      compare(Profiles.profileOf(item.id), "lazyvim")
      compare(item.id, "lazyvim/" + item.localId)
      verify(item.actionName.length > 0)
      verify(!seen[item.id])
      seen[item.id] = true
      var steps = AnswerMatcher.stepCount(item.answer)
      verify(steps >= 1 && steps <= 8)
      compare(AnswerMatcher.judgeMode(item.answer), "text")
      verify(["normal", "visual", "insert", "operator"].indexOf(item.answer.context) !== -1)
    }
  }

  // Leader is configuration in the application being trained, so a pack stores a
  // placeholder. Someone who moved theirs trains the mapping, not a key they
  // never press.
  // LazyVim's leader, tmux's prefix and herdr's prefix are one idea: a
  // configurable key every other binding hangs off. One parser reads all
  // three, in the spellings a person actually writes.
  function test_aConfigurablePrefixIsReadInEverySpellingPeopleUse() {
    compare(TextKey.parseKeySpec(" ").named, "SPACE")
    compare(TextKey.parseKeySpec(",").text, ",")
    compare(TextKey.parseKeySpec("<Space>").named, "SPACE")
    compare(TextKey.parseKeySpec("Space").named, "SPACE")

    var control = TextKey.parseKeySpec("C-b")
    compare(control.mods, 4)
    compare(control.text, "b")
    compare(TextKey.parseKeySpec("ctrl+a").mods, 4)
    compare(TextKey.parseKeySpec("ctrl+a").text, "a")
    compare(TextKey.parseKeySpec("CTRL+A").text, "a")
    compare(TextKey.parseKeySpec("C-Space").named, "SPACE")
    compare(TextKey.parseKeySpec("ctrl+space").mods, 4)
    compare(TextKey.parseKeySpec("M-x").mods, 8)
    compare(TextKey.parseKeySpec("alt+x").mods, 8)

    // Unreadable ones return null, and the caller keeps its default.
    compare(TextKey.parseKeySpec(""), null)
    compare(TextKey.parseKeySpec("C-"), null)
    compare(TextKey.parseKeySpec("NotAKey"), null)
    compare(TextKey.parseKeySpec("ctrl+notakey"), null)
  }

  // "S-" is Shift in Vim's notation, in tmux's, and in every collector on the
  // Python side. It meant Super in this parser alone, so a prefix a machine
  // had set to Shift would have been taught as Super.
  function test_shiftIsShiftOnBothSidesOfTheHelperBoundary() {
    compare(TextKey.parseKeySpec("S-x").text, "X")
    compare(TextKey.parseKeySpec("S-x").mods, 0)
    compare(TextKey.parseKeySpec("shift+x").text, "X")
    // A named key has no character for Shift to fold into, so there it stays
    // a modifier - and Tab is refused, because Qt cannot tell it from Backtab.
    compare(TextKey.parseKeySpec("S-Up").mods, 1)
    compare(TextKey.parseKeySpec("S-Tab"), null)
    // Nothing shifts "1" into another key on every layout, so it is refused
    // rather than guessed at.
    compare(TextKey.parseKeySpec("S-1"), null)
    // Super still has spellings of its own.
    compare(TextKey.parseKeySpec("SUPER+k").mods, 64)
    compare(TextKey.parseKeySpec("cmd+k").mods, 64)
    compare(TextKey.parseKeySpec("C-S-x").mods, 4)
    compare(TextKey.parseKeySpec("C-S-x").text, "X")
  }

  // Vim reads the name inside <> without regard to case; the characters
  // outside it are decisive. A config written <Leader>ff used to add a second
  // card beside the packaged <leader>ff instead of replacing its description.
  function test_aLeftHandSideMeetsThePackWhateverCaseItsBracketsUse() {
    compare(TextKey.canonicalNotation("normal/<Leader>ff"), "normal/<leader>ff")
    compare(TextKey.canonicalNotation("normal/<C-X>"), "normal/<c-x>")
    // Outside the brackets nothing moves: these are two different mappings.
    compare(TextKey.canonicalNotation("normal/<leader>fF"), "normal/<leader>fF")

    testPack.profileId = "lazyvim"
    testPack.options = ({ leader: " " })
    testPack.overrides = [{ op: "set", lhs: "<Leader>ff", desc: "Mine",
                            contexts: ["normal"] }]
    testPack.refresh()
    var matched = 0
    for (var index = 0; index < testPack.bindings.length; index++) {
      if (TextKey.canonicalNotation(testPack.bindings[index].localId)
          === "normal/<leader>ff") matched += 1
    }
    compare(matched, 1)
    compare(testPack.customAdded, 0)
    compare(testPack.customChanged, 1)
    testPack.overrides = []
    testPack.refresh()
  }

  function test_detectedLeaderOptionsRemainBoundedAndDeclared() {
    var defaults = Profiles.resolvedOptions("lazyvim", null)
    compare(defaults.leader, " ")
    compare(defaults.localleader, "\\")
    var custom = Profiles.resolvedOptions("lazyvim", { leader: ",", localleader: "-" })
    compare(custom.leader, ",")
    compare(custom.localleader, "-")
    var invalid = Profiles.resolvedOptions("lazyvim", { leader: "F13", localleader: "x".repeat(33) })
    compare(invalid.leader, " ")
    compare(invalid.localleader, "\\")
    var hostile = JSON.parse('{"leader":",","prefix":"C-a","__proto__":{},"constructor":"x","prototype":"x"}')
    var resolved = Profiles.resolvedOptions("lazyvim", hostile)
    compare(Object.getPrototypeOf(resolved), null)
    compare(Object.keys(resolved).join(","), "leader,localleader")
    compare(resolved.leader, ",")
    compare(Object.keys(Profiles.resolvedOptions("tmux", hostile)).length, 0)
  }

  // A bundle LazyVim ships but does not enable is real on a machine that
  // turned it on and absent on one that did not, so what a table carries and
  // what it deals are two different things.
  function test_onlyTheBundlesAMachineTurnedOnAreDealt() {
    testPack.profileId = "lazyvim"
    testPack.options = ({ leader: " " })

    testPack.enabledExtras = []
    testPack.refresh()
    var core = testPack.bindings.length
    verify(core > 100)
    verify(testPack.disabledCount > 100, "a table with no bundles on deals only its core")
    for (var index = 0; index < testPack.bindings.length; index++)
      compare(testPack.bindings[index].extras.length, 0)

    // Turning one on deals exactly what it provides, and nothing else.
    testPack.enabledExtras = ["lazyvim.plugins.extras.dap.core"]
    testPack.refresh()
    verify(testPack.bindings.length > core)
    var added = []
    for (var second = 0; second < testPack.bindings.length; second++) {
      var item = testPack.bindings[second]
      if (item.extras.length) added.push(item)
    }
    verify(added.length > 10)
    for (var third = 0; third < added.length; third++)
      verify(added[third].extras.indexOf("lazyvim.plugins.extras.dap.core") !== -1,
             added[third].localId + " came from a bundle that is not on")

    // And an entry the core provides is dealt whatever is enabled.
    testPack.enabledExtras = []
    testPack.refresh()
    compare(testPack.bindings.length, core)
  }

  function test_literalMachineMappingsCalibrateTheLazyVimPack() {
    testPack.profileId = "lazyvim"
    testPack.options = ({ leader: " ", localleader: "\\" })
    testPack.enabledExtras = []
    testPack.overrides = [
      { op: "set", contexts: ["normal"], lhs: "<leader>ff", desc: "My file picker" },
      { op: "del", contexts: ["normal"], lhs: "<C-h>", desc: "" },
      { op: "set", contexts: ["normal"], lhs: "gZ", desc: "My command" }
    ]
    testPack.refresh()
    var changed = null
    var added = null
    var removed = null
    for (var index = 0; index < testPack.bindings.length; index++) {
      var item = testPack.bindings[index]
      if (item.localId === "normal/<leader>ff") changed = item
      if (item.localId === "normal/gZ") added = item
      if (item.localId === "normal/<C-h>") removed = item
    }
    verify(changed !== null)
    compare(changed.actionName, "My file picker")
    compare(changed.customKind, "changed")
    verify(added !== null)
    compare(added.customKind, "added")
    compare(AnswerMatcher.stepCount(added.answer), 2)
    compare(typeAll(added.answer, [{ text: "g" }, { text: "Z" }]).verdict, "hit")
    compare(typeAll(added.answer, [{ text: "g" }, { text: "z" }]).verdict, "miss")
    compare(typeAll(changed.answer, [{ named: "SPACE" }, { text: "f" }, { text: "f" }]).verdict, "hit")
    compare(removed, null)
    compare(testPack.customAdded, 1)
    compare(testPack.customChanged, 1)
    compare(testPack.customDeleted, 1)
    compare(testPack.customSkipped, 0)

    // Source order defines the final result. Repeated operations count the
    // effective diff, not each intermediate write.
    testPack.overrides = [
      { op: "del", contexts: ["normal"], lhs: "<leader>ff", desc: "" },
      { op: "set", contexts: ["normal"], lhs: "<leader>ff", desc: "Final picker" },
      { op: "set", contexts: ["normal"], lhs: "gZ", desc: "Temporary" },
      { op: "del", contexts: ["normal"], lhs: "gZ", desc: "" },
      { op: "set", contexts: ["normal"], lhs: "<Plug>(mine)", desc: "Unreadable" }
    ]
    testPack.refresh()
    compare(testPack.customAdded, 0)
    compare(testPack.customChanged, 1)
    compare(testPack.customDeleted, 0)
    compare(testPack.customSkipped, 1)
    testPack.overrides = []
    testPack.refresh()
  }

  // The table declares every bundle it carries keys for, so the runtime has
  // something to match a machine's own list against.
  function test_thePackDeclaresTheBundlesItCarries() {
    var pack = Packs.pack("lazyvim")
    verify(pack.extras.length > 10)
    var declared = ({})
    for (var index = 0; index < pack.extras.length; index++) {
      verify(pack.extras[index].indexOf("lazyvim.plugins.extras.") === 0, pack.extras[index])
      declared[pack.extras[index]] = true
    }
    for (var entry = 0; entry < pack.bindings.length; entry++) {
      var providers = pack.bindings[entry].extras
      for (var name = 0; name < providers.length; name++)
        verify(declared[providers[name]], providers[name] + " is used but not declared")
    }
  }

  function test_theLeaderIsResolvedFromDetectedConfigNotBakedIntoThePack() {
    testPack.options = ({ leader: " " })
    testPack.refresh()
    var spaced = null
    for (var index = 0; index < testPack.bindings.length; index++) {
      if (testPack.bindings[index].localId === "normal/<leader>ff") spaced = testPack.bindings[index]
    }
    verify(spaced !== null)
    compare(spaced.answer.steps[0].named, "SPACE")
    compare(typeAll(spaced.answer, [{ named: "SPACE" }, { text: "f" }, { text: "f" }]).verdict, "hit")

    testPack.options = ({ leader: "," })
    testPack.refresh()
    var comma = null
    for (var second = 0; second < testPack.bindings.length; second++) {
      if (testPack.bindings[second].localId === "normal/<leader>ff") comma = testPack.bindings[second]
    }
    verify(comma !== null)
    compare(comma.answer.steps[0].text, ",")
    compare(typeAll(comma.answer, [{ text: "," }, { text: "f" }, { text: "f" }]).verdict, "hit")
    compare(AnswerMatcher.advance(AnswerMatcher.begin(), comma.answer,
        textEvent({ named: "SPACE" })), "miss")
    // The entry keeps its identity across the change, so progress survives it.
    compare(comma.id, spaced.id)
    testPack.options = ({ leader: " " })
    testPack.refresh()
  }

  function test_leaderFindSequenceHoldsPrefixThenHitsOrSchedulesRemedial() {
    testPack.options = Profiles.resolvedOptions("lazyvim", { leader: " " })
    testPack.refresh()
    var card = testPack.bindings.find(function(item) { return item.localId === "normal/<leader>ff" })
    verify(card !== undefined)
    compare(AnswerMatcher.stepCount(card.answer), 3)
    var stats = Stats.defaults()
    Stats.recordGuided(stats, card.id, 1, 100)
    var before = JSON.stringify(stats)
    var state = AnswerMatcher.begin()
    compare(AnswerMatcher.advance(state, card.answer, textEvent({ named: "SPACE" })), "progress")
    compare(AnswerMatcher.advance(state, card.answer, textEvent({ text: "f" })), "progress")
    compare(AnswerMatcher.typedSteps(state), 2)
    // A held prefix yields neither a hit nor a miss; callers must not record
    // a first try or a lapse until a terminal verdict (Keycade.handleGameInput).
    compare(JSON.stringify(stats), before)
    var hit = AnswerMatcher.advance(state, card.answer, textEvent({ text: "f" }))
    compare(hit, "hit")
    Stats.recordFirstTry(stats, card.id, hit === "hit", 600, 1, 700)
    compare(stats.bindings[card.id].firstTryAttempts, 1)
    compare(stats.bindings[card.id].firstTryCorrect, 1)
    compare(stats.bindings[card.id].lapseCount, 0)
    compare(AnswerMatcher.typedSteps(state), 0)

    compare(AnswerMatcher.advance(state, card.answer, textEvent({ named: "SPACE" })), "progress")
    var miss = AnswerMatcher.advance(state, card.answer, textEvent({ text: "x" }))
    compare(miss, "miss")
    compare(AnswerMatcher.typedSteps(state), 0)
    // The terminal miss feeds the existing first-try/remedial seam; the
    // scheduler still spaces the retest three to five other cards away.
    Stats.recordFirstTry(stats, card.id, miss === "hit", -1, 2, 800)
    var run = Scheduler.build(testPack.bindings, stats, 24, { now: 800, runId: 2 })
    run[0] = { binding: card, tier: "learning", queue: "due", remedial: false }
    var remedial = Scheduler.insertRemedial(run, 0, card)
    compare(stats.bindings[card.id].firstTryAttempts, 2)
    compare(stats.bindings[card.id].firstTryCorrect, 1)
    compare(stats.bindings[card.id].lapseCount, 1)
    var retest = remedial.findIndex(function(item) { return item.remedial && item.binding.id === card.id })
    verify(retest >= 4 && retest <= 6)
    // A correction must retype the leader; completing only the old suffix
    // cannot answer after the miss.
    compare(AnswerMatcher.advance(state, card.answer, textEvent({ text: "f" })), "miss")
    compare(typeAll(card.answer, [{ named: "SPACE" }, { text: "f" }, { text: "f" }]).verdict, "hit")
  }

  function test_customLocalleaderUsesTheSameTextSequencePath() {
    testPack.options = Profiles.resolvedOptions("lazyvim", { leader: ",", localleader: "-" })
    testPack.overrides = [{ op: "set", lhs: "<localleader>u", desc: "My local command", contexts: ["normal"] }]
    testPack.refresh()
    var custom = testPack.bindings.find(function(item) { return item.localId === "normal/<localleader>u" })
    verify(custom !== undefined)
    compare(custom.customKind, "added")
    compare(custom.category, "misc")
    compare(typeAll(custom.answer, [{ text: "-" }, { text: "u" }]).verdict, "hit")
    var state = AnswerMatcher.begin()
    compare(AnswerMatcher.advance(state, custom.answer, textEvent({ text: "-" })), "progress")
    compare(AnswerMatcher.advance(state, custom.answer, textEvent({ text: "U" })), "miss")
    testPack.options = Profiles.resolvedOptions("lazyvim", null)
    testPack.overrides = []
    testPack.refresh()
  }

  // The generator bounded the table. This side bounds it again, because
  // "the generator checked it" is not something this side can verify.
  function test_thePackSourceRefusesWhatItCannotJudge() {
    var categories = ["find"]
    compare(testPack.acceptedBinding(null, categories), null)
    compare(testPack.acceptedBinding({ localId: "", desc: "x", category: "find",
                                       context: "normal", steps: [{ text: "f" }] }, categories), null)
    compare(testPack.acceptedBinding({ localId: "a", desc: "", category: "find",
                                       context: "normal", steps: [{ text: "f" }] }, categories), null)
    compare(testPack.acceptedBinding({ localId: "a", desc: "x", category: "nope",
                                       context: "normal", steps: [{ text: "f" }] }, categories), null)
    compare(testPack.acceptedBinding({ localId: "a", desc: "x", category: "find",
                                       context: "command", steps: [{ text: "f" }] }, categories), null)
    compare(testPack.acceptedBinding({ localId: "a", desc: "x", category: "find",
                                       context: "normal", steps: [] }, categories), null)
    // An answer with one unreadable step is not a partially good answer.
    compare(testPack.acceptedBinding({ localId: "a", desc: "x", category: "find", context: "normal",
                                       steps: [{ text: "f" }, { named: "NotAKey" }] }, categories), null)
    // Esc saves the run and leaves, on every ground.
    compare(testPack.acceptedBinding({ localId: "a", desc: "x", category: "find", context: "normal",
                                       steps: [{ named: "Esc" }] }, categories), null)
    var tooMany = []
    for (var index = 0; index < 9; index++) tooMany.push({ text: "a" })
    compare(testPack.acceptedBinding({ localId: "a", desc: "x", category: "find",
                                       context: "normal", steps: tooMany }, categories), null)
    // And what it does accept comes back fully formed.
    var good = testPack.acceptedBinding({ localId: "normal/x", desc: "Find", category: "find",
                                          context: "normal", steps: [{ mods: 0, text: "f" }] }, categories)
    compare(good.id, "lazyvim/normal/x")
    compare(good.actionName, "Find")
    compare(AnswerMatcher.stepCount(good.answer), 1)
  }

  function test_externalPackEnvelopesAreBoundedBeforeRetention() {
    compare(testPack.acceptedCategories(["find", "git"]).join(","), "find,git")
    compare(testPack.acceptedCategories(["find", "find"]), null)
    compare(testPack.acceptedCategories(["__proto__"]), null)
    var tooManyCategories = []
    for (var category = 0; category < 33; category++) tooManyCategories.push("c" + category)
    compare(testPack.acceptedCategories(tooManyCategories), null)

    var tooManyExtras = []
    for (var extra = 0; extra < 129; extra++) tooManyExtras.push("extra." + extra)
    compare(testPack.acceptedBinding({
      localId: "normal/x", desc: "Find", category: "find", context: "normal",
      steps: [{ text: "x" }], extras: tooManyExtras
    }, ["find"]), null)
    var tooManyAlternates = []
    for (var other = 0; other < 5; other++) tooManyAlternates.push([{ text: "x" }])
    compare(testPack.acceptedBinding({
      localId: "normal/x", desc: "Find", category: "find", context: "normal",
      steps: [{ text: "x" }], alternates: tooManyAlternates
    }, ["find"]), null)
  }

  function test_schedulerCountsPrototypeNamedExternalIds() {
    var deck = [
      { binding: { id: "__proto__" }, tier: "guided", queue: "unseen" },
      { binding: { id: "constructor" }, tier: "guided", queue: "unseen" },
      { binding: { id: "prototype" }, tier: "learning", queue: "due" }
    ]
    var counts = Scheduler.planCounts(deck)
    compare(counts.added, 2)
    compare(counts.review, 1)
    compare(({}).polluted, undefined)
  }

  // Dynamic keys from a helper or a pack must not land on a normal {}.
  function test_packMapsRejectPrototypeKeys() {
    var originalConstructor = Object.prototype.constructor
    testPack.profileId = "lazyvim"
    testPack.options = ({ leader: " " })
    testPack.enabledExtras = []
    var hostilePack = {
      schemaVersion: 1,
      profile: "lazyvim",
      judgeMode: "text",
      categories: ["misc"],
      bindings: [
        { localId: "normal/g", context: "normal", category: "misc",
          desc: "Safe", steps: [{ text: "g" }] },
        { localId: "__proto__", context: "normal", category: "misc",
          desc: "Evil", steps: [{ text: "x" }] },
        { localId: "constructor", context: "normal", category: "misc",
          desc: "Ctor", steps: [{ text: "c" }] }
      ]
    }
    testPack.overrides = [
      { op: "set", contexts: ["normal"], lhs: "g", desc: "Mine" },
      { op: "set", contexts: ["normal"], lhs: "__proto__", desc: "Nope" }
    ]
    // No live table override survives. Exercise the same merge and consumer
    // validation directly with hostile records before refreshing the real pack.
    var records = testPack.mergedBindings(hostilePack)
    var foundSafe = false
    var refused = 0
    for (var index = 0; index < records.length; index++) {
      var item = testPack.acceptedBinding(records[index], hostilePack.categories)
      if (!item) { refused += 1; continue }
      verify(item.localId !== "__proto__" && item.localId !== "constructor")
      if (item.localId === "normal/g") {
        foundSafe = true
        compare(item.actionName, "Mine")
        compare(item.customKind, "changed")
      }
    }
    compare(foundSafe, true)
    compare(refused, 2)
    testPack.refresh()
    compare(testPack.error, "")
    compare(Object.prototype.constructor, originalConstructor)
    compare(({}).pwned, undefined)
    testPack.overrides = []
    testPack.refresh()
  }

  // Setting an entry aside is one mechanism across every ground: an entry in
  // settings.json, namespaced by ground, naming the local id.
  function test_packEntriesAreSetAsideThroughTheSameExclusionList() {
    var bindings = [
      { id: "lazyvim/normal/a", localId: "normal/a", category: "find", actionName: "A" },
      { id: "lazyvim/normal/b", localId: "normal/b", category: "git", actionName: "B" }
    ]
    var result = PackEligibility.filter(bindings, {
      profile: "lazyvim",
      excludedBindings: ["lazyvim:normal/b"]
    })
    compare(result.eligible.length, 1)
    compare(result.eligible[0].localId, "normal/a")
    compare(result.excluded.length, 1)
    compare(result.excluded[0].reason, "user-excluded")
    // The Hyprland ground's own list is not consumed here.
    compare(PackEligibility.filter(bindings, {
      profile: "lazyvim", excludedBindings: ["hyprland:normal/b"]
    }).eligible.length, 2)
    compare(PackEligibility.categories(bindings).join(","), "find,git")
  }

  // A run on a pack ground, end to end: the deck comes from the pack, the
  // scheduler keys on qualified ids, the counters land in that ground's own
  // record, and the answers are typed rather than held.
  // Each pack declares the contexts and categories of its own ground, and the
  // registry has to agree with it: the loader validates against the registry
  // while the pack is what the table was actually built to.
  function test_everyPackAgreesWithTheRegistryAboutItsContexts() {
    var ids = Packs.ids()
    compare(ids.join(","), "lazyvim")
    for (var index = 0; index < ids.length; index++) {
      var id = ids[index]
      verify(Profiles.isPack(id), id + " ships a pack but is not registered")
      var pack = Packs.pack(id)
      verify(pack !== null)
      compare(pack.profile, id)
      // The registry says what the ground can pose; the pack says what its
      // table actually holds. A pack context outside the registry would be
      // dropped by the loader without a word, so it is the subset that has
      // to hold.
      var allowed = Profiles.contexts(id)
      verify(allowed.length > 0, id)
      for (var context = 0; context < pack.contexts.length; context++)
        verify(allowed.indexOf(pack.contexts[context]) !== -1,
               id + " ships context " + pack.contexts[context] + " its ground does not pose")
      verify(pack.categories.length > 0, id)
    }
    // Retired supplies cannot be loaded, even while the old profile registry
    // is awaiting its separate teardown.
    var retired = ["hyprland", "herdr", "tmux", "vim", "neovim"]
    for (var old = 0; old < retired.length; old++)
      compare(Packs.pack(retired[old]), null)
  }

  // A pack ships the upstream's English; the language packs answer it. The
  // description is the prompt a card asks the keys for, so it has to be
  // readable in the language the rest of the screen is in.
  function test_packDescriptionsAreReadableInBothLanguages() {
    testPack.options = ({ leader: " " })
    testPack.refresh()
    var sample = null
    for (var index = 0; index < testPack.bindings.length; index++) {
      if (testPack.bindings[index].localId === "normal/<C-h>") sample = testPack.bindings[index]
    }
    verify(sample !== null)
    // The ground is in the key: LazyVim's "Next" and Neovim's ":next" slug the
    // same way, and a shared key meant one translation replaced the other.
    compare(sample.descKey, "packdesc_lazyvim_go_to_left_window")
    compare(sample.actionName, "Go to Left Window")

    testI18n.locale = "en"
    compare(testI18n.t(sample.descKey), "Go to Left Window")
    testI18n.locale = "zh-CN"
    compare(testI18n.t(sample.descKey), "切换到左侧窗口")

    // Every entry the pack ships is answered in both languages.
    for (var second = 0; second < testPack.bindings.length; second++) {
      var key = testPack.bindings[second].descKey
      verify(key.length > 0, testPack.bindings[second].localId + " carries no description key")
      verify(testI18n.messages[key] !== undefined, key + " has no Chinese")
    }

    // Wording upstream has rewritten answers to no key, so the card keeps the
    // English rather than showing a translation of the old wording.
    compare(testI18n.messages["packdesc_a_description_nobody_wrote"], undefined)
    testI18n.locale = "en"
  }

  // The drawer lists what you set aside, including its answer keys.
  function test_setAsideRowsStillCarryTheirKeys() {
    testPack.options = ({ leader: " " })
    testPack.refresh()
    var packResult = PackEligibility.filter(testPack.bindings, {
      profile: "lazyvim",
      excludedBindings: ["lazyvim:normal/<C-h>"]
    })
    compare(packResult.excluded.length, 1)
    var packRow = packResult.excluded[0].binding
    verify(packRow.answer !== undefined, "a set-aside pack entry carries no answer")
    compare(AnswerMatcher.stepLabels(packRow.answer)[0].join(" + "), "CTRL + h")

    // A sequence has to read as a sequence in a list too. Joining its steps
    // with spaces made "[w" look like one unreadable token rather than two
    // keys typed one after the other.
    var sequence = null
    for (var index = 0; index < testPack.bindings.length; index++) {
      if (testPack.bindings[index].localId === "normal/[w") sequence = testPack.bindings[index]
    }
    verify(sequence !== null)
    var steps = AnswerMatcher.stepLabels(sequence.answer)
    compare(steps.length, 2)
    compare(steps.map(function(keys) { return keys.join(" + ") }).join(" › "), "[ › w")
  }

  function test_aRunOnAPackGroundGoesThroughTheSameMachinery() {
    testPack.options = ({ leader: " " })
    testPack.refresh()
    var stats = Stats.defaults()
    var deck = Scheduler.build(testPack.bindings, stats, 24,
                               { now: 1000, runId: 1, deckId: "all" })
    compare(deck.length, 24)
    for (var index = 0; index < deck.length; index++)
      compare(Profiles.profileOf(deck[index].binding.id), "lazyvim")

    // Typing the first card's answer answers it, one step at a time.
    var answer = deck[0].binding.answer
    var state = AnswerMatcher.begin()
    var verdict = ""
    for (var step = 0; step < answer.steps.length; step++)
      verdict = AnswerMatcher.advance(state, answer, textEvent(answer.steps[step]))
    compare(verdict, "hit")

    Stats.recordGuided(stats, deck[0].binding.id, 1, 1000)
    Stats.recordFirstTry(stats, deck[0].binding.id, true, 900, 1, 2000)
    Scheduler.markCovered(testPack.bindings, stats, deck[0].binding.id, "all")
    Stats.completeRun(stats, "all")

    // The retired ground's counters are untouched by any of it.
    compare(Stats.runsOf(stats, "all"), 1)
    compare(Stats.runsOf(stats, "hyprland"), 0)
    verify(Stats.counters(stats, "all").coverageCursor !== 0)
    compare(Stats.counters(stats, "hyprland").coverageCursor, 0)
    compare(Object.keys(stats.bindings)[0].slice(0, 8), "lazyvim/")
  }

  // Every palette has to stay readable on the surfaces it is actually drawn
  // on. The drawer lists set-aside shortcuts as ink on the cabinet with their
  // descriptions in the muted tone, and two palettes had that tone sitting
  // just under the line.
  // The palette holds hex strings, which is what the QML colour properties are
  // assigned from; parse them here rather than relying on a colour type.
  function relativeLuminance(hex) {
    var text = String(hex).replace("#", "")
    var parts = []
    for (var index = 0; index < 3; index++) {
      var value = parseInt(text.substr(index * 2, 2), 16) / 255
      parts.push(value <= 0.03928 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4))
    }
    return 0.2126 * parts[0] + 0.7152 * parts[1] + 0.0722 * parts[2]
  }

  function contrastRatio(left, right) {
    var a = relativeLuminance(left)
    var b = relativeLuminance(right)
    return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05)
  }

  function test_everyPaletteKeepsItsTextReadableOnTheCabinet() {
    var names = Palettes.names()
    verify(names.length >= 5)
    for (var index = 0; index < names.length; index++) {
      var palette = Palettes.palette(names[index])
      var ink = contrastRatio(palette.inkColor, palette.cabinetColor)
      var muted = contrastRatio(palette.mutedColor, palette.cabinetColor)
      verify(ink >= 4.5, names[index] + " ink on cabinet is " + ink.toFixed(2))
      verify(muted >= 4.5, names[index] + " muted on cabinet is " + muted.toFixed(2))
      // The screen is the other surface text lands on.
      verify(contrastRatio(palette.inkColor, palette.screenColor) >= 4.5, names[index])
      verify(contrastRatio(palette.mutedColor, palette.screenColor) >= 4.5, names[index])
    }
  }

}
