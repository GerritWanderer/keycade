.pragma library
.import "Profiles.js" as Profiles
.import "DeckState.js" as DeckState

var DAY_MS = 86400000
var RECENT_LIMIT = 6
var REACTION_LIMIT = 10
var SUCCESSFUL_RUN_LIMIT = 10
var MAX_BINDINGS = 4000
// A binding id is its profile, a separator, and the id that profile's source
// minted. The local part keeps the bound it always had; the prefix adds the
// longest profile name the id pattern allows.
var MAX_LOCAL_ID = 2300
var MAX_BINDING_ID = MAX_LOCAL_ID + 33
// Current declarations are protected; surplus orphan counters are pruned by
// id only once the asynchronous configuration result supplies that context.
var MAX_DECKS = 48
var MAX_COUNTER = 1000000000
// New allocations leave a bounded next-run due target. Legacy sessions may
// already use MAX_COUNTER: they can resume, but can never allocate a successor.
var MAX_NEW_RUN_ID = MAX_COUNTER - 1
var MAX_TIMESTAMP = 9000000000000000
var MAX_REACTION_MS = 600000
var FORBIDDEN_KEYS = ["__proto__", "constructor", "prototype"]

function safeMap() { return Object.create(null) }

function safeKey(value) {
  var key = String(value === undefined || value === null ? "" : value)
  return key && key.length <= MAX_BINDING_ID && FORBIDDEN_KEYS.indexOf(key) === -1 ? key : ""
}

function boundedNumber(value, fallback, minimum, maximum, integer) {
  var number = typeof value === "number" && isFinite(value) ? value : fallback
  number = Math.max(minimum, Math.min(maximum, number))
  return integer ? Math.floor(number) : number
}

function defaults() {
  return {
    schemaVersion: 5,
    runSequence: 0,
    bindings: safeMap(),
    decks: safeMap()
  }
}

// Card history stays global; runs, coverage and celebration belong to a deck.
function freshDeck() {
  return {
    runs: 0,
    coverageCursor: 0,
    totalTrainingMs: 0,
    firstMasteryAt: 0,
    firstMasteryRun: 0,
    firstMasteryCelebrated: false
  }
}

function normalizedDeck(source) {
  var input = source && typeof source === "object" && !Array.isArray(source) ? source : {}
  var item = freshDeck()
  item.runs = boundedNumber(input.runs, 0, 0, MAX_COUNTER, true)
  item.coverageCursor = boundedNumber(input.coverageCursor, 0, 0, MAX_COUNTER, true)
  item.totalTrainingMs = boundedNumber(input.totalTrainingMs, 0, 0, MAX_TIMESTAMP, true)
  item.firstMasteryAt = boundedNumber(input.firstMasteryAt, 0, 0, MAX_TIMESTAMP, true)
  item.firstMasteryRun = boundedNumber(input.firstMasteryRun, 0, 0, MAX_COUNTER, true)
  item.firstMasteryCelebrated = input.firstMasteryCelebrated === true
  // knownTotal/knownMastered are legacy input only. Progress is derived from
  // the current eligible corpus, never persisted as a stale denominator.
  return item
}

// Reading never writes: activeRunId is a QML binding on the stats object, and
// a read that created a record would mutate state from inside a binding.
function counters(stats, deckId) {
  var name = DeckState.validId(deckId) ? deckId : ""
  var map = stats && stats.decks
  if (!name || !map || typeof map !== "object" || Array.isArray(map)) return freshDeck()
  return Object.prototype.hasOwnProperty.call(map, name) ? map[name] : freshDeck()
}

// The live record, created on demand. For the writing side only.
function ensureCounters(stats, deckId) {
  var name = DeckState.validId(deckId) ? deckId : ""
  if (!name) return freshDeck()
  if (!stats.decks || typeof stats.decks !== "object" || Array.isArray(stats.decks))
    stats.decks = safeMap()
  if (!Object.prototype.hasOwnProperty.call(stats.decks, name)) {
    if (Object.keys(stats.decks).length >= MAX_DECKS) return freshDeck()
    stats.decks[name] = freshDeck()
  }
  return stats.decks[name]
}

