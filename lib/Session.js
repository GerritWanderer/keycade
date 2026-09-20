.pragma library
.import "Profiles.js" as Profiles
.import "DeckState.js" as DeckState

var MAX_CARDS = 24
var MAX_RESULTS = 24
// A card names a binding by its qualified id: the profile, a separator, and
// the id that profile's source minted. Exclusions store the local part alone,
// because they already carry their profile in a field of their own.
var MAX_LOCAL_ID = 2300
var MAX_BINDING_ID = MAX_LOCAL_ID + 33
var MAX_REACTIONS = 10
var MAX_COUNTER = 1000000000
var FORBIDDEN_KEYS = ["__proto__", "constructor", "prototype"]

function safeMap() { return Object.create(null) }

function safeId(value) {
  var id = String(value === undefined || value === null ? "" : value)
  return id && id.length <= MAX_BINDING_ID && FORBIDDEN_KEYS.indexOf(id) === -1 ? id : ""
}

// Exclusions ride in settings.json, whose whole payload is capped at 64 KiB
// (StateStore.fileLimits and bin/state-store FILE_LIMITS). A single binding id
// can reach MAX_BINDING_ID on its own, so a count cap alone is not a bound:
// cap the serialized array too, and refuse a new entry rather than truncate.
var MAX_EXCLUDED_ENTRIES = 64
var MAX_EXCLUDED_CHARS = 8 * 1024
// Entries from another training ground are kept but never consumed here, so
// two grounds cannot clear each other's exclusions.
function excludedEntry(profile, bindingId) {
  var id = safeId(bindingId)
  return id && Profiles.valid(profile) ? String(profile) + ":" + id : ""
}

function excludedList(values) {
  var list = []
  if (!Array.isArray(values)) return list
  var seen = safeMap()
  var chars = 2
  for (var index = 0; index < values.length && list.length < MAX_EXCLUDED_ENTRIES; index++) {
    var value = values[index]
    if (typeof value !== "string") continue
    var separator = value.indexOf(":")
    if (separator <= 0) continue
    var entry = excludedEntry(value.slice(0, separator), value.slice(separator + 1))
    if (!entry || seen[entry]) continue
    var cost = entry.length + 3
    if (chars + cost > MAX_EXCLUDED_CHARS) break
    chars += cost
    seen[entry] = true
    list.push(entry)
  }
  return list
}

// Consuming the stored array always goes through excludedList first, so the
// eligibility side never trusts what the settings file happened to hold.
function excludedSet(values, profile) {
  var prefix = String(profile === undefined || profile === null ? "" : profile) + ":"
  var set = safeMap()
  var list = excludedList(values)
  for (var index = 0; index < list.length; index++) {
    if (list[index].slice(0, prefix.length) === prefix)
      set[list[index].slice(prefix.length)] = true
  }
  return set
}

// Returns the new array, or null when the entry is invalid or does not fit.
function withExclusion(values, profile, bindingId) {
  var entry = excludedEntry(profile, bindingId)
  if (!entry) return null
  var list = excludedList(values)
  if (list.indexOf(entry) !== -1) return list
  var next = excludedList(list.concat([entry]))
  return next.indexOf(entry) === -1 ? null : next
}

function withoutExclusion(values, profile, bindingId) {
  var list = excludedList(values)
  var entry = excludedEntry(profile, bindingId)
  var index = entry ? list.indexOf(entry) : -1
  return index === -1 ? list : list.slice(0, index).concat(list.slice(index + 1))
}

function boundedInteger(value, minimum, maximum) {
  var number = typeof value === "number" && isFinite(value) ? value : minimum
  return Math.floor(Math.max(minimum, Math.min(maximum, number)))
}

function bindingMap(bindings) {
  var map = safeMap()
  for (var index = 0; index < Math.min((bindings || []).length, 2000); index++) {
    var binding = bindings[index]
    var id = binding ? safeId(binding.id) : ""
    if (id && Profiles.profileOf(id) === "lazyvim") map[id] = binding
  }
  return map
}

function cardsFrom(deck, startIndex) {
  var cards = []
  for (var index = Math.max(0, startIndex); index < deck.length && cards.length < MAX_CARDS; index++) {
    var cardValue = deck[index]
    cards.push({
      bindingId: cardValue.binding.id,
      tier: cardValue.tier,
      queue: cardValue.queue,
      remedial: Boolean(cardValue.remedial)
    })
  }
  return cards
}

