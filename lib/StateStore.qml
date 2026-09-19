import QtQuick
import Quickshell
import Quickshell.Io
import "Stats.js" as Stats
import "Session.js" as Session
import "Palettes.js" as Palettes
import "DeckState.js" as DeckState

Item {
  id: root

  // Absolute interpreter and helper paths plus a rebuilt child environment
  // keep this long-lived component from resolving anything through PATH.
  readonly property string interpreterPath: "/usr/bin/python3"
  // A relay spawned by this consumer caps what can reach the parser.
  // Quickshell exposes no parser buffer limit, so a child that never
  // emits the split marker would otherwise be retained in full before
  // any budget here could run. The limit is chosen and enforced
  // outside the process that produces the data.
  readonly property string relayPath: String(Qt.resolvedUrl("../bin/bounded-relay")).replace("file://", "")
  readonly property int relayMaxBytes: 6 * 1024 * 1024
  readonly property real relayDeadline: 4.0
  readonly property string helperPath: String(Qt.resolvedUrl("../bin/state-store")).replace("file://", "")
  readonly property int maxResponseChars: 6 * 1024 * 1024
  readonly property int maxRecordChars: 128 * 1024
  readonly property int maxRecords: 4096
  readonly property int maxQueuedOperations: 16
  readonly property var fileLimits: ({ stats: 2 * 1024 * 1024, settings: 64 * 1024, session: 512 * 1024 })

  // Incremental load state; the budget is enforced per record while reading.
  property var loadFiles: null
  property string loadKind: ""
  property int loadChunksLeft: 0
  property int streamChars: 0
  property int streamRecords: 0
  property bool streamComplete: false

  property var stats: Stats.defaults()
  property var settings: defaultSettings()
  property var session: null
  property bool ready: false
  // Declaration context is asynchronous. Keep only the bounded raw stats
  // text until it arrives; never prune or write an assumed all-only view.
  property var declaredDeckIds: null
  property var pendingStatsRaw: null
  property bool statsSavePending: false
  property bool runIdentityPrepared: false
  property string deckCardsRefusal: ""
  property bool statsLoaded: false
  property bool settingsLoaded: false
  property bool sessionLoaded: false
  property bool statsCorrupt: false
  property bool settingsCorrupt: false
  property bool sessionCorrupt: false
  property string error: ""
  property var operations: []
  property var currentOperation: null
  property string operationOutput: ""
  property bool operationTimedOut: false

  signal failed(string message)
  signal deckCardsRefused(string reason)

  function defaultSettings() {
    return {
      schemaVersion: 4,
      locale: "en",
      theme: Palettes.defaultName(),
      reducedMotion: false,
      feedbackSound: true,
      countdownSound: true,
      soundVolume: 0.4,
      excludedBindings: [],
      activeDeck: "all",
      deckCards: DeckState.map()
    }
  }

  function finiteNumber(value, fallback, minimum, maximum) {
    var number = typeof value === "number" && isFinite(value) ? value : fallback
    return Math.max(minimum, Math.min(maximum, number))
  }

  function normalizedSettings(value) {
    var source = value && typeof value === "object" && !Array.isArray(value) ? value : {}
    var result = root.defaultSettings()
    result.locale = ["en", "zh-CN"].indexOf(String(source.locale || "")) !== -1
        ? String(source.locale) : "en"
    result.theme = Palettes.supported(source.theme) ? String(source.theme) : Palettes.defaultName()
    result.reducedMotion = source.reducedMotion === true
    result.feedbackSound = source.feedbackSound === undefined
        ? (source.soundEnabled === undefined ? true : source.soundEnabled === true)
        : source.feedbackSound === true
    result.countdownSound = source.countdownSound === undefined ? true : source.countdownSound === true
    result.soundVolume = root.finiteNumber(source.soundVolume, 0.4, 0, 1)
    // Exclusions remain profile:localId, including retired namespaces (D10).
    result.excludedBindings = Session.excludedList(source.excludedBindings)
    result.activeDeck = source.schemaVersion === 4 && DeckState.validId(source.activeDeck)
        ? source.activeDeck : "all"
    result.deckCards = source.schemaVersion === 4
        ? DeckState.normalize(source.deckCards) : DeckState.map()
    if (Number(source.schemaVersion) === 2 && Math.abs(result.soundVolume - 0.3) < 0.001)
      result.soundVolume = 0.4
    return result
  }

  function updateReady() {
    var loaded = root.statsLoaded && root.settingsLoaded && root.sessionLoaded
    if (loaded && !root.error && !root.runIdentityPrepared) {
      try {
        var before = root.stats.runSequence
        // Session.runId remains the persisted numeric identity. Reserve even
        // an unresumable/abandoned legacy LazyVim session, never a foreign one.
        if (root.session && root.session.profileId === "lazyvim")
          Stats.adoptRunIdentity(root.stats, root.session.runId)
        root.runIdentityPrepared = true
        if (before !== root.stats.runSequence) {
          root.stats = Object.assign({}, root.stats)
          root.statsSavePending = true
        }
      } catch (identityError) {
        root.fail("Run identity is invalid or exhausted")
      }
    }
    root.ready = loaded && root.runIdentityPrepared && !root.error
    if (root.ready && root.statsSavePending) Qt.callLater(function() { root.saveStats() })
  }

  function setDeclaredDeckIds(ids) {
    // This interface consumes the final config result, not a temporary loading
    // fallback. Invalid IDs cannot replace a previously accepted declaration.
    var declared = DeckState.declaredIds(ids)
    root.declaredDeckIds = declared
    if (root.pendingStatsRaw !== null) {
      var raw = root.pendingStatsRaw
      root.pendingStatsRaw = null
      root.loadStats(raw)
    } else if (root.statsLoaded) {
      var reconciled = Stats.migrate(root.stats, declared)
      if (JSON.stringify(reconciled) !== JSON.stringify(root.stats)) {
        root.stats = reconciled
        root.statsSavePending = true
      }
    }
    if (root.statsSavePending && root.statsLoaded) root.saveStats()
  }

  function loadStats(raw) {
    var text = String(raw || "").trim()
    if (DeckState.utf8Bytes(text) > root.fileLimits.stats) {
      root.fail("stats state exceeded its limit")
      return
    }
    if (root.declaredDeckIds === null) {
      root.pendingStatsRaw = text
      return
    }
    if (!text) {
      root.stats = Stats.defaults()
      root.statsCorrupt = false
    } else {
      try {
        var value = JSON.parse(text)
        if (!Stats.valid(value)) throw new Error("unsupported stats schema")
        var previousSchema = Number(value.schemaVersion || 0)
        root.stats = Stats.migrate(value, root.declaredDeckIds)
        root.statsCorrupt = false
        if (previousSchema !== root.stats.schemaVersion
            || JSON.stringify(value) !== JSON.stringify(root.stats))
          Qt.callLater(function() { root.saveStats() })
      } catch (loadError) {
        root.stats = Stats.defaults()
        root.statsCorrupt = true
        root.enqueue({ action: "quarantine", kind: "stats" })
        console.warn("Keycade stats were rejected and queued for quarantine")
      }
    }
    root.statsLoaded = true
    root.updateReady()
    if (root.statsSavePending) Qt.callLater(function() { root.saveStats() })
  }

  function loadSettings(raw) {
    var text = String(raw || "").trim()
    if (!text) {
      root.settings = root.defaultSettings()
      root.settingsCorrupt = false
    } else {
      try {
        var value = JSON.parse(text)
        if (!value || typeof value !== "object" || Array.isArray(value)
            || [1, 2, 3, 4].indexOf(value.schemaVersion) === -1
            || DeckState.utf8Bytes(text) > root.fileLimits.settings)
          throw new Error("unsupported settings schema")
        var previousSchema = Number(value.schemaVersion)
        root.settings = root.normalizedSettings(value)
        root.settingsCorrupt = false
        // profileOptions was a short-lived manual override. It is ignored by
        // normalizedSettings and removed from disk so a stale value can never
        // mask configuration detected later.
        if (previousSchema !== root.settings.schemaVersion
            || Object.prototype.hasOwnProperty.call(value, "profileOptions")
            || Object.prototype.hasOwnProperty.call(value, "activeProfile"))
          Qt.callLater(function() { root.saveSettings() })
      } catch (loadError) {
        root.settings = root.defaultSettings()
        root.settingsCorrupt = true
        root.enqueue({ action: "quarantine", kind: "settings" })
        console.warn("Keycade settings were rejected and queued for quarantine")
      }
    }
    root.settingsLoaded = true
    root.updateReady()
  }

  function loadSession(raw) {
    var text = String(raw || "").trim()
    root.session = null
    root.sessionCorrupt = false
    if (text) {
      try {
        var input = JSON.parse(text)
        // The legacy sanitizer clamps counters. That must not turn a hostile
        // session identity into a reused valid ID before reservation.
        // Reject through the nonfatal session quarantine path. An invalid ID
        // is never adopted or clamped, and must not latch a storage failure
        // which would prevent that queued quarantine from ever running.
        if (input && input.profileId === "lazyvim" && !Stats.validRunId(input.runId))
          throw new Error("invalid run identity")
        var value = Session.sanitize(input)
        if (!value) throw new Error("unsupported session schema")
        root.session = value
      } catch (loadError) {
        root.sessionCorrupt = true
        root.enqueue({ action: "quarantine", kind: "session" })
        console.warn("Keycade session was rejected and queued for quarantine")
      }
    }
    root.sessionLoaded = true
    root.updateReady()
  }

  // Only what the helper needs; nothing else is inherited.
  function childEnvironment() {
    return {
      "PATH": "/usr/bin",
      "HOME": Quickshell.env("HOME") || "",
      "XDG_STATE_HOME": Quickshell.env("XDG_STATE_HOME") || ""
    }
  }

  function fail(message) {
    if (root.error) return
    root.error = String(message || "State storage failed").slice(0, 512)
    root.ready = false
    root.failed(root.error)
  }

  function enqueue(operation) {
    if (root.error) return
    var queue = root.operations.slice()
    if (operation.action === "write") {
      for (var index = queue.length - 1; index >= 0; index--) {
        if (queue[index].kind !== operation.kind) continue
        if (queue[index].action === "write") {
          queue[index] = operation
          root.operations = queue
          return
        }
        break
      }
    } else if (operation.action === "delete") {
      for (var deleteIndex = queue.length - 1; deleteIndex >= 0; deleteIndex--) {
        if (queue[deleteIndex].kind !== operation.kind) continue
        if (queue[deleteIndex].action === "delete") return
        if (queue[deleteIndex].action === "write") {
          queue[deleteIndex] = operation
          root.operations = queue
          return
        }
        break
      }
    }
    if (queue.length >= root.maxQueuedOperations) {
      root.fail("State operation queue exceeded its limit")
      return
    }
    queue.push(operation)
    root.operations = queue
    root.runNext()
  }

  function runNext() {
    if (stateProcess.running || root.currentOperation || !root.operations.length || root.error) return
    var queue = root.operations.slice()
    root.currentOperation = queue.shift()
    root.operations = queue
    root.operationOutput = ""
    root.operationTimedOut = false
    root.loadFiles = null
    root.loadKind = ""
    root.loadChunksLeft = 0
    root.streamChars = 0
    root.streamRecords = 0
    root.streamComplete = false
    var operation = root.currentOperation
    var command = [
      root.interpreterPath, root.relayPath,
      "--max-bytes", String(root.relayMaxBytes),
      "--deadline", String(root.relayDeadline),
      "--", root.interpreterPath, root.helperPath, operation.action
    ]
    if (operation.kind) command.push(operation.kind)
    if (operation.quarantine) command.push("--quarantine")
    stateProcess.command = command
    stateProcess.stdinEnabled = operation.payload !== undefined
    operationTimeout.restart()
    stateProcess.running = true
  }

  function enqueueWrite(kind, value, quarantine) {
    var payload
    try {
      payload = JSON.stringify(value)
    } catch (serializeError) {
      root.fail("State serialization failed")
      return
    }
    // The helper also counts the terminating newline in its stdin budget.
    if (DeckState.utf8Bytes(payload) + 1 > root.fileLimits[kind]) {
      root.fail(kind + " state exceeded its limit")
      return
    }
    root.enqueue({ action: "write", kind: kind, payload: payload, quarantine: quarantine === true })
  }

  function saveStats() {
    if (root.declaredDeckIds === null || !root.statsLoaded || !root.runIdentityPrepared) {
      root.statsSavePending = true
      return
    }
    root.statsSavePending = false
    root.stats = Stats.migrate(root.stats, root.declaredDeckIds)
    root.enqueueWrite("stats", root.stats, root.statsCorrupt)
    root.statsCorrupt = false
  }

  function saveSettings() {
    try {
      root.settings = root.normalizedSettings(root.settings)
      root.enqueueWrite("settings", root.settings, root.settingsCorrupt)
      root.settingsCorrupt = false
    } catch (settingsError) {
      root.fail("Settings state was invalid")
    }
  }

  // Atomic, nonfatal curation boundary for the later drawer. A rejected edit
  // never changes settings, queues a write, or evicts old/undeclared deltas.
  function setDeckCard(deckId, cardId, action) {
    var next
    try {
      if (!root.ready) throw new Error("state-not-ready")
      next = root.normalizedSettings(root.settings)
      next.deckCards = DeckState.change(root.settings.deckCards, deckId, cardId, action)
      if (DeckState.serializedBytes(next) + 1 > root.fileLimits.settings)
        throw new Error("settings-limit")
    } catch (mutationError) {
      var reason = String(mutationError.message || "invalid-deck-cards")
      root.deckCardsRefusal = ["deck-cards-limit", "invalid-deck-cards", "settings-limit",
                              "state-not-ready"].indexOf(reason) !== -1
          ? reason : "invalid-deck-cards"
      root.deckCardsRefused(root.deckCardsRefusal)
      return false
    }
    root.deckCardsRefusal = ""
    root.settings = next
    root.saveSettings()
    return true
  }

  function saveSession(value) {
    if (value && value.profileId === "lazyvim") {
      try {
        var before = root.stats.runSequence
        Stats.adoptRunIdentity(root.stats, value.runId)
        if (before !== root.stats.runSequence) root.saveStats()
      } catch (identityError) {
        root.fail("Run identity is invalid or exhausted")
        return
      }
    }
    root.session = Session.sanitize(value)
    if (!root.session) {
      root.clearSession()
      return
    }
    root.enqueueWrite("session", root.session, root.sessionCorrupt)
    root.sessionCorrupt = false
  }

  function clearSession() {
    root.session = null
    root.enqueue({ action: "delete", kind: "session" })
  }

  // One record at a time while the helper is still running, so an oversized
  // response is abandoned rather than retained and measured afterwards.
  // Write, delete and quarantine reply with a single small acknowledgement.
  function acceptAcknowledgement(line) {
    var text = String(line || "")
    if (!text.trim().length) return
    if (text.length > 4096) throw new Error("oversized state acknowledgement")
    var acknowledgement = JSON.parse(text)
    if (!acknowledgement || acknowledgement.schemaVersion !== 1 || acknowledgement.ok !== true)
      throw new Error("invalid state acknowledgement")
    root.streamComplete = true
  }

  // Give the helper a chance to exit on its own before forcing it down.
  function stopHelper() {
    if (!stateProcess.running) return
    stateProcess.signal(15)
    forceStop.restart()
  }

  function acceptLine(line) {
    if (root.streamComplete) return
    var text = String(line || "")
    if (text.length > root.maxRecordChars) throw new Error("state record exceeded its limit")
    root.streamChars += text.length + 1
    if (root.streamChars > root.maxResponseChars) throw new Error("state response exceeded its limit")
    root.streamRecords += 1
    if (root.streamRecords > root.maxRecords) throw new Error("too many state records")
    if (!text.trim().length) return

    var record = JSON.parse(text)
    if (!record || typeof record !== "object" || Array.isArray(record))
      throw new Error("invalid state record")

    if (record.type === "header") {
      if (record.schemaVersion !== 1) throw new Error("invalid state response")
      root.loadFiles = ({ stats: "", settings: "", session: "" })
      root.loadKind = ""
      root.loadChunksLeft = 0
      return
    }

    if (record.type === "file") {
      if (!root.loadFiles) throw new Error("state record before header")
      if (["stats", "settings", "session"].indexOf(record.kind) === -1)
        throw new Error("invalid state file response")
      if (["ok", "missing", "quarantined"].indexOf(record.status) === -1)
        throw new Error("invalid state file response")
      if (typeof record.chunks !== "number" || !isFinite(record.chunks)
          || Math.floor(record.chunks) !== record.chunks || record.chunks < 0)
        throw new Error("invalid state chunk count")
      root.loadKind = record.kind
      root.loadChunksLeft = record.chunks
      return
    }

    if (record.type === "chunk") {
      if (!root.loadFiles || record.kind !== root.loadKind || root.loadChunksLeft <= 0)
        throw new Error("unexpected state chunk")
      if (typeof record.data !== "string") throw new Error("invalid state chunk")
      var existing = String(root.loadFiles[record.kind])
      var addition = String(record.data)
      if (DeckState.utf8Bytes(existing + addition) > root.fileLimits[record.kind])
        throw new Error("state file exceeded its limit")
      root.loadFiles[record.kind] = existing + addition
      root.loadChunksLeft -= 1
      return
    }

    if (record.type !== "end") throw new Error("unknown state record type")
    if (!root.loadFiles || root.loadChunksLeft !== 0) throw new Error("incomplete state response")
    root.streamComplete = true
    root.loadStats(root.loadFiles.stats)
    root.loadSettings(root.loadFiles.settings)
    root.loadSession(root.loadFiles.session)
    root.loadFiles = null
  }

  Component.onCompleted: root.enqueue({ action: "load" })
  Component.onDestruction: {
    operationTimeout.stop()
    forceStop.stop()
    if (stateProcess.running) {
      stateProcess.signal(15)
      stateProcess.signal(9)
    }
  }

  Timer {
    id: operationTimeout
    interval: 5000
    repeat: false
    onTriggered: {
      root.operationTimedOut = true
      root.stopHelper()
    }
  }

  Timer {
    id: forceStop
    interval: 500
    repeat: false
    onTriggered: if (stateProcess.running) stateProcess.signal(9)
  }

  Process {
    id: stateProcess
    clearEnvironment: true
    Component.onCompleted: stateProcess.environment = root.childEnvironment()
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) {
        if (root.error) return
        try {
          if (root.currentOperation && root.currentOperation.action === "load") root.acceptLine(line)
          else root.acceptAcknowledgement(line)
        } catch (lineError) {
          root.fail("State helper returned invalid data")
          root.stopHelper()
        }
      }
    }
    onStarted: {
      if (root.currentOperation && root.currentOperation.payload !== undefined)
        stateProcess.write(root.currentOperation.payload + "\n")
    }
    onExited: function(exitCode) {
      operationTimeout.stop()
      forceStop.stop()
      var operation = root.currentOperation
      root.currentOperation = null
      if (root.operationTimedOut) {
        root.fail("State helper exceeded its deadline")
        return
      }
      if (exitCode !== 0) {
        root.fail("State helper failed")
        return
      }
      if (root.error) return
      if (!root.streamComplete) {
        root.fail("State helper returned invalid data")
        return
      }
      Qt.callLater(function() { root.runNext() })
    }
  }
}