function runsOf(stats, deckId) {
  return Number(counters(stats, deckId).runs || 0)
}

function validRunId(value) {
  return typeof value === "number" && isFinite(value) && Math.floor(value) === value
      && value >= 1 && value <= MAX_COUNTER
}

// Unlike ordinary display counters, a malformed sequence must never become
// zero and reuse identities. Saturation retains history but refuses training.
function sequenceValue(value) {
  if (value === undefined) return 0
  return typeof value === "number" && isFinite(value) && Math.floor(value) === value
      && value >= 0 && value <= MAX_COUNTER ? value : MAX_COUNTER
}

function runSequenceOf(stats) {
  return stats && DeckState.own(stats, "runSequence") && stats.runSequence !== undefined
      ? sequenceValue(stats.runSequence) : MAX_COUNTER
}

function peekRunIdentity(stats) {
  var sequence = runSequenceOf(stats)
  return sequence < MAX_NEW_RUN_ID ? sequence + 1 : 0
}

// Call exactly once for a NEW session, before scheduling or writing its
// session file. Deck-visible counters do not allocate identities.
function allocateRunIdentity(stats) {
  var identity = peekRunIdentity(stats)
  if (!identity) throw new Error("run-sequence-exhausted")
  stats.runSequence = identity
  return identity
}

// Reserve an interrupted session before publishing store readiness, even if
// the user will abandon it. Resuming repeatedly never allocates another ID.
function adoptRunIdentity(stats, identity) {
  if (!validRunId(identity)) throw new Error("invalid-run-identity")
  var sequence = runSequenceOf(stats)
  stats.runSequence = Math.max(sequence, identity)
  return identity
}

// Seed only legacy LazyVim state. Foreign prefixes/counters are inert, and
// card records are inspected, never rewritten to fit the new identity model.
function initialRunSequence(value) {
  var source = value.schemaVersion === 4 ? value.profiles : value.decks
  var name = value.schemaVersion === 4 ? "lazyvim" : "all"
  var previous = DeckState.object(source) && DeckState.own(source, name) ? source[name] : {}
  if (!DeckState.object(previous)) return MAX_COUNTER
  var sequence = Math.max(sequenceValue(previous.runs), sequenceValue(previous.firstMasteryRun))
  return historyRunSequence(value, sequence, true)
}

function historyRunSequence(value, sequence, includeDue) {
  Object.keys(value.bindings).slice(0, MAX_BINDINGS).forEach(function(id) {
    if (Profiles.profileOf(id) !== "lazyvim" || !safeKey(id)) return
    var item = value.bindings[id] || {}
    sequence = Math.max(sequence, sequenceValue(item.lastSuccessfulRun))
    if (includeDue) sequence = Math.max(sequence, sequenceValue(item.dueRun))
    if (item.successfulRuns !== undefined && !Array.isArray(item.successfulRuns)) sequence = MAX_COUNTER
    var runs = Array.isArray(item.successfulRuns) ? item.successfulRuns : []
    if (runs.length > SUCCESSFUL_RUN_LIMIT) sequence = MAX_COUNTER
    runs.slice(-SUCCESSFUL_RUN_LIMIT).forEach(function(run) { sequence = Math.max(sequence, sequenceValue(run)) })
  })
  return sequence
}

function valid(value) {
  return value && typeof value === "object" && !Array.isArray(value)
      && (value.schemaVersion === 1 || value.schemaVersion === 2
                   || value.schemaVersion === 3 || value.schemaVersion === 4 || value.schemaVersion === 5)
      && value.bindings && typeof value.bindings === "object" && !Array.isArray(value.bindings)
      && (value.schemaVersion !== 5 || DeckState.object(value.decks))
      && (value.schemaVersion !== 4 || value.profiles === undefined || DeckState.object(value.profiles))
}

