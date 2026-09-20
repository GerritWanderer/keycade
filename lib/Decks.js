.pragma library
.import "DeckValidation.js" as Validation
.import "DeckState.js" as DeckState
.import "Packs.js" as Packs
.import "Profiles.js" as Profiles
.import "Session.js" as Session
.import "Stats.js" as Stats

// Definitions consume AppConfigSource's already independently validated result.
// Never persist these records or their derived membership. In particular all's
// seed is opaque even here; its name is the only user override we read.
var STARTERS = [
  { id: "navigation", name: "Navigation", nameKey: "deckNavigation",
    seed: { categories: ["navigation", "window", "buffer", "tab"] } },
  { id: "lsp", name: "LSP & Diagnostics", nameKey: "deckLsp",
    seed: { categories: ["lsp", "diagnostics"] } },
  { id: "search", name: "Search & Find", nameKey: "deckSearch",
    seed: { categories: ["search", "find"] } },
  { id: "git", name: "Git", nameKey: "deckGit", seed: { categories: ["git"] } }
]

function definitions(config) {
  var all = { id: "all", name: "All", nameKey: "deckAll" }
  var declarations = []
  var reason = config.reason
  var rejected = config.rejected
  if (config.status === "absent") {
    // The same vocabulary/validator as the reader consumer checks compiled
    // seeds against the actual shipped pack, not a second category registry.
    var compiled = Validation.validate({ schemaVersion: 1, status: "valid", reason: "",
      rejected: 0, decks: STARTERS.map(function(item) {
        return { id: item.id, name: item.name, seed: item.seed }
      }) }, Packs.pack("lazyvim"), Profiles.contexts("lazyvim"))
    declarations = compiled.decks
    rejected += compiled.rejected
    reason = compiled.reason
    declarations.forEach(function(item, index) { item.nameKey = STARTERS[index].nameKey })
  } else if (config.status === "valid") declarations = config.decks
  var result = [all]
  declarations.forEach(function(item) {
    if (item.id === "all") { all.name = item.name; all.nameKey = ""; return }
    var record = { id: item.id, name: item.name, nameKey: item.nameKey || "" }
    if (Validation.own(item, "seed")) {
      record.seed = Object.create(null)
      Validation.SEED_KEYS.forEach(function(key) {
        if (Validation.own(item.seed, key)) record.seed[key] = item.seed[key].slice()
      })
    }
    result.push(record)
  })
  return { decks: result, reason: reason, rejected: rejected, status: config.status }
}

function ids(definitions) { return definitions.map(function(item) { return item.id }) }
function find(definitions, id) {
  for (var i = 0; i < definitions.length; i++) if (definitions[i].id === id) return definitions[i]
  return null
}

// PackSource has already enforced ingestion/gating. Exclusions and the corpus
// namespace still win before either seeds OR explicit additions (D10/D12).
function eligible(corpus, exclusions) {
  var excluded = Session.excludedSet(exclusions, "lazyvim")
  var seen = Object.create(null)
  return corpus.filter(function(card) {
    if (!card || !DeckState.validCardId(card.id) || Profiles.profileOf(card.id) !== "lazyvim"
        || seen[card.id] || excluded[Profiles.localOf(card.id)]) return false
    seen[card.id] = true
    return true
  })
}

function seedMatches(definition, card) {
  if (definition.id === "all") return true
  if (!Validation.own(definition, "seed")) return false
  var seed = definition.seed
  var dimensions = Object.keys(seed)
  if (!dimensions.length) return true // an explicit unconstrained seed
  // Present dimensions UNION, not intersection. A present empty array must
  // remain constrained: rejected vocabulary must never expand into all.
  return (seed.categories && seed.categories.indexOf(card.category) !== -1)
      || (seed.contexts && seed.contexts.indexOf((card.answer || {}).context) !== -1)
      || (seed.extras && (card.extras || []).some(function(extra) {
        return seed.extras.indexOf(extra) !== -1
      })) || false
}

function membership(definition, card, deltas) {
  if (!definition || !card) return { member: false, seeded: false, added: false, removed: false }
  var seeded = Boolean(seedMatches(definition, card))
  var delta = deltas && deltas[definition.id]
  var added = definition.id !== "all" && Boolean(delta && delta.added.indexOf(card.id) !== -1)
  var removed = definition.id !== "all" && Boolean(delta && delta.removed.indexOf(card.id) !== -1)
  return { member: (seeded || added) && !removed, seeded: seeded, added: added, removed: removed }
}

function evaluate(definition, corpus, deltas, exclusions) {
  if (!definition) return [] // missing declarations/deltas stay inert
  return eligible(corpus, exclusions).filter(function(card) {
    return membership(definition, card, deltas).member
  })
}

// Pass the eligible corpus, not a stale card object, so absent/excluded cards
// cannot acquire badges through a stored delta alone.
function otherDecks(definitions, cardId, targetId, corpus, deltas, exclusions) {
  var cards = eligible(corpus, exclusions)
  var card = null
  for (var i = 0; i < cards.length; i++) if (cards[i].id === cardId) { card = cards[i]; break }
  return definitions.filter(function(definition) {
    return definition.id !== targetId && membership(definition, card, deltas).member
  })
}

function progress(definition, corpus, deltas, exclusions, stats, now, runId) {
  return Stats.counts(stats, evaluate(definition, corpus, deltas, exclusions), now, runId)
}
