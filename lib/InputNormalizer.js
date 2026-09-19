.pragma library

// InputGuard tracks every held modifier, including Shift, even though text
// judging handles a character's Shift through event.text. Keep that UI/safety
// boundary separate from TextKey; no key translation or judging lives here.
var SHIFT = 1
var CTRL = 4
var ALT = 8
var SUPER = 64

function modifierMask(qtModifiers) {
  var value = Number(qtModifiers || 0)
  var mask = 0
  if (value & 0x02000000) mask |= SHIFT
  if (value & 0x04000000) mask |= CTRL
  if (value & 0x08000000) mask |= ALT
  if (value & 0x10000000) mask |= SUPER
  return mask
}

// Bare modifier presses do not advance (or fail) a text sequence. Use Qt's
// key identity solely for this input filter, never as a character or keycode.
function isModifier(qtKey) {
  var key = Number(qtKey || 0)
  return key === 0x01000020 || key === 0x01000021
      || key === 0x01000022 || key === 0x01000023
}