function freshEntry() {
  return {
    state: "unseen",
    guidedCompleted: false,
    dueAt: 0,
    dueRun: 0,
    intervalStep: 0,
    firstTryAttempts: 0,
    firstTryCorrect: 0,
    recentFirstTry: [],
    reactions: [],
    successfulRuns: [],
    lastSuccessfulRun: 0,
    lastSeenAt: 0,
    lapseCount: 0
  }
}

function normalizedEntry(source) {
  var item = freshEntry()
  var input = source || {}
  item.state = ["unseen", "guided", "learning", "mastered"].indexOf(String(input.state)) !== -1
      ? String(input.state) : "unseen"
  item.guidedCompleted = input.guidedCompleted === true
  item.dueAt = boundedNumber(input.dueAt, 0, 0, MAX_TIMESTAMP, true)
  item.dueRun = boundedNumber(input.dueRun, 0, 0, MAX_COUNTER, true)
  item.intervalStep = boundedNumber(input.intervalStep, 0, 0, 5, true)
  item.firstTryAttempts = boundedNumber(input.firstTryAttempts, 0, 0, MAX_COUNTER, true)
  item.firstTryCorrect = boundedNumber(input.firstTryCorrect, 0, 0, item.firstTryAttempts, true)
  item.recentFirstTry = Array.isArray(input.recentFirstTry)
      ? input.recentFirstTry.slice(-RECENT_LIMIT).map(Boolean) : []
  item.reactions = Array.isArray(input.reactions)
      ? input.reactions.slice(-REACTION_LIMIT).map(function(value) {
          return boundedNumber(value, 0, 0, MAX_REACTION_MS, true)
        }).filter(function(value) { return value > 0 }) : []
  item.successfulRuns = Array.isArray(input.successfulRuns)
      ? input.successfulRuns.slice(-SUCCESSFUL_RUN_LIMIT).map(function(value) {
          return boundedNumber(value, 0, 0, MAX_COUNTER, true)
        }).filter(function(value, index, values) {
          return value > 0 && values.indexOf(value) === index
        }).slice(-SUCCESSFUL_RUN_LIMIT) : []
  item.lastSuccessfulRun = boundedNumber(input.lastSuccessfulRun, 0, 0, MAX_COUNTER, true)
  item.lastSeenAt = boundedNumber(input.lastSeenAt, 0, 0, MAX_TIMESTAMP, true)
  item.lapseCount = boundedNumber(input.lapseCount, 0, 0, MAX_COUNTER, true)
  if (item.state === "learning" && masteryReady(item)) item.state = "mastered"
  if (input.forceGuided === true) item.state = "guided"
  return item
}

function masteryReady(item) {
  var recent = item.recentFirstTry.slice(-2)
  return item.guidedCompleted
      && item.firstTryCorrect >= 2
      && item.successfulRuns.length >= 2
      && recent.length >= 2
      && recent.every(Boolean)
}

// Everything written before training grounds existed came from Hyprland, so
// a migrated id is the old one with that profile in front of it. The local
// part is copied byte for byte: it is what the scheduler and every stored
// exclusion already name, and rewriting it would reset the user's progress.
function legacyKey(rawId) {
  var id = safeKey(rawId)
  // Bound the local part before the prefix goes on, so a long id is migrated
  // rather than dropped for overrunning the qualified bound the prefix made.
  return id && id.length <= MAX_LOCAL_ID
      ? safeKey(Profiles.qualify(Profiles.LEGACY_ID, id)) : ""
}

