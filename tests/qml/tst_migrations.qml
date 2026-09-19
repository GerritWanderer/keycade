import QtQuick
import QtTest
import "../../lib/Stats.js" as Stats
import "../../lib/DeckState.js" as DeckState

TestCase {
  name: "StateMigrations"

  function rejected(callback, reason) {
    var caught = false
    try { callback() } catch (error) { caught = true; if (reason) compare(error.message, reason) }
    verify(caught)
  }

  function test_equalDeckLocalRunNumbersUseDistinctSharedCardSuccesses() {
    var stats = Stats.defaults()
    var id = "lazyvim/normal/shared"
    compare(Stats.runsOf(stats, "lsp") + 1, 1)
    var first = Stats.allocateRunIdentity(stats)
    Stats.recordGuided(stats, id, first, 100)
    Stats.recordFirstTry(stats, id, true, 500, first, 200)
    verify(!Stats.recordFirstTry(stats, id, true, 400, first, 250).masteredGained)
    compare(stats.bindings[id].successfulRuns.join(","), String(first))
    compare(stats.bindings[id].dueRun, first + 1)
    Stats.completeRun(stats, "lsp")

    compare(Stats.runsOf(stats, "git") + 1, 1)
    var second = Stats.allocateRunIdentity(stats)
    verify(second > first)
    verify(Stats.isDue(stats.bindings[id], 300, second))
    verify(Stats.recordFirstTry(stats, id, true, 300, second, 400).masteredGained)
    compare(stats.bindings[id].successfulRuns.join(","), first + "," + second)
    compare(Stats.counts(stats, [{id: id}], 400, second).mastered, 1)
    Stats.noteFirstMastery(stats, "git", 500, Stats.runsOf(stats, "git") + 1)
    Stats.completeRun(stats, "git")
    compare(stats.decks.lsp.runs, 1)
    compare(stats.decks.git.runs, 1)
    compare(stats.decks.git.firstMasteryRun, 1) // not global identity 2
  }

  function test_dueRunAdvancesAcrossUnrelatedDeckSessions() {
    var stats = Stats.defaults()
    var first = Stats.allocateRunIdentity(stats)
    var id = "lazyvim/normal/shared"
    Stats.recordGuided(stats, id, first, 100)
    Stats.recordFirstTry(stats, id, true, 500, first, 200)
    verify(!Stats.isDue(stats.bindings[id], 300, first))
    var unrelated = Stats.allocateRunIdentity(stats)
    Stats.completeRun(stats, "other")
    verify(Stats.isDue(stats.bindings[id], 300, unrelated))
    var third = Stats.allocateRunIdentity(stats)
    compare(Stats.runsOf(stats, "new-deck"), 0)
    verify(Stats.isDue(stats.bindings[id], 300, third))
    verify(Stats.recordFirstTry(stats, id, true, 300, third, 400).masteredGained)
    compare(stats.bindings[id].successfulRuns.join(","), "1,3")
  }

  function test_resumeReusesIdentityButAbandonAndRestartNeverDo() {
    var stats = Stats.defaults()
    compare(Stats.peekRunIdentity(stats), 1)
    compare(stats.runSequence, 0) // preview is read-only
    var first = Stats.allocateRunIdentity(stats)
    compare(Stats.adoptRunIdentity(stats, first), first)
    compare(Stats.adoptRunIdentity(stats, first), first)
    compare(stats.runSequence, first)
    var next = Stats.allocateRunIdentity(stats) // abandon first without completing
    compare(next, first + 1)
    compare(Object.keys(stats.decks).length, 0)
    stats = Stats.migrate(stats, ["all"])
    compare(Stats.adoptRunIdentity(stats, next), next)
    compare(Stats.allocateRunIdentity(stats), next + 1)
  }

  function test_initialHighWaterIsLazyvimOnlyAndOrdinarySavesDoNotAllocate() {
    var lazy = Stats.freshEntry()
    lazy.state = "mastered"
    lazy.lastSuccessfulRun = 11
    lazy.successfulRuns = [10, 11]
    lazy.dueRun = 15
    var foreign = Stats.freshEntry()
    foreign.lastSuccessfulRun = Stats.MAX_COUNTER
    foreign.successfulRuns = [Stats.MAX_COUNTER]
    foreign.dueRun = Stats.MAX_COUNTER
    var input = {schemaVersion: 4, profiles: {lazyvim: {runs: 7}, tmux: {runs: Stats.MAX_COUNTER}},
                 bindings: {"lazyvim/shared": lazy, "tmux/foreign": foreign}}
    var before = JSON.stringify(input.bindings)
    var stats = Stats.migrate(input, ["all"])
    compare(stats.runSequence, 15)
    compare(JSON.stringify(stats.bindings), before)
    compare(Stats.allocateRunIdentity(stats), 16)
    stats.bindings["lazyvim/shared"].dueRun = 999
    stats.decks.all.runs = 800
    stats.decks.all.firstMasteryRun = 700
    var saved = Stats.migrate(stats, ["all"])
    compare(saved.runSequence, 16)
    compare(JSON.stringify(Stats.migrate(saved, ["all"])), JSON.stringify(saved))
    // Real successful identity evidence protects an understated sequence.
    saved.bindings["lazyvim/shared"].lastSuccessfulRun = 20
    compare(Stats.migrate(saved, ["all"]).runSequence, 20)
  }

  function test_exhaustionAndLegacyBoundaryResumeAreNonDestructive() {
    var stats = Stats.defaults()
    stats.runSequence = Stats.MAX_COUNTER - 2
    compare(Stats.allocateRunIdentity(stats), Stats.MAX_COUNTER - 1)
    var id = "lazyvim/shared"
    Stats.recordGuided(stats, id, Stats.MAX_COUNTER - 1, 100)
    Stats.recordFirstTry(stats, id, true, 500, Stats.MAX_COUNTER - 1, 200)
    compare(stats.bindings[id].dueRun, Stats.MAX_COUNTER)
    var before = JSON.stringify(stats)
    rejected(function() { Stats.allocateRunIdentity(stats) }, "run-sequence-exhausted")
    compare(JSON.stringify(stats), before)
    compare(JSON.stringify(Stats.migrate(stats, ["all"])), before)
    // MAX_COUNTER was valid in legacy card/session records. Never narrow
    // resume validity or quarantine this valid history to regain ID space.
    compare(Stats.adoptRunIdentity(stats, Stats.MAX_COUNTER), Stats.MAX_COUNTER)
    compare(stats.runSequence, Stats.MAX_COUNTER)
    compare(Stats.peekRunIdentity(stats), 0)
    verify(Stats.recordFirstTry(stats, id, true, 300, Stats.MAX_COUNTER, 300).masteredGained)
    compare(stats.bindings[id].lastSuccessfulRun, Stats.MAX_COUNTER)
    Stats.recordFirstTry(stats, id, false, -1, Stats.MAX_COUNTER, 400)
    compare(stats.bindings[id].dueRun, 0)
    compare(stats.bindings[id].dueAt, Stats.MAX_TIMESTAMP)
    verify(!Stats.isDue(stats.bindings[id], 500, Stats.MAX_COUNTER))
    compare(Stats.migrate(stats, ["all"]).runSequence, Stats.MAX_COUNTER)
  }

  function test_hostileIdentityValuesCannotWrapOrMutateCards() {
    var values = [-1, 0, 1.5, "1", null, undefined, NaN, Infinity, Stats.MAX_COUNTER + 1]
    values.forEach(function(identity) {
      var stats = Stats.defaults()
      var before = JSON.stringify(stats)
      rejected(function() { Stats.recordGuided(stats, "lazyvim/shared", identity, 100) })
      rejected(function() { Stats.recordFirstTry(stats, "lazyvim/shared", true, 300, identity, 200) })
      compare(JSON.stringify(stats), before)
      verify(!Stats.isDue({state: "learning", dueRun: 1}, 300, identity))
    })
    ;[-1, 1.5, "1", null, undefined, NaN, Infinity, Stats.MAX_COUNTER + 1].forEach(function(value) {
      var stats = Stats.defaults()
      stats.runSequence = value
      rejected(function() { Stats.allocateRunIdentity(stats) }, "run-sequence-exhausted")
      compare(Stats.migrate(stats, ["all"]).runSequence, Stats.MAX_COUNTER)
    })
    ;[[], "9", 9, null, {runs: "9"}, {runs: -1}].forEach(function(counter) {
      var stats = Stats.migrate({schemaVersion: 4, profiles: {lazyvim: counter}, bindings: {}}, ["all"])
      compare(stats.runSequence, Stats.MAX_COUNTER)
      compare(Stats.peekRunIdentity(stats), 0)
    })
  }

  function test_guidanceTargetsGlobalNextRunWithoutAllocating() {
    var stats = Stats.defaults()
    Stats.allocateRunIdentity(stats)
    Stats.allocateRunIdentity(stats)
    Stats.ensureCounters(stats, "all").runs = 99
    Stats.requestGuidance(stats, "lazyvim/shared")
    compare(stats.bindings["lazyvim/shared"].dueRun, 3)
    compare(stats.runSequence, 2)
  }

  function test_defaultsAndIndependentDeckCounters() {
    var stats = Stats.defaults()
    compare(stats.schemaVersion, 5)
    compare(Object.getPrototypeOf(stats.bindings), null)
    compare(Object.getPrototypeOf(stats.decks), null)
    compare(Stats.completeRun(stats, "all"), 1)
    compare(Stats.completeRun(stats, "lsp"), 1)
    Stats.ensureCounters(stats, "all").coverageCursor = 17
    compare(Stats.counters(stats, "lsp").coverageCursor, 0)
    Stats.noteFirstMastery(stats, "all", 123, 1)
    compare(Stats.counters(stats, "lsp").firstMasteryAt, 0)
    compare(Stats.counters(stats, "missing").runs, 0)
    compare(Object.keys(stats.decks).length, 2)
  }

  function test_currentSchemaDropsOnlyDerivedProgress() {
    var source = { schemaVersion: 5, bindings: {}, decks: {
      all: { runs: 3, knownTotal: 100, knownMastered: 45 },
      deleted: { runs: 8, totalTrainingMs: 900, firstMasteryAt: 5, firstMasteryRun: 2,
                 firstMasteryCelebrated: true }
    } }
    var stats = Stats.migrate(source, ["all"])
    compare(stats.decks.all.runs, 3)
    compare(stats.decks.all.knownTotal, undefined)
    compare(stats.decks.all.knownMastered, undefined)
    compare(stats.decks.deleted.firstMasteryCelebrated, true)
    compare(JSON.stringify(Stats.migrate(stats, ["all"])), JSON.stringify(stats))
  }

  function test_overcapNeedsFinalDeclarations() {
    var source = Stats.defaults()
    for (var i = 0; i < 60; i++) source.decks["deck-" + i] = { runs: i }
    var before = JSON.stringify(source)
    rejected(function() { Stats.migrate(source) }, "declared-decks-required")
    rejected(function() { Stats.parse(before) }, "declared-decks-required")
    compare(JSON.stringify(source), before)
    var ids = ["all", "deck-59", "deck-58"]
    var stats = Stats.migrate(source, ids)
    compare(Object.keys(stats.decks).length, 48)
    compare(stats.decks["deck-59"].runs, 59)
    compare(stats.decks["deck-58"].runs, 58)
  }

  function test_orphansCannotCrowdOutNeverPlayedDeclaredDecks() {
    var source = Stats.defaults()
    for (var i = 0; i < 48; i++) source.decks["orphan-" + i] = { runs: i }
    var stats = Stats.migrate(source, ["all", "brand-new"])
    compare(Object.keys(stats.decks).length, 48)
    compare(Stats.completeRun(stats, "all"), 1)
    compare(Stats.completeRun(stats, "brand-new"), 1)
    compare(stats.decks.all.runs, 1)
    compare(stats.decks["brand-new"].runs, 1)
    compare(Stats.migrate(stats, ["all", "brand-new"]).decks.all.runs, 1)
  }

  function test_statsHostileCountersAndBindingCaps() {
    var source = JSON.parse('{"schemaVersion":5,"bindings":{},"decks":{"__proto__":{"polluted":true},"constructor":{"runs":3},"prototype":{"runs":4},"Nope":{"runs":9},"safe":{"runs":1e100,"coverageCursor":-8}}}')
    var result = Stats.migrate(source, ["all"])
    compare(Object.keys(result.decks).join(","), "safe")
    compare(result.decks.safe.runs, Stats.MAX_COUNTER)
    compare(result.decks.safe.coverageCursor, 0)
    compare(({}).polluted, undefined)
    for (var i = 0; i < 4001; i++) source.bindings["future/card-" + i] = Stats.freshEntry()
    result = Stats.migrate(source, ["all"])
    compare(Object.keys(result.bindings).length, 4000)
    compare(Object.getPrototypeOf(result.bindings), null)
  }

  function test_legacyNamespaceUnaffectedByDefaultSupply() {
    for (var version = 1; version <= 3; version++) {
      var stats = Stats.migrate({ schemaVersion: version, runs: 9, bindings: { "normal/gd": {} } })
      verify(stats.bindings["hyprland/normal/gd"] !== undefined)
      compare(stats.bindings["lazyvim/normal/gd"], undefined)
      compare(Object.keys(stats.decks).length, 0)
    }
  }

  function test_deltaRoundtripRetainsAbsentDecksAndCards() {
    var source = { deleted: { added: ["lazyvim/normal/missing", "tmux/prefix/%"],
                              removed: ["future-supply/unknown"] } }
    var normalized = DeckState.normalize(source)
    compare(JSON.stringify(normalized), JSON.stringify(source))
    compare(Object.getPrototypeOf(normalized), null)
    source.deleted.added.push("lazyvim/changed")
    compare(normalized.deleted.added.length, 2)
    compare(JSON.stringify(DeckState.normalize(JSON.parse(JSON.stringify(normalized)))),
            JSON.stringify(normalized))
  }

  function test_deltaAddRemoveResetAreIndependentOfExclusion() {
    var original = DeckState.normalize({ retired: { added: ["vim/normal/gg"], removed: [] } })
    var before = JSON.stringify(original)
    var added = DeckState.change(original, "lsp", "lazyvim/normal/gd", "add")
    compare(JSON.stringify(original), before)
    compare(added.lsp.added[0], "lazyvim/normal/gd")
    var removed = DeckState.change(added, "lsp", "lazyvim/normal/gd", "remove")
    compare(removed.lsp.added.length, 0)
    compare(removed.lsp.removed[0], "lazyvim/normal/gd")
    var reset = DeckState.change(removed, "lsp", "lazyvim/normal/gd", "reset")
    compare(reset.lsp.added.length, 0)
    compare(reset.lsp.removed.length, 0)
    compare(reset.retired.added[0], "vim/normal/gg")
    rejected(function() { DeckState.change(original, "all", "lazyvim/a", "add") })
  }

  function test_deltaExactSerializedUtf8BudgetAndAtomicRefusal() {
    var source = { deck: { added: [], removed: [] } }
    for (var i = 0; i < 8; i++) source.deck.added.push("lazyvim/" + i + "名".repeat(1000))
    var remaining = DeckState.MAX_BYTES - DeckState.serializedBytes(source)
    // Adding one quoted id costs its length + comma + two quotes.
    source.deck.added.push("x/" + "a".repeat(remaining - 5))
    compare(DeckState.serializedBytes(source), DeckState.MAX_BYTES)
    var atCap = DeckState.normalize(source)
    var before = JSON.stringify(atCap)
    rejected(function() { DeckState.change(atCap, "new-deck", "lazyvim/new", "add") }, "deck-cards-limit")
    compare(JSON.stringify(atCap), before)
    // Replacing a delta need not grow the map: no-op additions still succeed.
    compare(DeckState.serializedBytes(DeckState.change(atCap, "deck", source.deck.added[0], "add")),
            DeckState.MAX_BYTES)
    verify(JSON.stringify(source).length < DeckState.MAX_BYTES)
  }

  function test_utf8CountsJsonEscapesAndSurrogates() {
    compare(DeckState.serializedBytes("名😀"), 9)
    compare(DeckState.serializedBytes('"\\\n'), 8)
    compare(DeckState.utf8Bytes("\ud800"), 3)
    // Qt's JSON serializer leaves lone surrogates unescaped; the byte counter
    // charges the UTF-8 replacement scalar, without encodeURIComponent throws.
    compare(DeckState.serializedBytes("\ud800"), 5)
    compare(DeckState.serializedBytes("😀"), 6)
  }

  function test_hostileDeltaShapesAndIdsAreRejectedWithoutPollution() {
    var values = [null, [], true, { safe: [] }, { safe: { added: "no", removed: [] } },
      { safe: { added: ["unqualified"], removed: [] } },
      { safe: { added: ["lazyvim/__proto__"], removed: [] } },
      { safe: { added: ["lazyvim/"], removed: [] } },
      { safe: { added: ["lazyvim/\ud800"], removed: [] } },
      { safe: { added: ["lazyvim/\udfff"], removed: [] } },
      JSON.parse('{"__proto__":{"added":[],"removed":[]}}'),
      JSON.parse('{"constructor":{"added":[],"removed":[]}}'),
      JSON.parse('{"prototype":{"added":[],"removed":[]}}')]
    values.forEach(function(value) { rejected(function() { DeckState.normalize(value) }) })
    compare(({}).polluted, undefined)
    compare(Object.keys(DeckState.normalize(undefined)).length, 0)
    compare(DeckState.normalize({ safe: { added: ["lazyvim/😀"], removed: [] } }).safe.added[0],
            "lazyvim/😀")
  }

  function test_deltaLimitsRejectNotTruncate() {
    var list = []
    for (var i = 0; i < 4097; i++) list.push("a/b")
    rejected(function() { DeckState.normalize({ deck: { added: list, removed: [] } }) })
    rejected(function() { DeckState.normalize({ deck: { added: ["a/" + "x".repeat(2301)], removed: [] } }) })
    var map = DeckState.map()
    for (var d = 0; d < 1025; d++) map["d-" + d] = { added: [], removed: [] }
    rejected(function() { DeckState.normalize(map) })
  }

  function test_declaredIdsAreBoundedSyntacticNotRegistryFiltered() {
    compare(DeckState.declaredIds(["zz-deleted", "all", "zz-deleted"]).join(","), "all,zz-deleted")
    rejected(function() { DeckState.declaredIds(["__proto__"]) })
    rejected(function() { DeckState.declaredIds(["constructor"]) })
    rejected(function() { DeckState.declaredIds("all") })
    var values = []
    for (var i = 0; i < 34; i++) values.push("d-" + i)
    rejected(function() { DeckState.declaredIds(values) })
  }
}
