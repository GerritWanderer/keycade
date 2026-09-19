.pragma library
.import "Stats.js" as Stats
.import "Session.js" as Session
.import "DeckState.js" as DeckState
.import "AnswerMatcher.js" as AnswerMatcher

var QUEUE_PRIORITY = { due: 0, unseen: 1, weak: 2, maintenance: 3 }

function stableBindings(bindings) {
  var seen = Object.create(null)
  return bindings.filter(function(binding) {
    if (!binding || !DeckState.validCardId(binding.id) || seen[binding.id]) return false
    seen[binding.id] = true
    return true
  }).sort(function(left, right) {
    return String(left.id).localeCompare(String(right.id))
  })
}

// Coverage is a deck property, never inferred from the corpus namespace.
function coverageOrder(bindings, stats, deckId) {
  var ordered = stableBindings(bindings)
  if (!ordered.length) return []
  var cursor = Number(Stats.counters(stats, deckId).coverageCursor || 0) % ordered.length
  return ordered.slice(cursor).concat(ordered.slice(0, cursor))
}

function dueSort(left, right, stats) {
  var leftItem = Stats.readEntry(stats, left.id)
  var rightItem = Stats.readEntry(stats, right.id)
  if (leftItem.state !== rightItem.state) return leftItem.state === "learning" ? -1 : 1
  var leftDue = Number(leftItem.dueAt || 0)
  var rightDue = Number(rightItem.dueAt || 0)
  if (leftDue !== rightDue) return leftDue - rightDue
  return String(left.id).localeCompare(String(right.id))
}

function weakSort(left, right, stats) {
  var leftItem = Stats.readEntry(stats, left.id)
  var rightItem = Stats.readEntry(stats, right.id)
  if (leftItem.lapseCount !== rightItem.lapseCount) return rightItem.lapseCount - leftItem.lapseCount
  var leftAccuracy = Stats.metrics(leftItem).accuracy
  var rightAccuracy = Stats.metrics(rightItem).accuracy
  if (leftAccuracy !== rightAccuracy) return leftAccuracy - rightAccuracy
  if (leftItem.lastSeenAt !== rightItem.lastSeenAt) return leftItem.lastSeenAt - rightItem.lastSeenAt
  return String(left.id).localeCompare(String(right.id))
}

function queuePools(bindings, stats, now, runId, deckId) {
  var pools = { due: [], unseen: [], weak: [], maintenance: [] }
  var ordered = stableBindings(bindings)
  for (var index = 0; index < ordered.length; index++) {
    var binding = ordered[index]
    var item = Stats.readEntry(stats, binding.id)
    if (item.state === "unseen" || item.state === "guided") continue
    if (Stats.isDue(item, now, runId)) pools.due.push(binding)
    else if (item.state === "learning") pools.weak.push(binding)
    else pools.maintenance.push(binding)
  }
  pools.due.sort(function(left, right) { return dueSort(left, right, stats) })
  pools.weak.sort(function(left, right) { return weakSort(left, right, stats) })
  pools.maintenance.sort(function(left, right) {
    var age = Stats.readEntry(stats, left.id).lastSeenAt - Stats.readEntry(stats, right.id).lastSeenAt
    return age || String(left.id).localeCompare(String(right.id))
  })
  pools.unseen = coverageOrder(bindings, stats, deckId).filter(function(binding) {
    var state = Stats.readEntry(stats, binding.id).state
    return state === "unseen" || state === "guided"
  })
  return pools
}

function card(binding, queue, stats) {
  return { binding: binding, tier: Stats.tier(Stats.readEntry(stats, binding.id)), queue: queue, remedial: false }
}

function takeUnique(target, pool, count, queue, stats, selected) {
  var amount = 0
  for (var index = 0; index < pool.length && amount < count; index++) {
    if (selected[pool[index].id]) continue
    selected[pool[index].id] = true
    target.push(card(pool[index], queue, stats))
    amount++
  }
  return amount
}

function markCovered(bindings, stats, bindingId, deckId) {
  if (!bindings.length || !bindingId || !DeckState.validId(deckId)) return
  var ordered = stableBindings(bindings)
  for (var index = 0; index < ordered.length; index++) {
    if (ordered[index].id === bindingId) {
      Stats.ensureCounters(stats, deckId).coverageCursor =
          (index + 1) % ordered.length
      return
    }
  }
}