function migrateV1(value) {
  var migrated = defaults()
  var legacyRuns = boundedNumber(value.runs, 0, 0, MAX_COUNTER, true)
  Object.keys(value.bindings || {}).slice(0, MAX_BINDINGS).forEach(function(rawId) {
    var id = legacyKey(rawId)
    if (!id) return
    var old = value.bindings[rawId] || {}
    var item = freshEntry()
    var attempts = Array.isArray(old.attempts) ? old.attempts.slice(-1000) : []
    var independent = attempts.filter(function(attempt) { return !attempt.guided })
    var correct = independent.filter(function(attempt) { return Boolean(attempt.correct) })
    item.guidedCompleted = boundedNumber(old.guidedHits, 0, 0, MAX_COUNTER, true) > 0
    item.state = old.forceGuided === true ? "guided" : item.guidedCompleted ? "learning" : "unseen"
    item.firstTryAttempts = boundedNumber(
        Math.max(Number(old.hits || 0) + Number(old.misses || 0)
                 - Number(old.guidedHits || 0), independent.length), 0, 0, MAX_COUNTER, true)
    item.firstTryCorrect = boundedNumber(
        Math.max(0, Number(old.hits || 0) - Number(old.guidedHits || 0), correct.length),
        0, 0, item.firstTryAttempts, true)
    item.recentFirstTry = independent.slice(-RECENT_LIMIT).map(function(attempt) { return Boolean(attempt.correct) })
    item.reactions = correct.map(function(attempt) { return Number(attempt.reactionMs || 0) })
        .filter(function(reaction) { return reaction > 0 }).slice(-REACTION_LIMIT)
    item.lastSeenAt = boundedNumber(old.lastSeen, 0, 0, MAX_TIMESTAMP, true)
    item.dueRun = boundedNumber(legacyRuns + 1, 1, 1, MAX_COUNTER, true)
    migrated.bindings[id] = normalizedEntry(item)
  })
  return migrated
}

// Pre-profile counters belonged to retired Hyprland, not LazyVim/all. Drop
// those counters, but qualify every legacy card in its historical namespace.
function migrateLegacy(value) {
  var migrated = defaults()
  Object.keys(value.bindings).slice(0, MAX_BINDINGS).forEach(function(rawId) {
    var id = legacyKey(rawId)
    if (!id) return
    migrated.bindings[id] = normalizedEntry(value.bindings[rawId])
  })
  return migrated
}

function migrateDecks(source, declaredIds) {
  var value = DeckState.object(source) ? source : safeMap()
  var names = Object.keys(value).filter(DeckState.validId)
  var declared = declaredIds === undefined || declaredIds === null
      ? null : DeckState.declaredIds(declaredIds)
  // Reserve space for declarations that have never recorded a run, too: an
  // orphan-filled map must not make ensureCounters return detached defaults
  // for a current deck. Only materialize those defaults under cap pressure.
  var missing = declared ? declared.filter(function(id) { return names.indexOf(id) === -1 }) : []
  // Never guess which records are orphans while config is still in flight.
  // StateStore keeps only a byte-bounded raw file until declarations arrive.
  if (names.length + missing.length > MAX_DECKS) {
    names = names.concat(missing)
    if (!declared) throw new Error("declared-decks-required")
    names.sort(function(left, right) {
      var priority = Number(declared.indexOf(right) !== -1) - Number(declared.indexOf(left) !== -1)
      return priority || (left < right ? -1 : left > right ? 1 : 0)
    })
    names = names.slice(0, MAX_DECKS)
  }
  var result = safeMap()
  names.forEach(function(name) { result[name] = normalizedDeck(value[name]) })
  return result
}

function migrate(value, declaredIds) {
  if (!valid(value)) return defaults()
  if (value.schemaVersion === 1) return migrateV1(value)
  if (value.schemaVersion < 4) return migrateLegacy(value)
  var migrated = defaults()
  if (value.schemaVersion === 4) {
    if (DeckState.object(value.profiles) && DeckState.own(value.profiles, "lazyvim"))
      migrated.decks.all = normalizedDeck(value.profiles.lazyvim)
  } else migrated.decks = migrateDecks(value.decks, declaredIds)
  // Only initialization reads legacy dueRun high-water: thereafter dueRun
  // can mean the NEXT session and must not allocate phantom runs on save.
  migrated.runSequence = value.schemaVersion === 5 && DeckState.own(value, "runSequence")
      ? historyRunSequence(value, runSequenceOf(value), false) : initialRunSequence(value)
  Object.keys(value.bindings).slice(0, MAX_BINDINGS).forEach(function(rawId) {
    // An id with no readable profile in front of it names no training ground
    // that can be loaded, so it is dropped rather than guessed at.
    var id = Profiles.isQualified(rawId) ? safeKey(rawId) : ""
    if (!id) return
    migrated.bindings[id] = normalizedEntry(value.bindings[rawId])
  })
  return migrated
}

