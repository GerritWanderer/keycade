.pragma library

// Consumer-only, pure boundary. No helper vocabulary or validation is trusted.
// validate(payload, Packs.pack("lazyvim"), Profiles.contexts("lazyvim")) returns
// {schemaVersion:1,status:"absent"|"valid"|"invalid",reason,decks,rejected}.
// absent selects starters later; invalid selects only all later; valid replaces
// starters even with zero declarations. We do not mint all, reorder declarations,
// evaluate seeds, or retain references to external records. A missing seed, {},
// and explicit [] dimensions remain distinct for the later deck engine.
var MAX_BYTES = 64 * 1024
var MAX_DECKS = 32
var MAX_REJECTED = 100000
var SEED_KEYS = ["categories", "extras", "contexts"]
var SEED_COUNTS = [24, 32, 8]
var SEED_CHARS = [32, 128, 32]
var REASONS = ["unsafe-path", "unsafe-config-home", "unreadable", "non-regular",
               "too-large", "invalid-utf8", "invalid-json", "invalid-schema",
               "vocabulary-unavailable", "not-loaded", "invalid-transport"]

function map() { return Object.create(null) }
function object(value) { return value !== null && typeof value === "object" && !Array.isArray(value) }
function own(value, key) { return Object.prototype.hasOwnProperty.call(value, key) }
function usableKey(value) {
  return typeof value === "string" && value !== "__proto__"
      && value !== "constructor" && value !== "prototype"
}
function validId(value) { return usableKey(value) && /^[a-z][a-z0-9-]{0,31}$/.test(value) }
function count(value) {
  return typeof value === "number" && isFinite(value) && value >= 0
      && Math.floor(value) === value && value <= MAX_REJECTED
}
function result(status, reason, decks, rejected) {
  return { schemaVersion: 1, status: status, reason: reason || "",
           decks: decks || [], rejected: Math.min(MAX_REJECTED, rejected || 0) }
}
function invalid(reason) { return result("invalid", reason, [], 1) }

// Count UTF-8 bytes without encodeURIComponent (hostile lone surrogates throw).
// A lone surrogate is charged the replacement character's three bytes.
function utf8Bytes(text) {
  var bytes = 0
  for (var i = 0; i < text.length; i++) {
    var code = text.charCodeAt(i)
    if (code < 0x80) bytes++
    else if (code < 0x800) bytes += 2
    else if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length
             && text.charCodeAt(i + 1) >= 0xdc00 && text.charCodeAt(i + 1) <= 0xdfff) {
      bytes += 4
      i++
    } else bytes += 3
  }
  return bytes
}

// Shared pure stream boundary for the existing AppConfigSource relay launch.
// No raw parsed record is stored in stream state: the caller validates the
// returned local value before retaining fields. Empty-marker SplitParser is
// essential; a line parser would accumulate an unbounded unterminated record.
function newStream() { return { buffer: "", bytes: 0, received: false, rejected: false } }
function rejectStream(state) { state.buffer = ""; state.rejected = true }
function completeStream(state) { return state.received && !state.rejected && !state.buffer.length }
function consumeStream(state, chunk, maxBytes) {
  if (state.rejected) return null
  var bytes = utf8Bytes(chunk)
  if (state.received || state.bytes + bytes > maxBytes + 1
      || state.buffer.length + chunk.length > maxBytes + 1) {
    rejectStream(state)
    return null
  }
  state.bytes += bytes
  var text = state.buffer + chunk
  var newline = text.indexOf("\n")
  if (newline === -1) { state.buffer = text; return null }
  if (text.slice(newline + 1).length) { rejectStream(state); return null }
  var record
  try { record = JSON.parse(text.slice(0, newline)) }
  catch (error) { rejectStream(state); return null }
  if (!object(record)) { rejectStream(state); return null }
  state.received = true
  state.buffer = ""
  return record
}
function validEnvelope(record, profile, maxBytes) {
  if (!object(record) || !own(record, "schemaVersion") || record.schemaVersion !== 1
      || record.type === "error" || !own(record, "profile") || record.profile !== profile) return false
  try { return utf8Bytes(JSON.stringify(record)) <= maxBytes }
  catch (error) { return false }
}

function safeName(value) {
  if (typeof value !== "string") return ""
  // ECMA-48/ISO-2022 grammar, independently implemented at this boundary.
  // ESC: intermediates 0x20..0x2f, final 0x30..0x7e (not merely @.._).
  // CSI: parameters/intermediates until final 0x40..0x7e. OSC/DCS/SOS/PM/APC
  // strings end at ST; OSC also accepts BEL. CAN/SUB cancel, another ESC
  // restarts a non-string sequence. Malformed bytes remain discarded until a
  // final/cancel; truncated sequences discard to end instead of leaking bytes.
  var text = ""
  var state = "text"
  var intermediate = false
  var stringBel = false
  var stringEscape = false
  for (var at = 0; at < value.length; at++) {
    var char = value[at]
    var byte = value.charCodeAt(at)
    if (state !== "text") {
      if (byte === 0x18 || byte === 0x1a) { state = "text"; continue }
      if (state === "string") {
        if (byte === 0x9c || (stringEscape && char === "\\") || (stringBel && byte === 0x07)) state = "text"
        stringEscape = byte === 0x1b
        continue
      }
      if (byte === 0x1b) { state = "escape"; intermediate = false; continue }
      if (byte === 0x9b) { state = "csi"; continue }
      if ([0x90, 0x98, 0x9d, 0x9e, 0x9f].indexOf(byte) !== -1) {
        state = "string"; stringBel = byte === 0x9d; stringEscape = false; continue
      }
      if (byte <= 0x1f || byte === 0x7f) continue
      if (state === "csi") {
        if (byte >= 0x40 && byte <= 0x7e) state = "text"
      } else if (!intermediate && char === "[") state = "csi"
      else if (!intermediate && "]PX^_".indexOf(char) !== -1) {
        state = "string"; stringBel = char === "]"; stringEscape = false
      } else if (byte >= 0x20 && byte <= 0x2f) intermediate = true
      else if (byte >= 0x30 && byte <= 0x7e) state = "text"
      continue
    }
    if (byte === 0x1b) { state = "escape"; intermediate = false }
    else if (byte === 0x9b) state = "csi"
    else if ([0x90, 0x98, 0x9d, 0x9e, 0x9f].indexOf(byte) !== -1) {
      state = "string"; stringBel = byte === 0x9d; stringEscape = false
    } else text += char
  }
  text = text.replace(/[\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u2028-\u202e\u2066-\u206f]/g, "")
  var clean = ""
  var chars = 0
  for (var i = 0; i < text.length && chars < 48; i++) {
    var code = text.charCodeAt(i)
    if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length
        && text.charCodeAt(i + 1) >= 0xdc00 && text.charCodeAt(i + 1) <= 0xdfff) {
      clean += text[i] + text[++i]
    } else if (code >= 0xd800 && code <= 0xdfff) continue
    else clean += text[i]
    chars++
  }
  return clean
}

