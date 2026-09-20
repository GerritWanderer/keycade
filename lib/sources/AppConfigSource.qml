import QtQuick
import Quickshell
import Quickshell.Io
import "../Profiles.js" as Profiles
import "../Packs.js" as Packs
import "../DeckValidation.js" as DeckValidation

// What a training ground's own configuration says about itself: which key
// every other binding hangs off, which opt-in bundles are on, which upstream
// version is installed.
//
// The shipped table stays the authority for *what* the bindings are. This only
// says how they were *changed*, and only from shapes that can be read without
// interpreting anything - see bin/app-config-json for the contract and the
// list of files, which is written out there in full.
//
// Reading nothing is a normal outcome, not a failure: no configuration, an
// unreadable one, or a value set in a shape the helper will not guess at all
// end here with the shipped defaults and a note saying so.
Item {
  id: root

  // Absolute interpreter and helper paths plus a rebuilt child environment
  // keep this long-lived component from resolving anything through PATH.
  readonly property string interpreterPath: "/usr/bin/python3"
  readonly property string relayPath: String(Qt.resolvedUrl("../../bin/bounded-relay")).replace("file://", "")
  readonly property string helperPath: String(Qt.resolvedUrl("../../bin/app-config-json")).replace("file://", "")
  readonly property int relayMaxBytes: 512 * 1024
  readonly property real relayDeadline: 3.0
  readonly property int maxPayloadBytes: 256 * 1024
  readonly property int maxExtras: 128
  readonly property int maxBindings: 128
  readonly property int maxOptionChars: 32

  property string profileId: ""

  // What the machine said. Empty until a read succeeds, and empty again if it
  // fails - a stale answer from another ground would be worse than none.
  property var options: Object.create(null)
  property var extras: []
  // Literal top-level vim.keymap.set/del calls, still in source order. The
  // pack loader applies them over the shipped LazyVim table.
  property var bindings: []
  property int bindingSkipped: 0
  // A fresh consumer-owned result, not a retained helper object. The later
  // engine chooses starters for absent, all-only for invalid, and replaces
  // starters for valid (including an empty list). No deck evaluation here.
  property var deckConfig: DeckValidation.invalid("not-loaded")
  property var inputState: DeckValidation.newStream()
  // Why a value is missing, by name: "never assigned" means the upstream
  // default applies and nothing needs attention, anything else means the
  // reader should look.
  property var skipped: Object.create(null)
  property bool loading: false
  property bool settled: false
  // A second ground picked while the first is still being read must not be
  // dropped: the request is remembered and run once the reader is down.
  property bool pending: false

  signal finished()

  function reset() {
    root.options = Object.create(null)
    root.extras = []
    root.bindings = []
    root.bindingSkipped = 0
    root.deckConfig = DeckValidation.invalid("not-loaded")
    root.inputState = DeckValidation.newStream()
    root.skipped = Object.create(null)
    root.settled = false
  }

  // A ground with nothing to read is answered immediately: only the ground
  // whose configuration this helper knows the shape of is asked.
  function readable() {
    return root.profileId === "lazyvim"
  }

  function refresh() {
    root.reset()
    if (!root.readable()) {
      root.settled = true
      root.finished()
      return
    }
    if (reader.running) {
      root.pending = true
      reader.signal(15)
      return
    }
    root.loading = true
    readTimeout.restart()
    reader.running = true
  }

  function safeText(value, limit) {
    var text = String(value === undefined || value === null ? "" : value)
    if (!text.length || text.length > limit) return ""
    return text.replace(/[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, " ")
  }

  function safeOption(value) {
    var text = String(value === undefined || value === null ? "" : value)
    if (!text.length || text.length > root.maxOptionChars) return ""
    return /[\u0000-\u001f\u007f]/.test(text) ? "" : text
  }

  // Bounded again on this side. The helper checks its own output; that it did
  // is not something this side can verify.
  function accept(record) {
    // Even direct callers must pass the same envelope and aggregate byte cap.
    if (!DeckValidation.validEnvelope(record, root.profileId, root.maxPayloadBytes)) return false
    var deckConfig = DeckValidation.validate(record.deckConfig, Packs.pack("lazyvim"), Profiles.contexts("lazyvim"))
    var declared = Object.keys(Profiles.options(root.profileId))
    var options = Object.create(null)
    var source = record.options && typeof record.options === "object"
        && !Array.isArray(record.options) ? record.options : ({})
    for (var index = 0; index < declared.length; index++) {
      var value = root.safeOption(source[declared[index]])
      if (value) options[declared[index]] = value
    }

    var extras = []
    if (Array.isArray(record.extras)) {
      for (var extra = 0; extra < record.extras.length && extras.length < root.maxExtras; extra++) {
        var name = String(record.extras[extra] || "")
        if (/^[A-Za-z0-9_.\-]{1,128}$/.test(name) && extras.indexOf(name) === -1)
          extras.push(name)
      }
    }

    var skipped = Object.create(null)
    var reasons = record.skipped && typeof record.skipped === "object"
        && !Array.isArray(record.skipped) ? record.skipped : ({})
    var forbidden = ["__proto__", "constructor", "prototype"]
    Object.keys(reasons).slice(0, 16).forEach(function(name) {
      if (/^[A-Za-z0-9_\-]{1,32}$/.test(name) && forbidden.indexOf(name) === -1)
        skipped[name] = root.safeText(reasons[name], 128)
    })

    root.options = options
    root.extras = extras
    var bindings = []
    var rejectedBindings = 0
    if (root.profileId === "lazyvim" && Array.isArray(record.bindings)) {
      var bindingLimit = Math.min(record.bindings.length, root.maxBindings)
      for (var binding = 0; binding < bindingLimit; binding++) {
        var item = record.bindings[binding]
        if (!item || typeof item !== "object" || Array.isArray(item)) {
          rejectedBindings += 1
          continue
        }
        var op = String(item.op || "")
        var lhs = String(item.lhs || "")
        if ((op !== "set" && op !== "del") || !lhs.length || lhs.length > 128
            || /[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/.test(lhs)) {
          rejectedBindings += 1
          continue
        }
        var desc = op === "set" ? root.safeText(item.desc, 512).trim() : ""
        if (op === "set" && !desc.length) {
          rejectedBindings += 1
          continue
        }
        if (!Array.isArray(item.contexts) || !item.contexts.length || item.contexts.length > 4) {
          rejectedBindings += 1
          continue
        }
        var contexts = []
        for (var context = 0; context < item.contexts.length; context++) {
          var name = String(item.contexts[context] || "")
          if (Profiles.contexts(root.profileId).indexOf(name) !== -1
              && contexts.indexOf(name) === -1) contexts.push(name)
        }
        if (contexts.length)
          bindings.push({ op: op, lhs: lhs, desc: desc, contexts: contexts })
        else rejectedBindings += 1
      }
      rejectedBindings += Math.max(0, record.bindings.length - bindingLimit)
    }
    var bindingSkipped = 0
    var bindingReasons = record.bindingSkipped && typeof record.bindingSkipped === "object"
        && !Array.isArray(record.bindingSkipped) ? record.bindingSkipped : ({})
    Object.keys(bindingReasons).slice(0, 16).forEach(function(reason) {
      if (forbidden.indexOf(reason) !== -1) return
      var count = Number(bindingReasons[reason] || 0)
      if (isFinite(count)) bindingSkipped += Math.max(0, Math.min(100000, Math.floor(count)))
    })
    root.bindings = bindings
    root.bindingSkipped = bindingSkipped + rejectedBindings
    root.skipped = skipped
    root.deckConfig = deckConfig
    return true
  }

  function rejectTransport() {
    root.options = Object.create(null)
    root.extras = []
    root.bindings = []
    root.bindingSkipped = 0
    root.skipped = Object.create(null)
    root.deckConfig = DeckValidation.invalid("invalid-transport")
    DeckValidation.rejectStream(root.inputState)
    if (reader.running) reader.signal(15)
  }

  function consume(chunk) {
    if (root.settled || root.inputState.rejected) return
    // Check aggregate bytes BEFORE retaining a chunk (R2/R8). The helper emits
    // ASCII JSON escapes so a UTF-8 code point cannot straddle Qt chunks.
    var record = DeckValidation.consumeStream(root.inputState, chunk, root.maxPayloadBytes)
    if (root.inputState.rejected) { root.rejectTransport(); return }
    try {
      if (record !== null && !root.accept(record)) root.rejectTransport()
    } catch (error) {
      // Malformed calibration fields must not prevent the deck fallback (or
      // training) just because a hostile value cannot be converted to text.
      root.rejectTransport()
    }
  }

  function settle() {
    if (root.settled) return
    if (!DeckValidation.completeStream(root.inputState)) root.rejectTransport()
    root.settled = true
    root.loading = false
    readTimeout.stop()
    root.finished()
  }

  Process {
    id: reader
    command: [
      root.interpreterPath, root.relayPath,
      "--max-bytes", String(root.relayMaxBytes),
      "--deadline", String(root.relayDeadline),
      "--", root.interpreterPath, root.helperPath, "--profile", root.profileId
    ]
    clearEnvironment: true
    // Fixed whitelist only; the helper validates the absolute XDG anchor and
    // descriptor-traverses it without following links. No ambient interpreter
    // or module-search environment is forwarded.
    Component.onCompleted: reader.environment = ({ "PATH": "/usr/bin", "HOME": Quickshell.env("HOME") || "",
                                                   "XDG_CONFIG_HOME": Quickshell.env("XDG_CONFIG_HOME") || "" })
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root.consume(chunk) }
    }
    onExited: {
      if (root.pending) {
        root.pending = false
        root.refresh()
        return
      }
      root.settle()
    }
  }

  Timer {
    id: readTimeout
    interval: 4000
    repeat: false
    onTriggered: {
      if (reader.running) reader.signal(15)
      root.settle()
    }
  }

  Component.onDestruction: if (reader.running) { reader.signal(15); reader.signal(9) }
}
