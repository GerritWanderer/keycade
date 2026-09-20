.pragma library
.import "TextKey.js" as TextKey

// An answer is a sequence of text steps, including a single-step shortcut.
//
//   Answer := { judgeMode: "text", context,
//               steps: [ Step, ... ],                       // 1..MAX_STEPS
//               alternates: [ [ Step, ... ], ... ] }         // 0..MAX_ALTERNATES
//   Step := { mods, text | named }                          // see TextKey.js
//
// No fallback judge: missing, retired or unknown modes fail closed rather
// than reinterpreting keysym/physical data as text.

var MAX_STEPS = 8
// One action, several ways to reach it: D and d$, S and cc. A card shows the
// first and accepts any of them, because refusing a spelling the application
// accepts would be teaching something untrue.
var MAX_ALTERNATES = 4

// A model's value reaches a delegate through QML's variant conversion, and an
// array that has made that trip no longer answers to Array.isArray - it is
// array-like, not an Array. Insisting on the type dropped every step, so the
// drawer of set-aside shortcuts listed descriptions with an empty column
// where the keys should have been. Take anything with a length, and bound it
// here as before.
function safeSteps(answer) {
  var steps = judgeMode(answer) === "text" ? answer.steps : null
  var length = steps && typeof steps.length === "number" ? Math.floor(steps.length) : 0
  var count = Math.max(0, Math.min(length, MAX_STEPS))
  var result = []
  for (var index = 0; index < count; index++) {
    if (steps[index]) result.push(steps[index])
  }
  return result
}

function stepCount(answer) {
  return safeSteps(answer).length
}

function judgeMode(answer) {
  return answer && answer.judgeMode === "text" ? "text" : ""
}

// A sequence is typed, not held: the matcher carries only how far the typing
// has got. There is deliberately no per-step deadline - Vim has `timeoutlen`,
// but copying it here would only punish the beginner this is for. The card's
// own deadline still covers the whole sequence.
// One cursor per accepted answer. They advance together on a shared key
// press; a candidate that diverges is out, and the card is answered by
// whichever finishes first.
function begin() { return { cursors: null } }

function alternates(answer) {
  var list = judgeMode(answer) === "text" ? answer.alternates : null
  var length = list && typeof list.length === "number" ? Math.floor(list.length) : 0
  var result = []
  for (var index = 0; index < Math.min(Math.max(0, length), MAX_ALTERNATES); index++) {
    if (list[index]) result.push(list[index])
  }
  return result
}

// Every sequence this card accepts, the shown one first.
function candidates(answer) {
  var all = [safeSteps(answer)]
  var extra = alternates(answer)
  for (var index = 0; index < extra.length; index++) {
    var steps = safeSteps({ judgeMode: "text", steps: extra[index] })
    if (steps.length) all.push(steps)
  }
  return all.filter(function(steps) { return steps.length > 0 })
}

function normalizeInput(answer, event) {
  return judgeMode(answer) === "text" ? TextKey.normalizeEvent(event) : null
}

function stepMatches(answer, step, input) {
  return judgeMode(answer) === "text" && TextKey.matches(step, input)
}

// One key press against the answer, with autorepeat and bare modifiers already
// filtered out by the caller.
//
//   "hit"      the last step landed; the card is answered
//   "progress" a step landed and more remain
//   "miss"     the card is wrong, whole - see the note in advance()
//
// A wrong key fails the entire card rather than the step: correcting a
// sequence means typing it again from the start, which is also how the muscle
// memory for one is actually built.
function advance(state, answer, event) {
  var all = candidates(answer)
  if (!all.length) { state.cursors = null; return "miss" }
  if (!state.cursors || state.cursors.length !== all.length) {
    state.cursors = []
    for (var reset = 0; reset < all.length; reset++) state.cursors.push(0)
  }
  var input = normalizeInput(answer, event)
  var alive = 0
  var hit = false
  for (var index = 0; index < all.length; index++) {
    var cursor = state.cursors[index]
    if (cursor < 0) continue
    var steps = all[index]
    if (!stepMatches(answer, steps[cursor], input)) {
      state.cursors[index] = -1
      continue
    }
    if (cursor + 1 >= steps.length) hit = true
    else { state.cursors[index] = cursor + 1; alive += 1 }
  }
  if (hit) { state.cursors = null; return "hit" }
  if (alive) return "progress"
  state.cursors = null
  return "miss"
}

// How far the shown answer has been typed, for the card to light up.
function typedSteps(state) {
  return state && state.cursors && state.cursors.length && state.cursors[0] > 0
      ? state.cursors[0] : 0
}

// A completed sequence is a hit even when a longer answer starts the same way:
// the card asked for `gc`, and `gc` is what it gets. The extra keystroke a
// user with `gcc` in their fingers then sends has to be swallowed before the
// next card can see it, which is what the overrun guard in Keycade.qml is for.
function overruns(answer) {
  var all = candidates(answer)
  for (var index = 0; index < all.length; index++) {
    if (all[index].length > 1) return true
  }
  return false
}

// The other ways in, as key-cap groups, for the card to name below the
// answer it is showing.
function alternateLabels(answer) {
  var extra = alternates(answer)
  var labels = []
  for (var index = 0; index < extra.length; index++) {
    var groups = stepLabels({ judgeMode: judgeMode(answer), steps: extra[index] })
    if (groups.length)
      labels.push(groups.map(function(keys) { return keys.join(" + ") }).join(" › "))
  }
  return labels
}

// What the card shows: one group of key caps per step.
function stepLabels(answer) {
  var steps = safeSteps(answer)
  var groups = []
  for (var index = 0; index < steps.length; index++) {
    groups.push(TextKey.labels(steps[index]))
  }
  return groups
}

// What an unmatched key press reads as in the feedback line.
function inputDisplay(answer, event) {
  if (judgeMode(answer) === "text")
    return TextKey.inputLabels(TextKey.normalizeEvent(event)).join(" ")
  return ""
}