function parse(raw, declaredIds) {
  var value
  try {
    value = JSON.parse(String(raw || ""))
  } catch (error) {
    return defaults()
  }
  // A missing declaration context is not corrupt data: let the caller defer
  // rather than replacing valid over-cap history with defaults.
  return migrate(value, declaredIds)
}

function entry(stats, id) {
  var key = safeKey(id)
  if (!key) return freshEntry()
  if (!stats.bindings || typeof stats.bindings !== "object" || Array.isArray(stats.bindings))
    stats.bindings = safeMap()
  if (!stats.bindings[key]) stats.bindings[key] = freshEntry()
  return stats.bindings[key]
}

function percentile75(samples) {
  if (!samples.length) return 0
  var sorted = samples.slice().sort(function(left, right) { return left - right })
  return sorted[Math.max(0, Math.ceil(sorted.length * 0.75) - 1)]
}

function aggregate(stats, bindings) {
  var attempts = 0
  var correct = 0
  var reactions = []
  var seen = safeMap()
  var source = (stats && stats.bindings) || {}
  var ids = bindings ? bindings.map(function(binding) { return binding.id })
                     : Object.keys(source)
  for (var index = 0; index < ids.length; index++) {
    var id = String(ids[index] || "")
    if (!id || seen[id]) continue
    seen[id] = true
    var item = normalizedEntry(source[id])
    attempts += item.firstTryAttempts
    correct += item.firstTryCorrect
    reactions = reactions.concat(item.reactions)
  }
  return {
    attempts: attempts,
    correct: correct,
    accuracy: attempts ? Math.round(correct / attempts * 100) : 0,
    response: percentile75(reactions)
  }
}

function addTrainingTime(stats, deckId, elapsedMs) {
  var record = ensureCounters(stats, deckId)
  var elapsed = boundedNumber(elapsedMs, 0, 0, MAX_TIMESTAMP, true)
  record.totalTrainingMs = boundedNumber(
      Number(record.totalTrainingMs || 0) + elapsed, 0, 0, MAX_TIMESTAMP, true)
  return record.totalTrainingMs
}

function completeRun(stats, deckId) {
  var record = ensureCounters(stats, deckId)
  record.runs = boundedNumber(Number(record.runs || 0) + 1, 0, 0, MAX_COUNTER, true)
  return record.runs
}

// Milestones use the deck-visible run number, never the global identity.
function noteFirstMastery(stats, deckId, now, deckRunNumber) {
  var record = ensureCounters(stats, deckId)
  if (Number(record.firstMasteryAt || 0) > 0) return false
  record.firstMasteryAt = Math.max(1, Number(now || Date.now()))
  record.firstMasteryRun = Math.max(1, Number(deckRunNumber || Number(record.runs || 0) + 1))
  record.firstMasteryCelebrated = false
  return true
}

function markFirstMasteryCelebrated(stats, deckId) {
  var record = ensureCounters(stats, deckId)
  if (!Number(record.firstMasteryAt || 0) || record.firstMasteryCelebrated) return false
  record.firstMasteryCelebrated = true
  return true
}

function metrics(item) {
  var value = item ? normalizedEntry(item) : freshEntry()
  var samples = value.recentFirstTry.length
  var recentCorrect = value.recentFirstTry.filter(Boolean).length
  return {
    samples: samples,
    accuracy: samples ? recentCorrect / samples : 0,
    p75: percentile75(value.reactions),
    totalAttempts: value.firstTryAttempts,
    totalCorrect: value.firstTryCorrect
  }
}

function scheduleNextRun(item, runId) {
  if (!validRunId(runId)) throw new Error("invalid-run-identity")
  if (runId < MAX_COUNTER) {
    item.dueAt = 0
    item.dueRun = runId + 1
  } else {
    // A valid legacy session may already occupy the boundary identity. There
    // is no representable successor; do not wrap or make it due again now.
    item.dueRun = 0
    item.dueAt = MAX_TIMESTAMP
  }
}