function arrange(cards) {
  var remaining = cards.slice()
  var arranged = []
  var usage = Object.create(null)
  var categoryCounts = Object.create(null)
  while (remaining.length) {
    var previousId = arranged.length ? arranged[arranged.length - 1].binding.id : ""
    var bestIndex = -1
    var bestScore = Infinity
    for (var index = 0; index < remaining.length; index++) {
      var candidate = remaining[index]
      var id = candidate.binding.id
      if (id === previousId) continue
      var category = String(candidate.binding.category || "uncategorized")
      var score = Number(usage[id] || 0) * 100
                + Number(categoryCounts[category] || 0) * 10
                + Number(QUEUE_PRIORITY[candidate.queue] || 0)
      if (score < bestScore) { bestIndex = index; bestScore = score }
    }
    if (bestIndex < 0) {
      for (var fallback = 0; fallback < remaining.length; fallback++) {
        if (remaining[fallback].binding.id !== previousId) { bestIndex = fallback; break }
      }
    }
    if (bestIndex < 0) bestIndex = 0
    var chosen = remaining.splice(bestIndex, 1)[0]
    arranged.push(chosen)
    var chosenId = chosen.binding.id
    var chosenCategory = String(chosen.binding.category || "uncategorized")
    usage[chosenId] = Number(usage[chosenId] || 0) + 1
    categoryCounts[chosenCategory] = Number(categoryCounts[chosenCategory] || 0) + 1
  }
  return arranged
}

function allocation(size) {
  var unseen = Math.floor(size * 6 / 24)
  var weak = Math.floor(size * 6 / 24)
  var maintenance = Math.floor(size * 2 / 24)
  return { due: size - unseen - weak - maintenance,
           unseen: unseen, weak: weak, maintenance: maintenance }
}

function build(bindings, stats, cardCount, options) {
  var unique = stableBindings(bindings)
  var limit = cardCount === undefined ? Session.MAX_CARDS : Number(cardCount)
  var total = Math.min(Session.MAX_CARDS, unique.length, Math.max(0, Math.floor(limit)))
  var deck = []
  if (!total || !isFinite(total)) return deck
  var config = options || {}
  var now = config.now === undefined ? Date.now() : Number(config.now)
  // Preview is read-only, and exhaustion is not silently turned into run 1.
  var runId = config.runId === undefined ? Stats.peekRunIdentity(stats) : config.runId
  var pools = queuePools(unique, stats, now, runId, config.deckId)
  var shares = allocation(total)
  var selected = Object.create(null)
  var names = ["due", "unseen", "weak", "maintenance"]
  names.forEach(function(name) {
    takeUnique(deck, pools[name], shares[name], name, stats, selected)
  })
  // Exhausted shares go to due first, then the other available UNIQUE cards.
  names.forEach(function(name) {
    takeUnique(deck, pools[name], total - deck.length, name, stats, selected)
  })
  return arrange(deck)
}

function planCounts(deck) {
  var newBindings = Object.create(null)
  var reviewBindings = Object.create(null)
  for (var index = 0; index < (deck || []).length; index++) {
    var cardValue = deck[index]
    if (!cardValue || !cardValue.binding) continue
    if (cardValue.queue === "unseen" && cardValue.tier === "guided")
      newBindings[cardValue.binding.id] = true
    else reviewBindings[cardValue.binding.id] = true
  }
  return {
    added: Object.keys(newBindings).length,
    review: Object.keys(reviewBindings).length
  }
}

// A longer answer takes longer to type, and the clamps were chosen for one
// chord. The extra per step is added outside them so a four-step sequence is
// not held to a single chord's ceiling. p75 measures the whole sequence, so
// the statistics need no notion of steps at all.
function durationFor(cardValue, stats) {
  if (!cardValue || cardValue.tier === "guided") return 0
  var metrics = Stats.metrics(stats.bindings[cardValue.binding.id])
  var extraSteps = Math.max(0, AnswerMatcher.stepCount(cardValue.binding.answer) - 1)
  if (cardValue.tier === "maintenance")
    return Math.max(2600, Math.min(4000, metrics.p75 ? metrics.p75 * 1.45 : 3600)) + 600 * extraSteps
  return Math.max(3500, Math.min(5000, metrics.p75 ? metrics.p75 * 1.7 : 4500)) + 800 * extraSteps
}

function insertRemedial(deck, currentIndex, binding) {
  var updated = deck.slice()
  var existingIndex = -1
  for (var index = currentIndex + 1; index < updated.length; index++) {
    if (updated[index].remedial && updated[index].binding.id === binding.id) {
      existingIndex = index
      break
    }
  }
  if (existingIndex >= currentIndex + 4 && existingIndex <= currentIndex + 6) return updated

  var start = currentIndex + 4
  var end = Math.min(currentIndex + 6, updated.length - 1)
  if (start > end) return updated

  var replacePriority = { maintenance: 4, weak: 3, unseen: 2, due: 1 }
  var replaceIndex = -1
  var bestPriority = -1
  for (var candidateIndex = start; candidateIndex <= end; candidateIndex++) {
    var candidate = updated[candidateIndex]
    if (candidate.remedial) continue
    var priority = Number(replacePriority[candidate.queue] || 0)
    if (priority > bestPriority) {
      replaceIndex = candidateIndex
      bestPriority = priority
    }
  }
  if (replaceIndex < 0) return updated

  var displaced = updated[replaceIndex]
  updated[replaceIndex] = {
    binding: binding,
    tier: "learning",
    queue: "remedial",
    remedial: true
  }
  if (existingIndex >= 0) updated[existingIndex] = displaced
  return updated
}