function unknownKeys(value, allowed) {
  return Object.keys(value).filter(function(key) { return allowed.indexOf(key) === -1 }).length
}

// The only vocabulary source is the static pack actually loaded by PackSource;
// contexts additionally come from the supply registry, not the reader payload.
function vocabulary(pack, profileContexts) {
  if (!object(pack) || pack.schemaVersion !== 1 || pack.profile !== "lazyvim"
      || !Array.isArray(profileContexts)) return null
  var vocab = map()
  for (var i = 0; i < SEED_KEYS.length; i++) {
    var key = SEED_KEYS[i]
    var values = pack[key]
    if (!Array.isArray(values) || values.length > 128) return null
    var allowed = map()
    for (var j = 0; j < values.length; j++) {
      var value = values[j]
      if (!usableKey(value) || !value.length || value.length > SEED_CHARS[i]
          || /[\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/.test(value)) return null
      if (key !== "contexts" || profileContexts.indexOf(value) !== -1) allowed[value] = true
    }
    vocab[key] = allowed
  }
  return vocab
}

function validate(payload, pack, profileContexts) {
  if (!object(payload)) return invalid("invalid-schema")
  // This also bounds unknown fields before traversing them. The caller must
  // enforce its stream/aggregate budget before JSON.parse; this is a sub-cap.
  try {
    if (utf8Bytes(JSON.stringify(payload)) > MAX_BYTES) return invalid("too-large")
  } catch (error) { return invalid("invalid-schema") }
  if (!own(payload, "schemaVersion") || payload.schemaVersion !== 1
      || !own(payload, "status") || !own(payload, "decks") || !Array.isArray(payload.decks)
      || !own(payload, "rejected") || !count(payload.rejected)
      || !own(payload, "reason") || typeof payload.reason !== "string") return invalid("invalid-schema")
  var rejected = payload.rejected + unknownKeys(payload, ["schemaVersion", "status", "reason", "decks", "rejected"])
  if (payload.status === "absent") {
    if (payload.decks.length || payload.reason !== "" || payload.rejected !== 0) return invalid("invalid-schema")
    return result("absent", "", [], rejected)
  }
  if (payload.status === "invalid") {
    if (REASONS.indexOf(payload.reason) === -1) return invalid("invalid-schema")
    return result("invalid", payload.reason, [], Math.max(1, rejected + payload.decks.length))
  }
  if (payload.status !== "valid" || payload.reason !== "") return invalid("invalid-schema")
  var vocab = vocabulary(pack, profileContexts)
  if (!vocab) return invalid("vocabulary-unavailable")
  var decks = []
  var seen = map()
  rejected += Math.max(0, payload.decks.length - MAX_DECKS)
  for (var d = 0; d < Math.min(payload.decks.length, MAX_DECKS); d++) {
    var item = payload.decks[d]
    if (!object(item)) { rejected++; continue }
    rejected += unknownKeys(item, ["id", "name", "seed"])
    if (!own(item, "id") || !validId(item.id) || seen[item.id]) { rejected++; continue }
    seen[item.id] = true
    var name = own(item, "name") ? safeName(item.name) : ""
    if (!name.trim().length) { rejected++; continue }
    var deck = { id: item.id, name: name }
    if (own(item, "seed") && item.id !== "all") {
      if (!object(item.seed)) { rejected++; continue }
      rejected += unknownKeys(item.seed, SEED_KEYS)
      var seed = map()
      for (var k = 0; k < SEED_KEYS.length; k++) {
        var key = SEED_KEYS[k]
        if (!own(item.seed, key)) continue
        var values = item.seed[key]
        var accepted = []
        var valueSeen = map()
        if (!Array.isArray(values)) rejected++
        else {
          rejected += Math.max(0, values.length - SEED_COUNTS[k])
          for (var v = 0; v < Math.min(values.length, SEED_COUNTS[k]); v++) {
            var value = values[v]
            if (!usableKey(value) || !value.length || value.length > SEED_CHARS[k]
                || !vocab[key][value] || valueSeen[value]) rejected++
            else { valueSeen[value] = true; accepted.push(value) }
          }
        }
        seed[key] = accepted
      }
      deck.seed = seed
    }
    decks.push(deck)
  }
  return result("valid", "", decks, rejected)
}