function scheduleNext(item, now, runId) {
  if (!validRunId(runId)) throw new Error("invalid-run-identity")
  var intervals = [0, 0, DAY_MS, 3 * DAY_MS, 7 * DAY_MS, 14 * DAY_MS]
  var step = Math.min(item.intervalStep, intervals.length - 1)
  if (step <= 1) {
    scheduleNextRun(item, runId)
  } else {
    item.dueAt = now + intervals[step]
    item.dueRun = 0
  }
}

function recordGuided(stats, id, runId, now) {
  // No profile/deck-counter fallback: callers must pass the session identity.
  var identity = adoptRunIdentity(stats, runId)
  var item = entry(stats, id)
  item.guidedCompleted = true
  item.state = "learning"
  item.lastSeenAt = Number(now || Date.now())
  item.dueAt = 0
  item.dueRun = identity
  return item
}

function recordFirstTry(stats, id, correct, reactionMs, runId, now) {
  var session = adoptRunIdentity(stats, runId)
  var item = entry(stats, id)
  var timestamp = Number(now || Date.now())
  var wasMastered = item.state === "mastered"
  item.firstTryAttempts += 1
  item.recentFirstTry.push(Boolean(correct))
  if (item.recentFirstTry.length > RECENT_LIMIT) item.recentFirstTry = item.recentFirstTry.slice(-RECENT_LIMIT)
  item.lastSeenAt = timestamp

  if (!correct) {
    item.state = "learning"
    item.lapseCount += 1
    item.intervalStep = Math.max(0, item.intervalStep - 1)
    scheduleNextRun(item, session)
    return { item: item, masteredGained: false, lapsed: wasMastered }
  }

  item.firstTryCorrect += 1
  if (Number(reactionMs) >= 0) {
    item.reactions.push(Math.round(Number(reactionMs)))
    if (item.reactions.length > REACTION_LIMIT) item.reactions = item.reactions.slice(-REACTION_LIMIT)
  }
  if (item.lastSuccessfulRun !== session) {
    item.lastSuccessfulRun = session
    item.intervalStep = Math.min(5, item.intervalStep + 1)
    if (item.successfulRuns.indexOf(session) === -1) item.successfulRuns.push(session)
    if (item.successfulRuns.length > 10) item.successfulRuns = item.successfulRuns.slice(-10)
  }

  var mastered = masteryReady(item)
  item.state = mastered || wasMastered ? "mastered" : "learning"
  scheduleNext(item, timestamp, session)
  return { item: item, masteredGained: !wasMastered && item.state === "mastered", lapsed: false }
}

function requestGuidance(stats, id, runId) {
  // A home/summary hint targets the next session without allocating one.
  var identity = runId === undefined ? peekRunIdentity(stats) : runId
  if (!validRunId(identity)) throw new Error("invalid-run-identity")
  var item = entry(stats, id)
  item.state = "guided"
  item.dueAt = 0
  item.dueRun = identity
  return item
}

function isDue(item, now, runId) {
  if (!item || item.state === "unseen" || item.state === "guided" || !validRunId(runId)) return false
  if (Number(item.dueRun || 0) > 0) return runId >= Number(item.dueRun)
  if (Number(item.dueAt || 0) > 0) return Number(now || Date.now()) >= Number(item.dueAt)
  return true
}

function tier(item) {
  if (!item || item.state === "unseen" || item.state === "guided") return "guided"
  return item.state === "mastered" ? "maintenance" : "learning"
}

function counts(stats, bindings, now, runId) {
  var result = { unseen: 0, learning: 0, mastered: 0, due: 0, total: bindings.length }
  for (var index = 0; index < bindings.length; index++) {
    var item = entry(stats, bindings[index].id)
    if (item.state === "unseen" || item.state === "guided") result.unseen += 1
    else if (item.state === "mastered") result.mastered += 1
    else result.learning += 1
    if (isDue(item, now, runId)) result.due += 1
  }
  return result
}
