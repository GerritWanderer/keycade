import QtQuick
import QtTest
import "../../lib" as Lib
import "../../lib/sources" as Sources
import "../../lib/Decks.js" as Decks
import "../../lib/DeckValidation.js" as Validation
import "../../lib/DeckState.js" as DeckState
import "../../lib/Packs.js" as Packs
import "../../lib/Profiles.js" as Profiles
import "../../lib/Scheduler.js" as Scheduler
import "../../lib/Session.js" as Session
import "../../lib/Stats.js" as Stats

TestCase {
  name: "DeckEngine"
  Lib.I18n { id: i18n }
  Sources.PackSource { id: pack; profileId: "lazyvim" }

  function declarations(decks) {
    return Decks.definitions(Validation.validate({ schemaVersion: 1, status: "valid", reason: "",
      decks: decks, rejected: 0 }, Packs.pack("lazyvim"), Profiles.contexts("lazyvim")))
  }
  function cards(count) {
    var result = []
    for (var i = 0; i < count; i++) result.push({ id: "lazyvim/normal/card-" + String(i).padStart(2, "0"),
      localId: "normal/card-" + String(i).padStart(2, "0"), category: "git", extras: [],
      answer: { context: "normal", steps: [{ text: "a" }] } })
    return result
  }
  function unique(queue) {
    var seen = Object.create(null)
    queue.forEach(function(card) { verify(!seen[card.binding.id]); seen[card.binding.id] = true })
  }
  function session() {
    return { schemaVersion: 2, deckId: "git", runId: 123, runNumber: 2, sessionSize: 7, offset: 2,
      cards: Session.cardsFrom(Scheduler.build(cards(5), Stats.defaults(), 24, {deckId: "git"}), 0),
      correct: 1, attempts: 2, newLearned: 1, masteredGained: 0, runReviewTarget: 4, runNewTarget: 3,
      correctionRequired: true, pendingReinforcements: [cards(1)[0].id],
      reactions: [321], runResults: { "lazyvim/normal/card-00": { misses: 1, reactions: [321] } } }
  }

  function test_absentStartersUseActualPackVocabularyAndLocales() {
    var resolved = Decks.definitions({schemaVersion: 1, status: "absent", reason: "", decks: [], rejected: 0})
    compare(Decks.ids(resolved.decks).join(","), "all,navigation,lsp,search,git")
    compare(resolved.rejected, 0)
    var vocabulary = Validation.vocabulary(Packs.pack("lazyvim"), Profiles.contexts("lazyvim"))
    resolved.decks.forEach(function(deck) {
      verify(deck.nameKey.length > 0)
      ;["en", "zh-CN"].forEach(function(locale) {
        i18n.locale = locale
        verify(i18n.t(deck.nameKey) !== deck.nameKey)
      })
      if (deck.seed) deck.seed.categories.forEach(function(category) { verify(vocabulary.categories[category]) })
    })
    compare(resolved.decks[1].seed.categories.join(","), "navigation,window,buffer,tab")
    compare(resolved.decks[2].seed.categories.join(","), "lsp,diagnostics")
    compare(resolved.decks[3].seed.categories.join(","), "search,find")
  }

  function test_presentEmptyReplacesStartersInvalidFallsBackNonfatally() {
    compare(Decks.ids(declarations([]).decks).join(","), "all")
    var invalid = Decks.definitions(Validation.invalid("malformed-json"))
    compare(Decks.ids(invalid.decks).join(","), "all")
    compare(invalid.reason, "malformed-json")
    compare(Decks.evaluate(invalid.decks[0], cards(7), {}, []).length, 7)
  }

  function test_reservedAllOpaqueSeedPinnedFirstAndDeclarationOrder() {
    var resolved = declarations([{id: "z", name: "Z"},
      {id: "all", name: "Everything", seed: {constructor: ["poison"], anything: {deep: 9}}},
      {id: "a", name: "A"}])
    compare(Decks.ids(resolved.decks).join(","), "all,z,a")
    compare(resolved.rejected, 0)
    compare(resolved.decks[0].name, "Everything")
    compare(resolved.decks[0].seed, undefined)
    var corpus = cards(3)
    var delta = { all: { added: [], removed: corpus.map(function(c) { return c.id }) } }
    compare(Decks.evaluate(resolved.decks[0], corpus, delta, []).length, 3)
  }

  function test_unionDimensionsEmptyConstraintsAndUnseeded() {
    var corpus = cards(4)
    corpus[1].category = "lsp"
    corpus[2].category = "misc"; corpus[2].answer.context = "insert"
    corpus[3].category = "misc"; corpus[3].extras = ["lazyvim.plugins.extras.editor.harpoon2"]
    var resolved = declarations([{id: "mixed", name: "Mixed", seed: {categories: ["lsp"], contexts: ["insert"],
      extras: ["lazyvim.plugins.extras.editor.harpoon2"]}},
      {id: "empty", name: "Empty", seed: {categories: ["telepathy"]}},
      {id: "manual", name: "Manual"}, {id: "any", name: "Any", seed: {}}])
    compare(resolved.rejected, 1)
    compare(Decks.evaluate(resolved.decks[1], corpus, {}, []).length, 3)
    compare(resolved.decks[2].seed.categories.length, 0)
    compare(Decks.evaluate(resolved.decks[2], corpus, {}, []).length, 0)
    compare(Decks.evaluate(resolved.decks[3], corpus, {}, []).length, 0)
    compare(Decks.evaluate(resolved.decks[4], corpus, {}, []).length, 4)
  }

  function test_liveSeedUnionAddedMinusRemovedExclusionWinsAndMissingInert() {
    var corpus = cards(3)
    var decks = declarations([{id: "git", name: "Git", seed: {categories: ["git"]}},
      {id: "manual", name: "Manual"}]).decks
    var deltas = DeckState.change({}, "git", corpus[0].id, "remove")
    deltas = DeckState.change(deltas, "manual", corpus[0].id, "add")
    deltas = DeckState.change(deltas, "manual", "lazyvim/missing", "add")
    deltas = DeckState.change(deltas, "orphan", corpus[1].id, "add")
    var before = JSON.stringify(deltas)
    compare(Decks.evaluate(decks[1], corpus, deltas, []).length, 2)
    compare(Decks.evaluate(decks[2], corpus, deltas, []).length, 1)
    compare(Decks.evaluate(decks[0], corpus, deltas, []).length, 3)
    compare(Decks.evaluate(null, corpus, deltas, []).length, 0)
    compare(Decks.evaluate(decks[1], cards(4), deltas, []).length, 3)
    var excluded = ["lazyvim:" + corpus[0].localId, "tmux:foreign"]
    compare(Decks.evaluate(decks[2], corpus, deltas, excluded).length, 0)
    compare(Decks.evaluate(decks[0], corpus.concat(corpus, [{id: "tmux/foreign"}]), deltas, excluded).length, 2)
    compare(Decks.otherDecks(decks, corpus[0].id, "git", corpus, deltas, []).map(function(d) {return d.id}).join(","), "all,manual")
    compare(Decks.otherDecks(decks, corpus[0].id, "git", corpus, deltas, excluded).length, 0)
    compare(JSON.stringify(deltas), before)
    var restored = declarations([{id: "orphan", name: "Restored"}]).decks[1]
    compare(Decks.evaluate(restored, corpus, deltas, []).length, 1)
  }

  function test_realCustomKeymapsParticipateNormallyAndExtrasStayGated() {
    pack.enabledExtras = []
    pack.overrides = [{op: "set", lhs: "<leader>zz", desc: "Custom", contexts: ["normal"]},
      {op: "set", lhs: "<C-h>", desc: "Changed", contexts: ["normal"]}]
    pack.refresh()
    var defs = declarations([{id: "misc", name: "Misc", seed: {categories: ["misc"]}},
      {id: "mode", name: "Normal", seed: {contexts: ["normal"]}},
      {id: "harpoon", name: "Harpoon", seed: {extras: ["lazyvim.plugins.extras.editor.harpoon2"]}}]).decks
    var misc = Decks.evaluate(defs[1], pack.bindings, {}, [])
    verify(misc.some(function(c) { return c.customKind === "added" && c.notation === "<leader>zz" }))
    var mode = Decks.evaluate(defs[2], pack.bindings, {}, [])
    verify(mode.some(function(c) { return c.customKind === "changed" && c.notation === "<C-h>" }))
    compare(Decks.evaluate(defs[3], pack.bindings, {}, []).length, 0)
    pack.enabledExtras = ["lazyvim.plugins.extras.editor.harpoon2"]
    pack.refresh()
    verify(Decks.evaluate(defs[3], pack.bindings, {}, []).length > 0)
    pack.overrides = []; pack.enabledExtras = []
  }

  function test_schedulerSizesAndDuplicateInput_data() {
    return [0, 1, 7, 12, 24, 50].map(function(n) { return {tag: String(n), n: n} })
  }
  function test_schedulerSizesAndDuplicateInput(data) {
    var corpus = cards(data.n)
    var stats = Stats.defaults()
    var before = JSON.stringify(stats)
    var queue = Scheduler.build(corpus.concat(corpus), stats, 24, {deckId: "git"})
    compare(queue.length, Math.min(24, data.n)); unique(queue)
    compare(JSON.stringify(stats), before) // no read-time identity/history allocations
    compare(Scheduler.build(corpus, stats, 0, {deckId: "git"}).length, 0)
  }

  function pools(counts) {
    var stats = Stats.defaults(), corpus = cards(counts.reduce(function(a, b) { return a + b }, 0))
    var index = 0
    counts.forEach(function(count, kind) {
      for (var i = 0; i < count; i++) {
        var item = Stats.entry(stats, corpus[index++].id)
        if (kind === 1) continue
        item.state = kind === 3 ? "mastered" : "learning"
        item.dueRun = kind === 0 ? 1 : 999
      }
    })
    return { stats: stats, corpus: corpus }
  }
  function test_proportionalSharesAndDueFirstRefill() {
    compare(JSON.stringify(Scheduler.allocation(12)), JSON.stringify({due: 5, unseen: 3, weak: 3, maintenance: 1}))
    var source = pools([10, 6, 6, 2])
    var queue = Scheduler.build(source.corpus, source.stats, 12, {deckId: "git", runId: 1})
    ;["due", "unseen", "weak", "maintenance"].forEach(function(name, i) {
      compare(queue.filter(function(c) { return c.queue === name }).length, [5, 3, 3, 1][i])
    })
    source = pools([40, 0, 0, 10])
    queue = Scheduler.build(source.corpus, source.stats, 24, {deckId: "git", runId: 1})
    compare(queue.filter(function(c) { return c.queue === "due" }).length, 22)
    compare(queue.filter(function(c) { return c.queue === "maintenance" }).length, 2)
    unique(queue)
  }
  function test_eachExhaustedShareRefillsWithoutRepeats() {
    // Every nonempty combination of the four pools, including one-card pools.
    for (var mask = 1; mask < 16; mask++) {
      ;[1, 7, 50].forEach(function(amount) {
        var source = pools([0, 1, 2, 3].map(function(i) {return mask & (1 << i) ? amount : 0}))
        var queue = Scheduler.build(source.corpus, source.stats, 24, {deckId: "git", runId: 1})
        compare(queue.length, Math.min(24, source.corpus.length)); unique(queue)
      })
    }
  }
  function test_coverageIndependentFromCorpusAndGlobalRunIdentity() {
    var corpus = cards(50), stats = Stats.defaults()
    var first = Scheduler.coverageOrder(corpus, stats, "git")[0]
    Scheduler.markCovered(corpus, stats, first.id, "git")
    compare(Scheduler.coverageOrder(corpus, stats, "lsp")[0].id, first.id)
    verify(Scheduler.coverageOrder(corpus, stats, "git")[0].id !== first.id)
    compare(Stats.counters(stats, "lazyvim").coverageCursor, 0)
    compare(stats.runSequence, 0)
    stats.runSequence = 70
    var item = Stats.entry(stats, first.id); item.state = "learning"; item.dueRun = 71
    var queue = Scheduler.build(corpus, stats, 24, {deckId: "lsp"})
    compare(queue.filter(function(c) {return c.queue === "due"})[0].binding.id, first.id)
    compare(stats.runSequence, 70)
  }

  function test_sharedProgressDistinctIdentitiesAndSmallDeckMasteryOnceEach() {
    var stats = Stats.defaults(), corpus = cards(1)
    var defs = declarations([{id: "git", name: "Git", seed: {}}, {id: "lsp", name: "LSP", seed: {}}]).decks
    var first = Stats.allocateRunIdentity(stats)
    Stats.recordGuided(stats, corpus[0].id, first, 1)
    Stats.recordFirstTry(stats, corpus[0].id, true, 321, first, 2)
    Stats.completeRun(stats, "git")
    var second = Stats.allocateRunIdentity(stats)
    verify(second !== first)
    Stats.recordFirstTry(stats, corpus[0].id, true, 321, second, 3)
    defs.forEach(function(d) {
      compare(Decks.progress(d, corpus, {}, [], stats, 4, second).mastered, 1)
      verify(Stats.noteFirstMastery(stats, d.id, 4, 1))
      verify(Stats.markFirstMasteryCelebrated(stats, d.id))
      verify(!Stats.noteFirstMastery(stats, d.id, 5, 2))
      verify(!Stats.markFirstMasteryCelebrated(stats, d.id))
      compare(Stats.counters(stats, d.id).firstMasteryRun, 1)
    })
    compare(Stats.runsOf(stats, "git"), 1); compare(Stats.runsOf(stats, "lsp"), 0)
  }

  function test_sessionRoundtripExactAndScopeIsolation() {
    var saved = Session.sanitize(session())
    verify(saved !== null)
    compare(JSON.stringify(Session.sanitize(saved)), JSON.stringify(saved))
    verify(Session.canResume(saved, 123, cards(5), 24, "git"))
    verify(!Session.canResume(saved, 123, cards(5), 24, "all"))
    verify(!Session.canResume(saved, 124, cards(5), 24, "git"))
    compare(Session.resumedSize(saved, cards(5)), 7)
    compare(Session.restoreCards(saved.cards, cards(5)).length, 5)
    compare(saved.correct, 1); compare(saved.offset, 2); compare(saved.runId, 123)
    compare(saved.runResults["lazyvim/normal/card-00"].misses, 1)
    compare(saved.pendingReinforcements.length, 1)
    verify(Session.resumeCorrection(saved, Session.restoreCards(saved.cards, cards(5))))
  }
  function test_sessionShrinkPreservesOffsetResultsScoreAndOriginalPlan() {
    var saved = session(), corpus = cards(5).slice(1)
    var restored = Session.restoreCards(saved.cards, corpus)
    compare(restored.length, 4); compare(Session.resumedSize(saved, corpus), 6)
    verify(!Session.resumeCorrection(saved, restored))
    saved.cards = Session.cardsFrom(restored, 0); saved.sessionSize = 6
    saved.correct = 7; saved.attempts = 8; saved.runReviewTarget = 12
    var clean = Session.sanitize(saved)
    verify(clean !== null); compare(clean.correct, 7); compare(clean.runReviewTarget, 12)
    var results = Session.restoreResults(clean.runResults, corpus)
    compare(results["lazyvim/normal/card-00"].misses, 1)
    compare(results["lazyvim/normal/card-00"].binding, null)
    verify(!Session.canResume(clean, 123, [], 24, "git"))
    compare(Session.resumedSize(clean, []), 2)
    compare(Stats.counts(Stats.defaults(), [], 1, 1).mastered, 0)
  }
  function test_sessionRejectsIncoherentBoundsAndForeignCards() {
    var cases = [{sessionSize: 25}, {sessionSize: 6}, {offset: 3}, {offset: -1},
      {runId: 0}, {runId: 1.5}, {runId: "123"}, {runNumber: 0}, {deckId: "constructor"},
      {correct: 25}, {attempts: -1}]
    cases.forEach(function(change) { compare(Session.sanitize(Object.assign(session(), change)), null) })
    var bad = session(); bad.cards[0].bindingId = "tmux/foreign"
    compare(Session.sanitize(bad), null)
    var legacy = {schemaVersion: 1, profileId: "tmux", runId: Stats.MAX_COUNTER,
      cards: [{bindingId: "tmux/foreign"}]}
    verify(!Session.canResume(legacy, Stats.MAX_COUNTER, [{id: "tmux/foreign"}], 24, "tmux"))
    compare(Session.scope(legacy), "")
    legacy.profileId = "lazyvim"; legacy.cards = [{bindingId: cards(1)[0].id}]
    verify(Session.canResume(legacy, Stats.MAX_COUNTER, cards(1), 24, "all"))
    compare(Session.sanitize(legacy).runId, Stats.MAX_COUNTER)
  }
}