function restoreCards(cards, bindings) {
  var map = bindingMap(bindings)
  var restored = []
  for (var index = 0; index < Math.min((cards || []).length, MAX_CARDS); index++) {
    var saved = cards[index]
    if (!saved || typeof saved !== "object" || Array.isArray(saved)) continue
    var binding = map[safeId(saved.bindingId)]
    var tier = ["guided", "learning", "maintenance"].indexOf(String(saved.tier)) !== -1
        ? String(saved.tier) : "learning"
    var queue = ["due", "unseen", "weak", "maintenance", "remedial"].indexOf(String(saved.queue)) !== -1
        ? String(saved.queue) : "weak"
    if (binding) restored.push({
      binding: binding,
      tier: tier,
      queue: queue,
      remedial: Boolean(saved.remedial)
    })
  }
  return restored
}

// v1 LazyVim sessions adapt to all without changing their global identity.
// Other v1 profiles remain retained/inert, even if a user declares a deck with
// that exact name. New writes use v2's deckId and explicit dynamic sessionSize.
function scope(session) {
  if (!session) return ""
  if (session.schemaVersion === 1) return session.profileId === "lazyvim" ? "all" : ""
  return session.schemaVersion === 2 && DeckState.validId(session.deckId) ? session.deckId : ""
}

function validInteger(value, minimum, maximum) {
  return typeof value === "number" && isFinite(value) && Math.floor(value) === value
      && value >= minimum && value <= maximum
}

function canResume(session, runId, bindings, cardLimit, deckId) {
  var saved = sanitize(session)
  var limit = Math.min(MAX_CARDS, cardLimit === undefined ? MAX_CARDS : cardLimit)
  if (!saved || !scope(saved) || scope(saved) !== deckId || saved.runId !== runId
      || saved.sessionSize > limit || saved.offset >= saved.sessionSize) return false
  return restoreCards(saved.cards, bindings).length > 0
}

// Changed configuration/exclusions may remove remaining cards, never replace
// them. The completed offset stays exact; the live size shrinks accordingly.
function resumedSize(session, bindings) {
  return session.offset + restoreCards(session.cards, bindings).length
}

function resumeCorrection(session, cards) {
  return Boolean(session.correctionRequired && cards.length && session.cards.length
      && cards[0].binding.id === session.cards[0].bindingId)
}

function serializableResults(results) {
  var output = safeMap()
  Object.keys(results || {}).slice(0, MAX_RESULTS).forEach(function(rawId) {
    var id = safeId(rawId)
    if (!id) return
    var row = results[id]
    if (!row || typeof row !== "object" || Array.isArray(row)) return
    output[id] = {
      misses: boundedInteger(row.misses, 0, MAX_COUNTER),
      reactions: Array.isArray(row.reactions) ? row.reactions.slice(-MAX_REACTIONS).map(function(value) {
        return boundedInteger(value, 0, 600000)
      }) : []
    }
  })
  return output
}

function restoreResults(saved, bindings) {
  var map = bindingMap(bindings)
  var restored = safeMap()
  if (!saved || typeof saved !== "object" || Array.isArray(saved)) return restored
  Object.keys(saved).slice(0, MAX_RESULTS).forEach(function(rawId) {
    var id = safeId(rawId)
    var row = id ? saved[id] : null
    if (id && Profiles.profileOf(id) === "lazyvim" && row && typeof row === "object" && !Array.isArray(row)) restored[id] = {
      binding: map[id] || null,
      misses: boundedInteger(row.misses, 0, MAX_COUNTER),
      reactions: Array.isArray(row.reactions) ? row.reactions.slice(-MAX_REACTIONS).map(function(value) {
        return boundedInteger(value, 0, 600000)
      }) : []
    }
  })
  return restored
}

// Ids written before training grounds existed carry no profile in front of
// them, and everything stored back then was played on Hyprland, forever
// independent of today's default supply. Qualify them on the way in so an
// interrupted legacy run is retained without becoming a LazyVim run.
function sessionId(rawId, profileId, legacy) {
  var id = safeId(rawId)
  if (!id || !legacy) return id
  // Bound the local part before the prefix goes on, so a long id is carried
  // over rather than dropped for overrunning the bound the prefix made.
  return id.length <= MAX_LOCAL_ID ? safeId(Profiles.qualifyLegacy(id, profileId)) : ""
}

