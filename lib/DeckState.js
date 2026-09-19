.pragma library
.import "DeckValidation.js" as Validation
.import "Profiles.js" as Profiles

// Stored choices are independent of today's declarations and corpus (D10).
// Never use registry membership here, and never evict curation to admit an edit.
var MAX_BYTES = 24 * 1024
var MAX_DECK_RECORDS = 1024
var MAX_LIST_ENTRIES = 4096
var MAX_LOCAL_ID = 2300
var MAX_DECLARED = 33 // 32 declarations, plus the reserved all

function map() { return Object.create(null) }
function object(value) { return Validation.object(value) }
function own(value, key) { return Validation.own(value, key) }
function validId(value) { return Validation.validId(value) }
function utf8Bytes(text) { return Validation.utf8Bytes(text) }
function serializedBytes(value) { return utf8Bytes(JSON.stringify(value)) }

function validCardId(value) {
  if (typeof value !== "string" || value.length > MAX_LOCAL_ID + 33) return false
  var local = Profiles.localOf(value)
  if (!local || local.length > MAX_LOCAL_ID || !Validation.usableKey(local)) return false
  // A lone surrogate cannot round-trip through the helper's UTF-8 writer.
  // Refuse it rather than silently persisting a different card identity.
  for (var i = 0; i < local.length; i++) {
    var code = local.charCodeAt(i)
    if (code >= 0xd800 && code <= 0xdbff) {
      var low = local.charCodeAt(++i)
      if (!(low >= 0xdc00 && low <= 0xdfff)) return false
    } else if (code >= 0xdc00 && code <= 0xdfff) return false
  }
  return true
}

function declaredIds(values) {
  if (!Array.isArray(values) || values.length > MAX_DECLARED)
    throw new Error("invalid-declared-decks")
  var result = ["all"]
  values.forEach(function(id) {
    if (!validId(id)) throw new Error("invalid-declared-decks")
    if (result.indexOf(id) === -1) result.push(id)
  })
  if (result.length > MAX_DECLARED) throw new Error("invalid-declared-decks")
  return result
}

function idList(values) {
  if (!Array.isArray(values) || values.length > MAX_LIST_ENTRIES)
    throw new Error("invalid-deck-cards")
  var seen = map()
  var result = []
  values.forEach(function(id) {
    if (!validCardId(id)) throw new Error("invalid-deck-cards")
    if (!seen[id]) { seen[id] = true; result.push(id) }
  })
  return result
}

// Reject malformed/over-budget persisted maps through the existing quarantine
// path, not a partial cleanup which would silently discard deliberate choices.
function normalize(value) {
  if (value === undefined) return map()
  if (!object(value)) throw new Error("invalid-deck-cards")
  var keys = Object.keys(value)
  if (keys.length > MAX_DECK_RECORDS || serializedBytes(value) > MAX_BYTES)
    throw new Error("deck-cards-limit")
  var result = map()
  keys.forEach(function(id) {
    if (!validId(id) || !object(value[id])
        || !own(value[id], "added") || !own(value[id], "removed"))
      throw new Error("invalid-deck-cards")
    result[id] = { added: idList(value[id].added), removed: idList(value[id].removed) }
  })
  return result
}

// add/remove express explicit membership; reset removes both overrides. The
// later drawer chooses reset for an added card and remove for a seeded card.
// all has no curation surface. Other undeclared IDs remain legitimate state.
function change(value, deckId, cardId, action) {
  if (!validId(deckId) || deckId === "all" || !validCardId(cardId)
      || ["add", "remove", "reset"].indexOf(action) === -1)
    throw new Error("invalid-deck-cards")
  var next = normalize(value)
  var item = next[deckId] || { added: [], removed: [] }
  item.added = item.added.filter(function(id) { return id !== cardId })
  item.removed = item.removed.filter(function(id) { return id !== cardId })
  if (action === "add") item.added.push(cardId)
  if (action === "remove") item.removed.push(cardId)
  next[deckId] = item
  // Check the entire candidate, including JSON punctuation/escaping and UTF-8,
  // before exposing it. The caller's original map and arrays are never touched.
  return normalize(next)
}