function sanitize(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)
      || [1, 2].indexOf(value.schemaVersion) === -1 || !Array.isArray(value.cards)) return null
  var deckScoped = value.schemaVersion === 2
  if ((deckScoped || scope(value)) && !validInteger(value.runId, 1, MAX_COUNTER)) return null
  if (deckScoped && (!DeckState.validId(value.deckId)
      || !validInteger(value.sessionSize, 0, MAX_CARDS)
      || !validInteger(value.offset, 0, value.sessionSize)
      || value.cards.length + value.offset !== value.sessionSize
      || !validInteger(value.runNumber, 1, MAX_COUNTER))) return null
  var legacy = !deckScoped && !Profiles.valid(value.profileId)
  var profileId = legacy ? Profiles.LEGACY_ID : String(value.profileId || "")
  var result = {
    schemaVersion: value.schemaVersion,
    runId: boundedInteger(value.runId, 1, MAX_COUNTER),
    savedAt: boundedInteger(value.savedAt, 0, 9000000000000000),
    offset: boundedInteger(value.offset, 0, MAX_CARDS),
    cards: [],
    correctionRequired: value.correctionRequired === true,
    currentBindingId: sessionId(value.currentBindingId, profileId, legacy),
    runReviewTarget: boundedInteger(value.runReviewTarget, 0, MAX_CARDS),
    runNewTarget: boundedInteger(value.runNewTarget, 0, MAX_CARDS),
    correct: boundedInteger(value.correct, 0, MAX_CARDS),
    attempts: boundedInteger(value.attempts, 0, MAX_COUNTER),
    newLearned: boundedInteger(value.newLearned, 0, MAX_CARDS),
    masteredGained: boundedInteger(value.masteredGained, 0, MAX_CARDS),
    reactions: Array.isArray(value.reactions) ? value.reactions.slice(-MAX_REACTIONS).map(function(item) {
      return boundedInteger(item, 0, 600000)
    }) : [],
    pendingReinforcements: Array.isArray(value.pendingReinforcements)
        ? value.pendingReinforcements.slice(0, MAX_CARDS).map(function(item) {
            return sessionId(item, profileId, legacy)
          }).filter(Boolean) : [],
    runResults: safeMap()
  }
  if (deckScoped) {
    result.deckId = value.deckId
    result.runNumber = value.runNumber
    result.sessionSize = value.sessionSize
    // Exclusions/config changes can shrink size below the original plan or
    // score. Preserve those historical tallies, bounded by the original cap.
    var tallies = ["correct", "newLearned", "masteredGained", "runReviewTarget", "runNewTarget"]
    for (var t = 0; t < tallies.length; t++) {
      if (!validInteger(value[tallies[t]], 0, MAX_CARDS)) return null
    }
    if (!validInteger(value.attempts, 0, MAX_COUNTER) || value.correct > value.attempts) return null
  } else {
    result.profileId = profileId
    result.sessionSize = Math.min(MAX_CARDS, result.offset + value.cards.length)
  }
  for (var index = 0; index < Math.min(value.cards.length, MAX_CARDS - result.offset); index++) {
    var card = value.cards[index]
    if (!card || typeof card !== "object" || Array.isArray(card)) continue
    var bindingId = sessionId(card.bindingId, profileId, legacy)
    if (!bindingId) { if (deckScoped) return null; continue }
    if (deckScoped && (!DeckState.validCardId(bindingId) || Profiles.profileOf(bindingId) !== "lazyvim"))
      return null
    result.cards.push({
      bindingId: bindingId,
      tier: ["guided", "learning", "maintenance"].indexOf(String(card.tier)) !== -1
          ? String(card.tier) : "learning",
      queue: ["due", "unseen", "weak", "maintenance", "remedial"].indexOf(String(card.queue)) !== -1
          ? String(card.queue) : "weak",
      remedial: card.remedial === true
    })
  }
  if (deckScoped && result.cards.length !== value.cards.length) return null
  if (value.runResults && typeof value.runResults === "object" && !Array.isArray(value.runResults)) {
    Object.keys(value.runResults).slice(0, MAX_RESULTS).forEach(function(rawId) {
      var id = sessionId(rawId, profileId, legacy)
      var row = id ? value.runResults[rawId] : null
      if (!id || !row || typeof row !== "object" || Array.isArray(row)) return
      result.runResults[id] = {
        misses: boundedInteger(row.misses, 0, MAX_COUNTER),
        reactions: Array.isArray(row.reactions) ? row.reactions.slice(-MAX_REACTIONS).map(function(item) {
          return boundedInteger(item, 0, 600000)
        }) : []
      }
    })
  }
  return result
}
