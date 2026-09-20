pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import "lib"
import "lib/sources"
import "lib/AnswerMatcher.js" as AnswerMatcher
import "lib/InputNormalizer.js" as Normalizer
import "lib/Profiles.js" as Profiles
import "lib/Scheduler.js" as Scheduler
import "lib/Stats.js" as Stats
import "lib/Session.js" as Session
import "lib/Decks.js" as Decks
import "lib/Palettes.js" as Palettes
import "lib/sources/pack/Eligibility.js" as PackEligibility

Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false
  property string view: "closed"
  property string errorMessage: ""
  property bool guardReady: false
  // The pack is ready only after the machine's configuration has arrived
  // through the bounded reader and calibrated the compiled LazyVim table.
  property bool groundLoading: false
  property bool escapeDown: false
  property string requestedLocale: ""

  property var eligibleBindings: [] // active deck's eligible members
  property var eligibleCorpus: []
  property var deckDefinitions: [] // final config only, never a loading fallback
  property var deckProgress: Object.create(null)
  property string deckConfigReason: ""
  property int deckConfigRejected: 0
  property string startRefusal: "" // bounded code driving the home refusal hint
  // Zero eligible cards means there is nothing to deal: the home controls
  // stay visible but inert, and Enter is refused before any run identity
  // could be allocated (startRun re-checks this same condition first).
  readonly property bool startBlocked: !root.eligibleBindings.length
  property int sessionSize: 0
  property var deck: []
  property int cardIndex: 0
  property int runNumber: 1
  property int runOffset: 0
  property int runReviewTarget: 0
  property int runNewTarget: 0
  property int correct: 0
  property int attempts: 0
  property int newLearned: 0
  property int masteredGained: 0
  property var reactions: []
  property var runResults: Object.create(null)
  property var pendingReinforcements: Object.create(null)
  property var reviewSuggestions: []
  property var masterySnapshot: ({ attempts: 0, correct: 0, accuracy: 0, response: 0 })
  property var progressCounts: ({ unseen: 0, learning: 0, mastered: 0, due: 0, total: 0 })
  // The available supply's { mastered, total }, by id. Retired history stays
  // in storage but never appears in this home-screen model.
  property var groundProgress: Object.create(null)
  property double activeSegmentStartedAt: 0
  property double cardStartedAt: 0
  property double deadline: 0
  property real energy: 1
  property int lastCountdownBeat: 0
  property int countdownSeconds: 0
  // A run-local streak of first-try hits. It is display only: it never reaches
  // stats or the scheduler, which grade recall and spacing rather than speed.
  property int combo: 0
  property bool cardLocked: false
  // How much of the current text answer has been typed.
  property int answerStep: 0
  // One cursor per accepted answer; see AnswerMatcher.begin().
  property var answerState: AnswerMatcher.begin()
  // A sequence can overrun its own answer: the card asked for `gc` and the
  // fingers typed `gcc`. The tail must not reach the next card, so a card that
  // could overrun arms a short silence over the one that follows it.
  property bool overrunGuardArmed: false
  property double inputSilentUntil: 0
  readonly property int overrunGuardMs: 150
  property bool correctionRequired: false
  property bool cardErrorSoundPlayed: false
  property string feedbackKind: "idle"
  property string feedbackText: ""
  property bool revealChord: false
  property string themeName: Palettes.defaultName()
  property bool resumeAvailable: false
  property bool languageMenuOpen: false
  property bool soundMenuOpen: false
  property bool excludedMenuOpen: false
  property bool browseOpen: false
  property bool browseTargetsOpen: false
  property string browseTargetId: "all"
  property string browseCategory: ""
  property string browseSource: ""
  property bool browseInDeck: false
  property string browseWarning: ""
  readonly property bool browseAvailable: store.ready && !root.groundLoading
      && (root.view === "home" || root.view === "summary" || root.view === "mastery")
  readonly property var browseTarget: Decks.find(root.deckDefinitions, root.browseTargetId)
  readonly property var browseCategories: PackEligibility.categories(root.eligibleCorpus)
  // Only active, validated pack metadata is offered, never arbitrary config strings.
  readonly property var browseExtras: root.activeBrowseExtras()
  readonly property var browseMatches: root.filteredBrowseCards()
  property var browseRows: []
  onBrowseMatchesChanged: root.syncBrowseRows()
  onBrowseAvailableChanged: if (!root.browseAvailable) root.closeBrowse()
  // The compact grid wraps on smaller frames and during play, leaving room
  // for the bounded selected-deck badge rather than overlapping the brand.
  readonly property int topButtonWidth: 100
  property bool themeMenuOpen: false
  property var excludedRows: []
  property int staleExcludedCount: 0
  property bool excludeStampVisible: false
  property string excludedCardId: ""
  property bool trainingLockedOut: false
  property string pendingExternalUrl: ""

  readonly property var currentCard: deck.length > cardIndex ? deck[cardIndex] : null
  readonly property var currentBinding: currentCard ? currentCard.binding : null
  readonly property var currentAnswer: currentBinding ? currentBinding.answer : null
  readonly property var answerSteps: AnswerMatcher.stepLabels(root.currentAnswer)
  readonly property int runCardLimit: 24
  // Read-only readiness for non-interactive tooling; selecting another supply
  // is no longer available as a way to wait for persisted settings.
  readonly property bool stateReady: store.ready
  // Supply identity never changes; the selected deck is a separate namespace.
  readonly property string profileId: "lazyvim"
  property string deckId: "all"
  property bool configOpened: false
  readonly property var availableProfiles: ["lazyvim"]
  readonly property var activeSource: packs
  // Long enough to read the stamp, not long enough to feel like a penalty.
  // 300 ms measured worse than it sounds: the 110 ms fade eats a third of it,
  // so the words were legible for under two tenths of a second.
  readonly property int excludeStampMs: 900
  readonly property int maxOpenPayloadChars: 16 * 1024
  readonly property bool reducedMotion: Boolean(store.settings.reducedMotion)
  readonly property int nextRunNumber: Math.min(Stats.MAX_COUNTER, Stats.runsOf(store.stats, root.deckId) + 1)
  property int sessionRunIdentity: 0
  // Display/celebration counters stay deck-local. Scheduling and card history
  // use the reserved identity (or a read-only preview before a new session).
  readonly property int activeRunId: root.sessionRunIdentity > 0
      ? root.sessionRunIdentity : Stats.peekRunIdentity(store.stats)
  readonly property string marketplaceUrl: "https://plugins.omarchy.org/plugin.html?id=gerritwanderer.keycade-lazyvim"

  readonly property var themePalette: Palettes.palette(root.themeName)
  readonly property color voidColor: root.themePalette.voidColor
  readonly property color cabinetColor: root.themePalette.cabinetColor
  readonly property color screenColor: root.themePalette.screenColor
  readonly property color inkColor: root.themePalette.inkColor
  readonly property color mutedColor: root.themePalette.mutedColor
  readonly property color primaryColor: root.themePalette.primaryColor
  readonly property color secondaryColor: root.themePalette.secondaryColor
  readonly property color successColor: root.themePalette.successColor
  readonly property color dangerColor: root.themePalette.dangerColor
  readonly property color coinColor: root.themePalette.coinColor

  function acceptedOpenPayload(payloadJson) {
    var rawPayload = typeof payloadJson === "string" ? payloadJson : "{}"
    if (rawPayload.length > root.maxOpenPayloadChars) return ({})
    try {
      var parsedPayload = JSON.parse(rawPayload || "{}")
      return parsedPayload && typeof parsedPayload === "object" && !Array.isArray(parsedPayload)
          ? parsedPayload : ({})
    } catch (error) {
      return ({})
    }
  }

  function open(payloadJson) {
    if (root.opened) return
    var payload = root.acceptedOpenPayload(payloadJson)
    root.opened = true
    root.view = "loading"
    root.errorMessage = ""
    root.guardReady = false
    root.requestedLocale = payload.locale && i18n.supported.indexOf(payload.locale) !== -1
        ? String(payload.locale) : ""
    root.activeSegmentStartedAt = 0
    root.pendingExternalUrl = ""
    root.closeTopMenus()
    root.closeBrowse()
    root.themeName = Palettes.supported(store.settings.theme) ? String(store.settings.theme)
        : Palettes.supported(payload.theme) ? String(payload.theme) : Palettes.defaultName()
    var savedLocale = String(store.settings.locale || "en")
    i18n.locale = root.requestedLocale
        || (i18n.supported.indexOf(savedLocale) !== -1 ? savedLocale : "en")
    guard.begin()
    // The cold-load reader was already requested before state readiness;
    // reuse that result/launch rather than deadlock or launch a second helper.
    if (root.configOpened || (!appConfig.loading && !appConfig.settled)) root.loadActiveGround()
    root.configOpened = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() { requestSafeClose() }

  function toggle() {
    if (root.opened) requestSafeClose()
    else open("{}")
  }

  function dismiss() {
    var externalUrl = root.pendingExternalUrl
    root.pendingExternalUrl = ""
    root.opened = false
    root.view = "closed"
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "gerritwanderer.keycade-lazyvim")
    if (externalUrl) Qt.openUrlExternally(externalUrl)
  }

  function openMarketplacePage() {
    if (root.view !== "mastery") return
    root.pendingExternalUrl = root.marketplaceUrl
    root.requestSafeClose()
  }

  // Back to the cabinets, mid-run. The run is saved exactly as leaving the
  // overlay saves it - the deck, the correction state, the statistics - so
  // picking this ground again resumes where it stopped. It is the only way
  // out of a run that is not also a way out of the overlay.
  function leaveRun() {
    if (root.view !== "playing") return
    cardTimer.stop()
    sounds.stopCountdown()
    feedbackTimer.stop()
    excludeStampTimer.stop()
    root.excludeStampVisible = false
    root.excludedCardId = ""
    commitActiveTraining()
    if (store.ready) {
      saveRunSession()
      store.saveStats()
    }
    root.cardLocked = false
    root.correctionRequired = false
    root.deadline = 0
    root.energy = 1
    root.combo = 0
    root.feedbackKind = "idle"
    root.answerStep = 0
    root.answerState = AnswerMatcher.begin()
    guard.pause()
    root.view = "home"
    root.feedbackText = i18n.t("ready")
    root.resumeAvailable = root.hasResumableSession()
    refreshProgressCounts()
  }

  function requestSafeClose() {
    root.closeBrowse()
    cardTimer.stop()
    sounds.stopCountdown()
    feedbackTimer.stop()
    commitActiveTraining()
    if (root.view === "playing" && root.cardLocked && !root.correctionRequired
        && root.feedbackKind === "hit" && root.cardIndex + 1 >= root.deck.length)
      finishRun(false)
    if (store.ready) {
      saveRunSession()
      store.saveStats()
    }
    root.view = "closing"
    guard.requestClose()
  }

  // Config must be requested independently of store.ready: its final deck
  // declarations are what allow StateStore to prune and finish loading stats.
  Component.onCompleted: root.loadActiveGround()

  function loadActiveGround() {
    root.groundLoading = true
    appConfig.profileId = root.profileId
    appConfig.refresh()
  }

  function maybeShowHome() {
    if (!root.opened || root.view !== "loading" || !root.guardReady
        || root.groundLoading || root.activeSource.loading || !store.ready) return
    var savedLocale = String(store.settings.locale || "en")
    if (i18n.supported.indexOf(savedLocale) === -1) {
      store.settings.locale = "en"
      store.settings = Object.assign({}, store.settings)
      store.saveSettings()
      savedLocale = "en"
    }
    if (!root.requestedLocale) i18n.locale = savedLocale
    // open() reads the theme too, but the state files load asynchronously, so
    // on a cold shell the overlay can be summoned before settings arrive and
    // keep the default palette for that whole session. This runs once the
    // store is ready, which is the point the saved theme is actually known.
    root.themeName = Palettes.supported(store.settings.theme)
        ? String(store.settings.theme) : root.themeName
    root.applyEligibility()
    root.runNumber = root.nextRunNumber
    root.resumeAvailable = hasResumableSession()
    root.adoptRunState()
    refreshProgressCounts()
    if (!root.settleGround()) return
    root.view = "home"
    root.feedbackText = i18n.t("ready")
  }

  // The one place eligibility is computed. Excluding and restoring both go
  // through it, so the mastery denominator - which is the size of this set -
  // moves with them instead of at the next launch.
  function applyEligibility() {
    var result = PackEligibility.filter(packs.bindings, {
      excludedBindings: store.settings.excludedBindings,
      profile: root.profileId
    })
    var rows = []
    var matched = Session.safeMap()
    for (var i = 0; i < result.excluded.length; i++) {
      if (result.excluded[i].reason !== "user-excluded") continue
      rows.push(result.excluded[i].binding)
      matched[result.excluded[i].binding.localId] = true
    }
    var stored = Session.excludedSet(store.settings.excludedBindings, root.profileId)
    var stale = 0
    Object.keys(stored).forEach(function(id) { if (!matched[id]) stale += 1 })
    root.eligibleCorpus = Decks.eligible(result.eligible, store.settings.excludedBindings)
    root.eligibleBindings = root.cardsForDeck(root.deckId)
    if (root.view === "playing")
      root.sessionSize = root.runOffset + root.cardIndex
          + Session.restoreCards(Session.cardsFrom(root.deck, root.cardIndex), root.eligibleBindings).length
    root.excludedRows = rows
    root.staleExcludedCount = stale
    // An exclusion can outlive the bind it names, so a config change between
    // two launches can empty the eligible set. Failing here would close the
    // overlay after five seconds with the restore list out of reach, so home
    // stays reachable and starting a run is what gets refused instead.
    root.trainingLockedOut = !result.eligible.length && (rows.length > 0 || stale > 0)
    refreshProgressCounts()
    root.startRefusal = root.eligibleBindings.length ? "" : "empty-deck"
    return result
  }

  // These APIs are shared by the later home list and curation drawer. Only
  // declared decks are offered; retained orphan deltas/counters stay inert.
  function cardsForDeck(id) {
    return Decks.evaluate(Decks.find(root.deckDefinitions, id), root.eligibleCorpus,
                          store.settings.deckCards, store.settings.excludedBindings)
  }

  function deckMembership(id, cardId) {
    var card = null
    for (var i = 0; i < root.eligibleCorpus.length; i++)
      if (root.eligibleCorpus[i].id === cardId) { card = root.eligibleCorpus[i]; break }
    return Decks.membership(Decks.find(root.deckDefinitions, id), card, store.settings.deckCards)
  }

  function otherDecks(cardId, targetId) {
    return Decks.otherDecks(root.deckDefinitions, cardId, targetId, root.eligibleCorpus,
                            store.settings.deckCards, store.settings.excludedBindings)
  }

  function setDeckCard(id, cardId, action) {
    if (root.view === "playing" || !Decks.find(root.deckDefinitions, id)) return false
    if (!store.setDeckCard(id, cardId, action)) return false
    root.applyEligibility()
    root.resumeAvailable = root.hasResumableSession()
    root.adoptRunState()
    return true
  }

  function selectDeck(id) {
    if (root.browseOpen || root.view === "playing" || !store.ready || root.groundLoading
        || !Decks.find(root.deckDefinitions, id)) return false
    root.deckId = id
    store.settings.activeDeck = id
    store.settings = Object.assign({}, store.settings)
    store.saveSettings()
    root.applyEligibility()
    root.resumeAvailable = root.hasResumableSession()
    root.adoptRunState()
    if (root.view === "summary" || root.view === "mastery") root.view = "home"
    root.refreshProgressCounts()
    return true
  }

  // Drawer state is deliberately separate from settings.activeDeck. Opening
  // results returns home; opening a saved run does not pause, allocate or resume.
  function closeTopMenus() {
    root.languageMenuOpen = false
    root.soundMenuOpen = false
    root.excludedMenuOpen = false
    root.themeMenuOpen = false
  }

  function closeBrowse() {
    root.browseTargetsOpen = false
    root.browseOpen = false
  }

  function toggleBrowse() {
    if (root.browseOpen) { root.closeBrowse(); return }
    if (!root.browseAvailable) return
    root.closeTopMenus()
    if (root.view === "summary" || root.view === "mastery") root.view = "home"
    root.browseTargetId = root.deckId
    root.browseWarning = ""
    root.browseOpen = true
  }

  function chooseBrowseTarget(id) {
    if (!root.browseOpen || !root.browseAvailable || !Decks.find(root.deckDefinitions, id)) return
    root.browseTargetId = id
    root.browseTargetsOpen = false
    root.browseWarning = ""
  }

  function browseCard(id) {
    for (var i = 0; i < root.eligibleCorpus.length; i++)
      if (root.eligibleCorpus[i].id === id) return root.eligibleCorpus[i]
    return null
  }

  function activeBrowseExtras() {
    var seen = Object.create(null)
    var extras = []
    root.eligibleCorpus.forEach(function(card) {
      (card.extras || []).forEach(function(extra) {
        if (packs.enabledExtras.indexOf(extra) !== -1 && !seen[extra]) {
          seen[extra] = true
          extras.push(extra)
        }
      })
    })
    return extras.sort()
  }

  function filteredBrowseCards() {
    // All inputs already passed the bounded source/config consumers. Membership
    // is still evaluated by the one engine; exclusions cannot re-enter here.
    return root.eligibleCorpus.filter(function(card) {
      if (root.browseCategory && card.category !== root.browseCategory) return false
      if (root.browseSource === "custom"
          && card.customKind !== "added" && card.customKind !== "changed") return false
      if (root.browseSource && root.browseSource !== "custom"
          && (root.browseExtras.indexOf(root.browseSource) === -1
              || card.extras.indexOf(root.browseSource) === -1)) return false
      return !root.browseInDeck || root.deckMembership(root.browseTargetId, card.id).member
    }).map(function(card) { return card.id })
  }

  function syncBrowseRows() {
    var next = root.browseMatches
    // A membership change must not reset a long corpus ListView. Its model is
    // IDs only; delegates resolve current metadata/membership independently.
    if (next.length === root.browseRows.length && next.every(function(id, index) {
      return id === root.browseRows[index]
    })) return
    root.browseRows = next
  }

  function browseMembershipLabel(membership) {
    return !membership.member ? i18n.t("browseAdd")
        : membership.added ? i18n.t("browseInDeckAdded") : i18n.t("browseInDeckSeeded")
  }

  function toggleBrowseCard(cardId) {
    if (!root.browseOpen || !root.browseAvailable) return false
    if (!root.browseTarget) { root.browseWarning = i18n.t("browseTargetMissing"); return false }
    if (root.browseTargetId === "all") return false
    if (!root.browseCard(cardId)) return false
    var membership = root.deckMembership(root.browseTargetId, cardId)
    // Restore a pruned seed by clearing its override, not by layering an
    // addition over a removal. Added/nonseed and seeded states have one action.
    var action = membership.member ? (membership.added ? "reset" : "remove")
        : membership.seeded ? "reset" : "add"
    if (!root.setDeckCard(root.browseTargetId, cardId, action)) {
      root.browseWarning = i18n.t("browseCapacityRefused")
      return false
    }
    root.browseWarning = ""
    return true
  }

  // Called before home Enter and by the real Keys handler. Input bookkeeping
  // remains outside this modal gate, including every modifier release.
  function handleBrowseKey(event) {
    if (!root.browseOpen) return false
    if (event.key === Qt.Key_Escape) {
      if (root.browseTargetsOpen) root.browseTargetsOpen = false
      else root.closeBrowse()
      root.escapeDown = false
    }
    event.accepted = true
    return true
  }

  function reconcileDeckState() {
    if (!store.ready || root.groundLoading || !root.deckDefinitions.length || root.view === "playing") return
    var saved = store.settings.activeDeck
    root.deckId = Decks.find(root.deckDefinitions, saved) ? saved : "all"
    root.applyEligibility()
    root.resumeAvailable = root.hasResumableSession()
    root.adoptRunState()
  }

  function excludeCurrentBinding() {
    if (root.view !== "playing" || !root.currentBinding || root.excludeStampVisible) return
    if (root.eligibleBindings.length <= 1) {
      root.feedbackKind = "miss"
      root.feedbackText = i18n.t("excludeRejectedLast")
      return
    }
    var next = Session.withExclusion(store.settings.excludedBindings, root.profileId,
                                     root.currentBinding.localId)
    if (!next) {
      root.feedbackKind = "miss"
      root.feedbackText = i18n.t("excludeRejectedFull")
      return
    }

    // Seal the card before anything else. A timer left running would reach
    // zero while the stamp is up and record a miss against a bind the user
    // just took out of training.
    root.cardLocked = true
    root.correctionRequired = false
    cardTimer.stop()
    feedbackTimer.stop()
    sounds.stopCountdown()
    root.deadline = 0
    root.energy = 1
    root.feedbackKind = "idle"
    root.feedbackText = i18n.t("excludeStamp")
    root.excludeStampVisible = true
    sounds.playEject()
    if (!root.reducedMotion) excludedPulse.restart()

    store.settings.excludedBindings = next
    store.settings = Object.assign({}, store.settings)
    store.saveSettings()
    // The eligible set shrinks now, not at the next launch, so the mastery
    // denominator and the drawer count answer for this run.
    root.applyEligibility()

    // The deck is left alone until the stamp clears: emptying it here would
    // blank the card behind the stamp. Nothing can reach the old card in the
    // meantime - it is locked and its timers are stopped - and a crash inside
    // the beat is harmless, because a resumed deck keeps only cards whose
    // binding is still eligible.
    root.excludedCardId = root.currentBinding.id
    excludeStampTimer.restart()
  }

  function dropExcludedCard(bindingId) {
    var remaining = []
    for (var i = 0; i < root.deck.length; i++) {
      if (i >= root.cardIndex && root.deck[i].binding.id === bindingId) continue
      remaining.push(root.deck[i])
    }
    root.deck = remaining
    root.setReinforcementPending(bindingId, false)
    // Recall history and score/results describe what happened, not the live
    // denominator. Keep them; only playable cards and sessionSize shrink.
    root.sessionSize = root.runOffset + root.deck.length
  }

  // Restoring is offered while idle only: putting a bind back mid-run would
  // mean rebuilding the deck and its plan counts for no benefit.
  // Named by local id: that is what the stored exclusion holds, and what the
  // restore rows carry.
  function restoreBinding(localId) {
    if (root.view === "playing") return
    store.settings.excludedBindings =
        Session.withoutExclusion(store.settings.excludedBindings, root.profileId, localId)
    store.settings = Object.assign({}, store.settings)
    store.saveSettings()
    root.applyEligibility()
    root.resumeAvailable = root.hasResumableSession()
    root.adoptRunState()
  }

  // Entries whose bind no longer exists cannot be shown or restored, but they
  // still spend the budget. They are never dropped silently: clearing them is
  // a button, because a bind commented out today may come back tomorrow.
  function clearStaleExclusions() {
    var live = Session.safeMap()
    for (var i = 0; i < root.excludedRows.length; i++) live[root.excludedRows[i].localId] = true
    var prefix = root.profileId + ":"
    var stored = Session.excludedList(store.settings.excludedBindings)
    var keep = []
    for (var j = 0; j < stored.length; j++) {
      var entry = stored[j]
      if (entry.slice(0, prefix.length) !== prefix || live[entry.slice(prefix.length)])
        keep.push(entry)
    }
    store.settings.excludedBindings = keep
    store.settings = Object.assign({}, store.settings)
    store.saveSettings()
    root.applyEligibility()
  }

  function localeLabel(code) {
    if (code === "zh-CN") return "简体中文"
    return "English"
  }

  function selectLocale(code) {
    if (i18n.supported.indexOf(code) === -1) return
    i18n.locale = code
    store.settings.locale = code
    store.settings = Object.assign({}, store.settings)
    store.saveSettings()
    root.languageMenuOpen = false
  }

  function selectTheme(name) {
    if (!Palettes.supported(name)) return
    root.themeName = String(name)
    store.settings.theme = root.themeName
    store.settings = Object.assign({}, store.settings)
    store.saveSettings()
    root.themeMenuOpen = false
  }

  function toggleSound() {
    store.settings.feedbackSound = !Boolean(store.settings.feedbackSound)
    store.settings = Object.assign({}, store.settings)
    store.saveSettings()
  }

  function adjustSoundVolume(delta) {
    var value = Math.round(Number(store.settings.soundVolume || 0.4) * 10) / 10
    store.settings.soundVolume = Math.max(0.1, Math.min(1.0, value + Number(delta || 0)))
    store.settings = Object.assign({}, store.settings)
    store.saveSettings()
  }

  function toggleCountdownSound() {
    store.settings.countdownSound = !Boolean(store.settings.countdownSound)
    store.settings = Object.assign({}, store.settings)
    store.saveSettings()
  }

  // Read at each use rather than cached in a property: a training ground's
  // record is created the first time it records anything, and a binding taken
  // before that would keep pointing at a detached copy of the defaults.
  function profileCounters() { return Stats.counters(store.stats, root.deckId) }

  function detectedOptions() {
    return appConfig.options || ({})
  }

  // What the source is handed: every declared option, resolved automatically.
  function profileOptions() {
    return Profiles.resolvedOptions(root.profileId, root.detectedOptions())
  }

  // The reader answered; calibrate the shipped table with the same extras,
  // literal keymaps and leaders as before. No external table replaces it.
  function applyDetectedConfig() {
    var resolved = Decks.definitions(appConfig.deckConfig)
    root.deckDefinitions = resolved.decks
    root.deckConfigReason = resolved.reason
    root.deckConfigRejected = resolved.rejected
    store.setDeclaredDeckIds(Decks.ids(root.deckDefinitions))
    packs.profileId = root.profileId
    packs.options = root.profileOptions()
    packs.enabledExtras = appConfig.extras
    packs.overrides = appConfig.bindings
    packs.refresh()
  }

  // A source finished. The eligible set is rebuilt from it whatever screen we
  // are on: waiting for maybeShowHome() to do it only worked while the answer
  // arrived before the home screen did.
  function groundReady() {
    root.groundLoading = false
    root.reconcileDeckState()
    root.applyEligibility()
    root.resumeAvailable = root.hasResumableSession()
    root.adoptRunState()
    // Already on the home screen: the ground changed under it, so settle it
    // in place rather than sending it through the loading screen again.
    if (root.view === "home") root.settleGround()
    else root.maybeShowHome()
  }

  // What a ground has to answer for once its table is in: whether it has
  // anything to teach at all, and whether finishing it earned the one-time
  // celebration. Shared by the cold start and by picking another cabinet.
  function settleGround() {
    // Empty collections stay reachable for curation; never fail the guard.
    if (!root.eligibleBindings.length) { root.startRefusal = "empty-deck"; return true }
    checkFirstMastery(root.nextRunNumber)
    var counters = root.profileCounters()
    if (!root.resumeAvailable && Number(counters.firstMasteryAt || 0) > 0
        && !Boolean(counters.firstMasteryCelebrated)
        && Number(counters.firstMasteryRun || 0) <= Number(counters.runs || 0)) {
      root.showFirstMastery()
      return false
    }
    return true
  }

  // The home-screen header and counters must describe the resumable LazyVim
  // run, not stale values left by a previous run or retired saved session.
  //
  // Only one session is kept, tagged with its ground. So: if this ground is
  // the one that can be resumed, what is on screen is that run's - it is what
  // picking RESUME walks back into. Otherwise there is no run here yet, and
  // the header reads as the run that pressing START would begin.
  //
  // The deck itself is not restored here; RESUME rebuilds it against this
  // ground's own bindings. Only what the screen shows is adopted.
  function adoptRunState() {
    if (root.view === "playing") return
    var session = root.resumeAvailable ? store.session : null
    root.deck = []
    root.cardIndex = 0
    root.runOffset = session ? Math.max(0, Math.min(root.runCardLimit - 1,
                                                   Number(session.offset || 0))) : 0
    root.sessionRunIdentity = session ? session.runId : 0
    root.sessionSize = session ? Session.resumedSize(session, root.eligibleBindings) : 0
    root.runNumber = session && session.runNumber ? session.runNumber : root.nextRunNumber
    root.correct = session ? Math.max(0, Number(session.correct || 0)) : 0
    root.attempts = session ? Math.max(0, Number(session.attempts || 0)) : 0
    root.newLearned = session ? Math.max(0, Number(session.newLearned || 0)) : 0
    root.masteredGained = session ? Math.max(0, Number(session.masteredGained || 0)) : 0
    root.runReviewTarget = session ? Math.max(0, Number(session.runReviewTarget || 0)) : 0
    root.runNewTarget = session ? Math.max(0, Number(session.runNewTarget || 0)) : 0
    root.reactions = session && Array.isArray(session.reactions) ? session.reactions : []
    root.runResults = session
        ? Session.restoreResults(session.runResults, root.eligibleBindings) : Session.safeMap()
    root.pendingReinforcements = Session.safeMap()
    var pending = session && Array.isArray(session.pendingReinforcements)
        ? session.pendingReinforcements : []
    for (var index = 0; index < pending.length; index++)
      if (root.eligibleBindings.some(function(card) { return card.id === pending[index] }))
        root.setReinforcementPending(String(pending[index]), true)
    root.combo = 0
    root.energy = 1
  }

  // A pack entry carries its upstream description and optional translation.
  function actionName(binding) {
    if (!binding) return ""
    // A pack ships the upstream's English. Show the translation when the
    // language pack has one, and the English when it does not - which is what
    // an upstream that rewrote its description leaves behind.
    var key = String(binding.descKey || "")
    if (key && i18n.messages && i18n.messages[key] !== undefined) return i18n.t(key)
    return String(binding.actionName || "")
  }

  // One line for an answer, wherever a list has no room to draw its steps.
  // A chord renders exactly as it always did. A sequence separates its steps
  // the way the card does, with the same mark: spaces alone made "[w" read as
  // "[  w", which in a small monospace column looks like no key at all rather
  // than like two keys typed one after the other.
  // The other sequences this card takes, as one line.
  function answerAlternates() {
    return AnswerMatcher.alternateLabels(root.currentAnswer)
  }

  function answerDisplay(binding) {
    var groups = AnswerMatcher.stepLabels(binding ? binding.answer : null)
    return groups.map(function(keys) { return keys.join(" + ") }).join(" › ")
  }

  function refreshProgressCounts() {
    root.progressCounts = Stats.counts(store.stats, root.eligibleBindings, Date.now(), root.activeRunId)
    var progress = Session.safeMap()
    root.deckDefinitions.forEach(function(definition) {
      progress[definition.id] = Decks.progress(definition, root.eligibleCorpus, store.settings.deckCards,
          store.settings.excludedBindings, store.stats, Date.now(), root.activeRunId)
    })
    root.deckProgress = progress
    // Current progress follows exclusions/extras, never stale written totals.
    root.refreshGroundProgress()
  }

  // Rebuild the current corpus standing so the existing UI sees mutations.
  // The later deck engine computes each deck's progress from this same corpus.
  function refreshGroundProgress() {
    var progress = Session.safeMap()
    // Only once this ground has actually counted itself. Mid-switch its
    // eligible set is empty, and writing that here would blink the cabinet
    // through a dash on the way to its real number.
    if (root.eligibleBindings.length) {
      progress[root.profileId] = {
        mastered: root.progressCounts.mastered,
        total: root.progressCounts.total
      }
    }
    root.groundProgress = progress
  }

  // What each cabinet shows under its name. A ground nobody has opened yet has
  // no total to show and says so with a dash rather than a made-up zero.
  function groundProgressLabel(id) {
    var known = root.groundProgress[String(id)]
    if (!known || !known.total) return "—"
    return known.mastered + "/" + known.total
  }

  // R5 display boundary for deck names: compiled starters resolve through
  // their frozen locale keys; user-declared names are already sanitized at
  // both config boundaries and are rendered as bounded, elided plain text.
  function deckDisplayName(definition) {
    if (!definition) return ""
    if (definition.nameKey) {
      var localized = i18n.t(definition.nameKey)
      if (localized !== definition.nameKey) return localized
    }
    return String(definition.name || "")
  }

  // The header badge identifies the deck being trained, the way it used to
  // identify the ground. Falls back to the supply name before decks arrive.
  function headerDeckName() {
    return root.deckDisplayName(Decks.find(root.deckDefinitions, root.deckId))
  }

  // One bounded line for a deck-config fallback reason or the counted
  // rejections of an otherwise valid file. Both are fixed-vocabulary codes
  // and capped counters from the reader, and an invalid config never blocks
  // training - it only narrows the list.
  function deckConfigNote() {
    if (root.deckConfigReason !== "")
      return i18n.t("deckConfigInvalid", { reason: root.deckConfigReason })
    if (root.deckConfigRejected > 0)
      return i18n.t("deckConfigRejected", { count: root.deckConfigRejected })
    return ""
  }

  function commitActiveTraining() {
    if (root.activeSegmentStartedAt <= 0) return
    Stats.addTrainingTime(store.stats, root.deckId, Date.now() - root.activeSegmentStartedAt)
    root.activeSegmentStartedAt = 0
  }

  function checkFirstMastery(deckRunNumber) {
    if (root.progressCounts.total <= 0
        || root.progressCounts.mastered !== root.progressCounts.total) return false
    var reached = Stats.noteFirstMastery(store.stats, root.deckId, Date.now(),
                                         deckRunNumber || root.nextRunNumber)
    if (reached) store.saveStats()
    return reached
  }

  function showFirstMastery() {
    root.masterySnapshot = Stats.aggregate(store.stats, root.eligibleBindings)
    Stats.markFirstMasteryCelebrated(store.stats, root.deckId)
    store.saveStats()
    root.view = "mastery"
    sounds.playMastery()
  }

  // Reaching 100% is the end of this run even when there are cards left in
  // the 24-card deal. The final mastery screen is the result that matters, so
  // persist the run and move there on the exact answer that masters the last
  // eligible binding instead of making the user finish unrelated review cards.
  function finishAtFirstMastery() {
    if (root.view !== "playing") return false
    // A pending milestone in persisted state is not proof that this ground is
    // still complete: exclusions or a refreshed source may have changed its
    // eligible set since the milestone was recorded. Only the current,
    // independently counted model may end the active run.
    if (root.progressCounts.total <= 0
        || root.progressCounts.mastered !== root.progressCounts.total) return false
    checkFirstMastery(root.runNumber)
    var counters = root.profileCounters()
    if (Number(counters.firstMasteryAt || 0) <= 0
        || Boolean(counters.firstMasteryCelebrated)) return false
    cardTimer.stop()
    feedbackTimer.stop()
    excludeStampTimer.stop()
    sounds.stopCountdown()
    root.excludeStampVisible = false
    root.excludedCardId = ""
    commitActiveTraining()
    store.clearSession()
    root.resumeAvailable = false
    root.sessionRunIdentity = 0
    Stats.completeRun(store.stats, root.deckId)
    store.stats = Object.assign({}, store.stats)
    refreshProgressCounts()
    showFirstMastery()
    return true
  }

  function formatTrainingTime(milliseconds) {
    var minutes = Math.floor(Math.max(0, Number(milliseconds || 0)) / 60000)
    if (minutes < 1) return i18n.t("underOneMinute")
    if (minutes < 60) return i18n.t("durationMinutes", { minutes: minutes })
    return i18n.t("durationHours", {
      hours: Math.floor(minutes / 60),
      minutes: minutes % 60
    })
  }

  function formatMasteryDate(timestamp) {
    var date = new Date(Number(timestamp || Date.now()))
    var month = String(date.getMonth() + 1).padStart(2, "0")
    var day = String(date.getDate()).padStart(2, "0")
    return date.getFullYear() + "-" + month + "-" + day
  }

  function completedCardCount() {
    if (root.view === "summary") return root.sessionSize
    var completed = root.runOffset + root.cardIndex
    if (root.view === "playing" && root.cardLocked && !root.correctionRequired
        && root.feedbackKind === "hit") completed += 1
    return Math.max(0, Math.min(root.sessionSize, completed))
  }

  function pendingReinforcementCount() {
    return Object.keys(root.pendingReinforcements || {}).length
  }

  function setReinforcementPending(bindingId, pending) {
    var updated = Session.safeMap()
    Object.keys(root.pendingReinforcements || {}).forEach(function(id) {
      updated[id] = root.pendingReinforcements[id]
    })
    if (pending) updated[bindingId] = true
    else delete updated[bindingId]
    root.pendingReinforcements = updated
  }

  function hasResumableSession() {
    var session = store.session
    return Boolean(store.ready && session && Stats.validRunId(session.runId)
        && session.runId <= Stats.sequenceValue(store.stats.runSequence)
        && Session.canResume(session, session.runId, root.eligibleBindings,
                             root.runCardLimit, root.deckId))
  }

  // Reserve and queue the high-water write before any new session snapshot.
  // An abandoned deal still consumes its identity; deck counters move only
  // when a run finishes. The chosen deck never supplies this identity.
  function allocateSessionIdentity() {
    if (!store.ready) return 0
    try {
      var identity = Stats.allocateRunIdentity(store.stats)
      root.sessionRunIdentity = identity
      store.stats = Object.assign({}, store.stats)
      store.saveStats()
      return identity
    } catch (identityError) {
      root.errorMessage = i18n.t("runIdentityExhausted")
      guard.fail(root.errorMessage)
      return 0
    }
  }

  function saveRunSession() {
    if (root.view !== "playing") return
    var resumeIndex = root.cardIndex
    var resumeCorrection = root.correctionRequired
    if (root.cardLocked && !root.correctionRequired && root.feedbackKind === "hit") resumeIndex += 1
    var cards = Session.cardsFrom(root.deck, resumeIndex).filter(function(card) {
      return root.eligibleBindings.some(function(binding) { return binding.id === card.bindingId })
    })
    root.sessionSize = root.runOffset + resumeIndex + cards.length
    if (!cards.length) {
      store.clearSession()
      root.resumeAvailable = false
      return
    }
    store.saveSession({
      schemaVersion: 2,
      deckId: root.deckId,
      sessionSize: root.runOffset + resumeIndex + cards.length,
      runNumber: root.runNumber,
      runId: root.sessionRunIdentity,
      offset: root.runOffset + resumeIndex,
      cards: cards,
      correct: root.correct,
      attempts: root.attempts,
      newLearned: root.newLearned,
      masteredGained: root.masteredGained,
      runReviewTarget: root.runReviewTarget,
      runNewTarget: root.runNewTarget,
      pendingReinforcements: Object.keys(root.pendingReinforcements || {}),
      reactions: root.reactions,
      runResults: Session.serializableResults(root.runResults),
      correctionRequired: resumeCorrection && resumeIndex === root.cardIndex
          && cards[0].bindingId === root.currentBinding.id,
      savedAt: Date.now()
    })
    root.resumeAvailable = true
  }

  function resumeRun() {
    if (root.browseOpen || !root.hasResumableSession() || !guard.active || root.groundLoading || root.view === "playing") return
    var session = store.session
    var offset = Math.max(0, Math.min(root.runCardLimit - 1, Number(session.offset || 0)))
    var restoredDeck = Session.restoreCards(session.cards, root.eligibleBindings)
    restoredDeck = restoredDeck.slice(0, root.runCardLimit - offset)
    if (!restoredDeck.length) {
      store.clearSession()
      root.resumeAvailable = false
      startRun()
      return
    }
    try {
      root.sessionRunIdentity = Stats.adoptRunIdentity(store.stats, session.runId)
    } catch (identityError) {
      root.errorMessage = i18n.t("runIdentityInvalid")
      guard.fail(root.errorMessage)
      return
    }
    guard.play()
    root.deck = restoredDeck
    root.cardIndex = 0
    root.runOffset = offset
    root.sessionSize = offset + restoredDeck.length
    root.runNumber = session.runNumber || root.nextRunNumber
    root.correct = Math.max(0, Number(session.correct || 0))
    root.attempts = Math.max(0, Number(session.attempts || 0))
    root.newLearned = Math.max(0, Number(session.newLearned || 0))
    root.masteredGained = Math.max(0, Number(session.masteredGained || 0))
    var plan = Scheduler.planCounts(restoredDeck)
    root.runReviewTarget = Math.max(0, Number(session.runReviewTarget === undefined
                                             ? plan.review : session.runReviewTarget))
    root.runNewTarget = Math.max(0, Number(session.runNewTarget === undefined
                                          ? plan.added : session.runNewTarget))
    root.pendingReinforcements = Session.safeMap()
    var pendingIds = Array.isArray(session.pendingReinforcements) ? session.pendingReinforcements : []
    for (var pendingIndex = 0; pendingIndex < pendingIds.length; pendingIndex++)
      if (root.eligibleBindings.some(function(card) { return card.id === pendingIds[pendingIndex] }))
        root.setReinforcementPending(String(pendingIds[pendingIndex]), true)
    root.reactions = Array.isArray(session.reactions) ? session.reactions : []
    root.runResults = Session.restoreResults(session.runResults, root.eligibleBindings)
    root.reviewSuggestions = []
    root.activeSegmentStartedAt = Date.now()
    root.view = "playing"
    showCard(Session.resumeCorrection(session, restoredDeck))
  }

  function startPrimary() {
    if (root.browseOpen) return
    if (root.view === "home" && root.resumeAvailable) resumeRun()
    else startRun()
  }

  function startRun() {
    if (root.browseOpen) return
    if (root.view !== "home" && root.view !== "summary") return
    // The home screen stays up while a cabinet loads, so START can be reached
    // before the table it would deal from has arrived.
    if (root.groundLoading || !store.ready) return
    if (!root.eligibleBindings.length) { root.startRefusal = "empty-deck"; return }
    root.startRefusal = ""
    if (!guard.active) {
      guard.fail("Shortcut inhibition is not active.")
      return
    }
    if (!root.allocateSessionIdentity()) return
    guard.play()
    store.clearSession()
    root.resumeAvailable = false
    root.runNumber = root.nextRunNumber
    root.deck = Scheduler.build(root.eligibleBindings, store.stats, root.runCardLimit,
                                { runId: root.activeRunId, deckId: root.deckId })
    root.sessionSize = root.deck.length
    var plan = Scheduler.planCounts(root.deck)
    root.runReviewTarget = plan.review
    root.runNewTarget = plan.added
    root.cardIndex = 0
    root.runOffset = 0
    root.correct = 0
    root.attempts = 0
    root.newLearned = 0
    root.masteredGained = 0
    root.reactions = []
    root.combo = 0
    root.runResults = Session.safeMap()
    root.pendingReinforcements = Session.safeMap()
    root.reviewSuggestions = []
    root.correctionRequired = false
    refreshProgressCounts()
    store.saveStats()
    root.activeSegmentStartedAt = Date.now()
    root.view = "playing"
    showCard()
  }

  function showCard(resumeCorrection) {
    feedbackTimer.stop()
    cardTimer.stop()
    sounds.stopCountdown()
    if (root.cardIndex >= root.deck.length) {
      finishRun()
      return
    }
    root.cardLocked = false
    root.correctionRequired = false
    root.cardErrorSoundPlayed = false
    root.answerStep = 0
    root.answerState = AnswerMatcher.begin()
    root.inputSilentUntil = root.overrunGuardArmed ? Date.now() + root.overrunGuardMs : 0
    root.overrunGuardArmed = false
    root.feedbackKind = "idle"
    root.revealChord = root.currentCard.tier === "guided"
    root.feedbackText = i18n.t(root.currentCard.tier === "guided" ? "copyChord" : "waiting")
    root.cardStartedAt = Date.now()
    root.lastCountdownBeat = 0
    root.countdownSeconds = 0
    if (root.currentCard.queue === "unseen") {
      Scheduler.markCovered(root.eligibleBindings, store.stats, root.currentBinding.id, root.deckId)
      store.saveStats()
    }
    if (resumeCorrection) {
      root.correctionRequired = true
      root.revealChord = true
      root.feedbackText = i18n.t("correctionPrompt")
      root.energy = 1
      root.deadline = 0
      saveRunSession()
      return
    }
    var duration = Scheduler.durationFor(root.currentCard, store.stats)
    root.energy = 1
    root.deadline = duration ? Date.now() + duration : 0
    if (duration) cardTimer.start()
    saveRunSession()
  }

  function handleGameInput(event) {
    if (root.view !== "playing" || root.cardLocked || !root.currentBinding) return
    if (root.inputSilentUntil > 0 && Date.now() < root.inputSilentUntil) return
    if (event.isAutoRepeat || Normalizer.isModifier(event.key)) return
    var state = root.answerState
    var verdict = AnswerMatcher.advance(state, root.currentAnswer, event)
    root.answerState = state
    root.answerStep = AnswerMatcher.typedSteps(state)
    // A step landed and more remain: the card's own deadline keeps running,
    // and the step lights up. There is no per-step deadline on purpose.
    if (verdict === "progress") return
    var received = AnswerMatcher.inputDisplay(root.currentAnswer, event)
    if (root.correctionRequired) {
      if (verdict === "hit") completeCorrection()
      else missCorrection(received)
      return
    }
    if (verdict === "hit") hitCurrent()
    else missCurrent("received", received)
  }

  // Correcting a sequence means typing it again from the start: a wrong key
  // fails the card whole, and the muscle memory for one is the whole run of it.
  function beginCorrection() {
    if (!root.correctionRequired || root.view !== "playing") return
    root.answerStep = 0
    root.answerState = AnswerMatcher.begin()
    root.cardLocked = false
    root.revealChord = true
    root.feedbackKind = "idle"
    root.feedbackText = i18n.t("correctionPrompt")
    root.deadline = 0
    root.energy = 1
  }

  function missCorrection(received) {
    root.revealChord = true
    root.feedbackKind = "miss"
    root.feedbackText = i18n.t("correctionMiss", { keys: received || "?" })
    if (!root.reducedMotion) missShake.restart()
  }

  function completeCorrection() {
    root.cardLocked = true
    root.overrunGuardArmed = AnswerMatcher.overruns(root.currentAnswer)
    root.correctionRequired = false
    root.revealChord = true
    root.feedbackKind = "hit"
    root.feedbackText = i18n.t("correctionHit")
    if (!root.reducedMotion) hitFlash.restart()
    saveRunSession()
    feedbackTimer.interval = 320
    feedbackTimer.restart()
  }

  function scheduleRetest(binding) {
    root.setReinforcementPending(binding.id, true)
    root.deck = Scheduler.insertRemedial(root.deck, root.cardIndex, binding)
  }

  function retryGuided() {
    root.answerStep = 0
    root.answerState = AnswerMatcher.begin()
    root.cardLocked = false
    root.feedbackKind = "idle"
    root.feedbackText = i18n.t("copyChord")
    root.revealChord = true
    root.deadline = 0
    root.energy = 1
    saveRunSession()
  }

  function hitCurrent() {
    if (root.cardLocked) return
    root.cardLocked = true
    root.overrunGuardArmed = AnswerMatcher.overruns(root.currentAnswer)
    cardTimer.stop()
    sounds.stopCountdown()
    var reaction = Math.max(0, Date.now() - root.cardStartedAt)
    var guided = root.currentCard.tier === "guided"
    var hitResult = root.runResults[root.currentBinding.id] || { binding: root.currentBinding, misses: 0, reactions: [] }
    if (guided) {
      var before = Stats.entry(store.stats, root.currentBinding.id)
      if (!before.guidedCompleted) root.newLearned += 1
      Stats.recordGuided(store.stats, root.currentBinding.id, root.activeRunId, Date.now())
      for (var i = root.cardIndex + 1; i < root.deck.length; i++) {
        if (root.deck[i].binding.id === root.currentBinding.id) root.deck[i].tier = "learning"
      }
      root.deck = root.deck.slice()
      scheduleRetest(root.currentBinding)
    } else {
      if (root.currentCard.remedial)
        root.setReinforcementPending(root.currentBinding.id, false)
      root.correct += 1
      root.attempts += 1
      root.reactions = root.reactions.concat([reaction])
      hitResult.reactions.push(reaction)
      var transition = Stats.recordFirstTry(store.stats, root.currentBinding.id, true,
                                            reaction, root.activeRunId, Date.now())
      if (transition.masteredGained) root.masteredGained += 1
      root.combo += 1
      if (root.combo % 5 === 0) sounds.playCombo()
    }
    root.runResults[root.currentBinding.id] = hitResult
    refreshProgressCounts()
    if (finishAtFirstMastery()) return
    store.saveStats()
    root.revealChord = true
    root.feedbackKind = "hit"
    root.feedbackText = guided ? i18n.t("guidedHit")
                               : i18n.t("hitReaction", { ms: Math.round(reaction) })
    saveRunSession()
    sounds.playCorrect()
    if (!root.reducedMotion) hitFlash.restart()
    feedbackTimer.interval = 320
    feedbackTimer.restart()
  }

  function missCurrent(reason, received) {
    root.combo = 0
    if (root.cardLocked) return
    cardTimer.stop()
    sounds.stopCountdown()
    var guided = root.currentCard.tier === "guided"
    root.cardLocked = true
    root.feedbackKind = "miss"
    if (!root.cardErrorSoundPlayed) {
      sounds.playWrong()
      root.cardErrorSoundPlayed = true
    }
    if (guided) {
      root.feedbackText = i18n.t("guidedMiss", { keys: received || "?" })
      if (!root.reducedMotion) missShake.restart()
      feedbackTimer.interval = 700
      feedbackTimer.restart()
      saveRunSession()
      return
    }
    root.correctionRequired = true
    root.attempts += 1
    root.revealChord = true
    root.feedbackText = i18n.t(reason === "timeout" ? "timeout" : "miss")
    Stats.recordFirstTry(store.stats, root.currentBinding.id, false, -1,
                         root.activeRunId, Date.now())
    scheduleRetest(root.currentBinding)
    var missResult = root.runResults[root.currentBinding.id] || { binding: root.currentBinding, misses: 0, reactions: [] }
    missResult.misses += 1
    root.runResults[root.currentBinding.id] = missResult
    refreshProgressCounts()
    store.saveStats()
    saveRunSession()
    if (!root.reducedMotion) missShake.restart()
    feedbackTimer.interval = 700
    feedbackTimer.restart()
  }

  function advanceCard() {
    if (root.currentCard && root.currentCard.tier === "guided" && root.feedbackKind === "miss") {
      retryGuided()
      return
    }
    root.cardIndex += 1
    if (root.cardIndex >= root.deck.length) {
      finishRun()
      return
    }
    showCard()
  }

  function finishRun(showMastery) {
    cardTimer.stop()
    commitActiveTraining()
    store.clearSession()
    root.resumeAvailable = false
    root.sessionRunIdentity = 0
    // The counter lives inside the deck record, so bumping it mutates
    // store.stats in place. Reassign anyway: it's a property var, so a plain
    // mutation never fires statsChanged, and root.nextRunNumber (a binding
    // through store.stats) would stay frozen instead of counting completed
    // runs. This visible number is deliberately not the scheduling identity.
    Stats.completeRun(store.stats, root.deckId)
    store.stats = Object.assign({}, store.stats)
    var resultRows = Object.keys(root.runResults).filter(function(id) {
      return root.eligibleBindings.some(function(binding) { return binding.id === id })
    }).map(function(id) { return root.runResults[id] })
    resultRows.sort(function(left, right) {
      if (left.misses !== right.misses) return right.misses - left.misses
      return Stats.percentile75(right.reactions) - Stats.percentile75(left.reactions)
    })
    root.reviewSuggestions = resultRows.slice(0, 3)
    refreshProgressCounts()
    root.masterySnapshot = Stats.aggregate(store.stats, root.eligibleBindings)
    var counters = root.profileCounters()
    if (Number(counters.firstMasteryAt || 0) > 0 && !Boolean(counters.firstMasteryCelebrated)) {
      if (showMastery === false) root.view = "summary"
      else root.showFirstMastery()
    } else root.view = "summary"
    store.saveStats()
  }

  function accuracyPercent() {
    return root.attempts ? Math.round(root.correct / root.attempts * 100) : 0
  }

  function p75Reaction() {
    return Stats.percentile75(root.reactions)
  }

  function requestHint(bindingId) {
    try {
      Stats.requestGuidance(store.stats, bindingId, root.activeRunId)
    } catch (identityError) {
      root.errorMessage = i18n.t("runIdentityExhausted")
      guard.fail(root.errorMessage)
      return
    }
    refreshProgressCounts()
    store.saveStats()
  }

  I18n { id: i18n }
  SoundManager {
    id: sounds
    feedbackEnabled: Boolean(store.settings.feedbackSound)
    countdownEnabled: Boolean(store.settings.countdownSound)
    volume: Number(store.settings.soundVolume || 0.4)
  }
  StateStore {
    id: store
    onReadyChanged: {
      root.reconcileDeckState()
      root.maybeShowHome()
    }
    onFailed: function(message) {
      root.errorMessage = message
      guard.fail(message)
    }
  }
  AppConfigSource {
    id: appConfig
    onFinished: root.applyDetectedConfig()
  }
  PackSource {
    id: packs
    onLoaded: root.groundReady()
    onFailed: function(message) {
      root.errorMessage = message
      guard.fail(message)
    }
  }

  InputGuard {
    id: guard
    window: panel
    keyboardFocused: keyCatcher.activeFocus
    onReady: {
      root.guardReady = true
      root.maybeShowHome()
    }
    onBlocked: function(message) {
      root.errorMessage = message
      root.view = "blocked"
      blockedClose.restart()
    }
    onClosed: root.dismiss()
  }

  Timer {
    id: cardTimer
    interval: 33
    repeat: true
    onTriggered: {
      var remaining = root.deadline - Date.now()
      var duration = root.deadline - root.cardStartedAt
      root.energy = Math.max(0, remaining / duration)
      var beat = Math.ceil(remaining / 1000)
      root.countdownSeconds = Math.max(0, Math.min(99, beat))
      if (beat > 0 && beat <= 3 && beat !== root.lastCountdownBeat) {
        root.lastCountdownBeat = beat
        sounds.playCountdown(beat === 1)
      }
      if (remaining <= 0) {
        stop()
        root.missCurrent("timeout", "")
      }
    }
  }

  Timer {
    id: feedbackTimer
    repeat: false
    onTriggered: {
      if (root.correctionRequired) root.beginCorrection()
      else root.advanceCard()
    }
  }
  Timer { id: blockedClose; interval: 5000; repeat: false; onTriggered: root.dismiss() }

  // The stamp holds for a fixed beat so the exclusion is legible, then the run
  // moves on. reducedMotion drops the fade, never this delay: the confirmation
  // is the point.
  Timer {
    id: excludeStampTimer
    interval: root.excludeStampMs
    repeat: false
    onTriggered: {
      root.excludeStampVisible = false
      if (root.excludedCardId) root.dropExcludedCard(root.excludedCardId)
      root.excludedCardId = ""
      if (root.finishAtFirstMastery()) return
      if (root.view !== "playing") return
      if (root.cardIndex >= root.deck.length) root.finishRun()
      else root.showCard()
    }
  }

  SequentialAnimation {
    id: hitFlash
    NumberAnimation { target: cardGlow; property: "opacity"; to: 1; duration: 50 }
    PauseAnimation { duration: 45 }
    NumberAnimation { target: cardGlow; property: "opacity"; to: 0; duration: 160 }
  }

  SequentialAnimation {
    id: excludedPulse
    NumberAnimation { target: excludedLamp; property: "opacity"; to: 1; duration: 90 }
    NumberAnimation { target: excludedLamp; property: "opacity"; to: 0; duration: 420 }
  }

  SequentialAnimation {
    id: missShake
    NumberAnimation { target: cardShift; property: "x"; to: -8; duration: 45 }
    NumberAnimation { target: cardShift; property: "x"; to: 8; duration: 55 }
    NumberAnimation { target: cardShift; property: "x"; to: -4; duration: 55 }
    NumberAnimation { target: cardShift; property: "x"; to: 0; duration: 55 }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "keycade-lazyvim"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: guard.wantsFocus ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    onVisibleChanged: if (visible) Qt.callLater(function() { keyCatcher.forceActiveFocus() })

    Rectangle {
      anchors.fill: parent
      color: root.voidColor
      opacity: 0.96
    }

    Item {
      id: keyCatcher
      objectName: "keyCatcher"
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem

      Keys.onPressed: function(event) { keyCatcher.handlePressed(event) }
      function handlePressed(event) {
        guard.updateInput(Normalizer.modifierMask(event.modifiers))
        if (event.isAutoRepeat) { event.accepted = true; return }
        if (root.handleBrowseKey(event)) return
        // Whether this Escape is a bare safe-exit or part of a modifier chord
        // (e.g. Super + Esc) is decided on release, not here: on a fast chord
        // Wayland can deliver the "modifiers" update for a just-pressed Super
        // slightly after this Escape press event, so event.modifiers briefly
        // under-reports it at press time. The release event has consistently
        // shown the correct modifiers by the time it arrives.
        if (event.key === Qt.Key_Escape) {
          if (root.languageMenuOpen || root.soundMenuOpen || root.excludedMenuOpen || root.themeMenuOpen) {
            root.closeTopMenus()
            root.escapeDown = false
            event.accepted = true
            return
          }
          root.escapeDown = true
          event.accepted = true
          return
        }
        // Swallowed, not queued. Home is where the training ground is picked,
        // so no path may skip it: queuing a start here rendered home for a
        // single frame and began a run on whichever ground happened to be
        // active, which put the one control that chooses the deck out of
        // reach of anyone who launches and presses Enter in one motion.
        if (root.view === "loading"
            && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
          event.accepted = true
          return
        }
        if (root.view === "mastery"
            && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
          event.accepted = true
          return
        }
        if ((root.view === "home" || root.view === "summary")
            && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
          root.startPrimary()
          event.accepted = true
          return
        }
        if (root.view === "playing") {
          root.handleGameInput(event)
          event.accepted = true
        }
      }

      Keys.onReleased: function(event) { keyCatcher.handleReleased(event) }
      function handleReleased(event) {
        guard.updateInput(Normalizer.modifierMask(event.modifiers))
        if (event.key === Qt.Key_Escape && root.escapeDown) {
          root.escapeDown = false
          if (Normalizer.modifierMask(event.modifiers) === 0) {
            root.requestSafeClose()
          } else if (root.view === "playing") {
            root.handleGameInput(event)
          }
        }
        event.accepted = true
      }
    }

    Rectangle {
      id: cabinetShadow
      width: Math.min(1040, panel.width - 64)
      height: Math.min(720, panel.height - 64)
      anchors.centerIn: parent
      anchors.horizontalCenterOffset: 12
      anchors.verticalCenterOffset: 12
      color: "#05070e"
    }

    Rectangle {
      id: cabinet
      width: cabinetShadow.width
      height: cabinetShadow.height
      anchors.centerIn: parent
      color: root.cabinetColor
      border.width: 4
      border.color: root.inkColor

      Rectangle { width: 12; height: 12; anchors.left: parent.left; anchors.top: parent.top; color: root.voidColor }
      Rectangle { width: 12; height: 12; anchors.right: parent.right; anchors.top: parent.top; color: root.voidColor }
      Rectangle { width: 12; height: 12; anchors.left: parent.left; anchors.bottom: parent.bottom; color: root.voidColor }
      Rectangle { width: 12; height: 12; anchors.right: parent.right; anchors.bottom: parent.bottom; color: root.voidColor }

      Rectangle {
        id: topbar
        z: 20
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 4
        height: 88
        color: root.primaryColor

        Rectangle {
          width: 50; height: 50
          anchors.left: parent.left; anchors.leftMargin: 24
          anchors.verticalCenter: parent.verticalCenter
          color: root.voidColor
          border.width: 4; border.color: root.voidColor
          SafeText {
            anchors.centerIn: parent
            text: "K"
            color: root.primaryColor
            font.family: "JetBrainsMono Nerd Font"
            font.pixelSize: 30
            font.bold: true
          }
        }

        Column {
          objectName: "topBrand"
          anchors.left: parent.left; anchors.leftMargin: 92
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(0, topControls.x - x - 12)
          spacing: 2
          SafeText { width: parent.width; elide: Text.ElideRight; text: "KEYCADE"; color: root.voidColor; font.family: "monospace"; font.pixelSize: 32; font.bold: true; font.letterSpacing: 4 }
          Row {
            width: parent.width
            spacing: 8
            SafeText {
              visible: topbar.width >= 1000 && root.view !== "playing"
              anchors.verticalCenter: parent.verticalCenter
              text: i18n.t("brandSubtitle"); color: root.voidColor
              font.family: "monospace"; font.pixelSize: 11; font.bold: true
            }
            // Which deck this is. The home screen names it too, but a run
            // is played away from the home screen, and "which deck am I on"
            // has to be answerable without leaving the run to find out.
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              // Bounded: a user-declared deck name can be 48 codepoints, and
              // it must never run under the top-bar controls.
              width: Math.min(parent.width, 148, groundBadge.implicitWidth + 16); height: 18
              color: root.voidColor
              SafeText {
                id: groundBadge
                objectName: "groundBadge"
                anchors.centerIn: parent
                width: Math.max(0, Math.min(implicitWidth, parent.width - 16))
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight; maximumLineCount: 1
                text: root.headerDeckName() || i18n.t("profile_" + root.profileId)
                color: root.primaryColor
                font.family: "monospace"; font.pixelSize: 10; font.bold: true; font.letterSpacing: 2
              }
            }
          }
        }

        Grid {
          id: topControls
          objectName: "topControls"
          anchors.right: parent.right; anchors.rightMargin: 22
          anchors.verticalCenter: parent.verticalCenter
          columns: root.view === "playing" ? 4 : topbar.width < 930 ? 3 : 5
          spacing: 8

          Rectangle {
            objectName: "browseButton"
            width: root.topButtonWidth; height: 36
            opacity: root.browseAvailable ? 1 : 0.4
            color: root.browseOpen ? root.voidColor : root.screenColor
            border.width: 3; border.color: root.voidColor
            SafeText {
              anchors.centerIn: parent; width: parent.width - 12
              horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
              text: i18n.t("browse"); color: root.browseOpen ? root.primaryColor : root.inkColor
              font.family: "monospace"; font.bold: true; font.pixelSize: 10
            }
            MouseArea {
              objectName: "browseButtonArea"
              anchors.fill: parent; enabled: root.browseAvailable
              onClicked: root.toggleBrowse()
            }
          }

          Rectangle {
            id: leaveButton
            width: root.topButtonWidth; height: 36
            visible: root.view === "playing"
            color: root.screenColor; border.width: 3; border.color: root.mutedColor
            SafeText {
              anchors.centerIn: parent; width: parent.width - 12
              horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; maximumLineCount: 1
              text: i18n.t("leaveRun")
              color: root.inkColor; font.family: "monospace"; font.bold: true; font.pixelSize: 10
            }
            MouseArea { anchors.fill: parent; onClicked: root.leaveRun() }
          }
          Rectangle {
            id: excludeButton
            width: root.topButtonWidth; height: 36
            visible: root.view === "playing"
            color: root.screenColor; border.width: 3; border.color: root.dangerColor
            SafeText {
              anchors.centerIn: parent; width: parent.width - 12
              horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; maximumLineCount: 1
              text: i18n.t("excludeAction")
              color: root.dangerColor; font.family: "monospace"; font.bold: true; font.pixelSize: 10
            }
            MouseArea { anchors.fill: parent; onClicked: root.excludeCurrentBinding() }
          }
          Rectangle {
            id: excludedButton
            width: root.topButtonWidth; height: 36; color: root.screenColor; border.width: 3; border.color: root.voidColor
            Rectangle { id: excludedLamp; anchors.fill: parent; color: root.coinColor; opacity: 0 }
            SafeText {
              anchors.centerIn: parent; width: parent.width - 12
              horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; maximumLineCount: 1
              text: i18n.t("excludedMenu", { count: root.excludedRows.length + root.staleExcludedCount }) + " ▾"
              color: root.inkColor; font.family: "monospace"; font.bold: true; font.pixelSize: 10
            }
            MouseArea {
              objectName: "excludedButtonArea"
              anchors.fill: parent
              onClicked: {
                root.closeBrowse()
                root.excludedMenuOpen = !root.excludedMenuOpen
                root.soundMenuOpen = false
                root.languageMenuOpen = false
                root.themeMenuOpen = false
              }
            }
          }
          Rectangle {
            id: soundButton
            width: root.topButtonWidth; height: 36; color: root.screenColor; border.width: 3; border.color: root.voidColor
            SafeText {
              anchors.centerIn: parent; width: parent.width - 12
              horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; maximumLineCount: 1
              text: store.settings.feedbackSound || store.settings.countdownSound
                    ? i18n.t("soundVolume", { volume: Math.round(Number(store.settings.soundVolume || 0.4) * 100) })
                    : i18n.t("soundOff")
              color: store.settings.feedbackSound || store.settings.countdownSound ? root.successColor : root.mutedColor
              font.family: "monospace"; font.bold: true; font.pixelSize: 10
            }
            MouseArea {
              objectName: "soundButtonArea"
              anchors.fill: parent
              onClicked: {
                root.closeBrowse()
                root.soundMenuOpen = !root.soundMenuOpen
                root.languageMenuOpen = false
                root.excludedMenuOpen = false
                root.themeMenuOpen = false
              }
            }
          }
          Rectangle {
            id: languageButton
            width: root.topButtonWidth; height: 36; color: root.screenColor; border.width: 3; border.color: root.voidColor
            SafeText {
              anchors.centerIn: parent; width: parent.width - 12
              horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; maximumLineCount: 1
              text: root.localeLabel(i18n.locale) + " ▾"
              color: root.inkColor; font.family: "monospace"; font.bold: true; font.pixelSize: 10
            }
            MouseArea {
              objectName: "languageButtonArea"
              anchors.fill: parent
              onClicked: {
                root.closeBrowse()
                root.languageMenuOpen = !root.languageMenuOpen
                root.soundMenuOpen = false
                root.excludedMenuOpen = false
                root.themeMenuOpen = false
              }
            }
          }
          Rectangle {
            id: themeButton
            width: root.topButtonWidth; height: 36; color: root.screenColor; border.width: 3; border.color: root.voidColor
            SafeText {
              anchors.centerIn: parent; width: parent.width - 12
              horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; maximumLineCount: 1
              text: root.themeName.toUpperCase() + " ▾"
              color: root.inkColor; font.family: "monospace"; font.bold: true; font.pixelSize: 10
            }
            MouseArea {
              objectName: "themeButtonArea"
              anchors.fill: parent
              onClicked: {
                root.closeBrowse()
                root.themeMenuOpen = !root.themeMenuOpen
                root.soundMenuOpen = false
                root.languageMenuOpen = false
                root.excludedMenuOpen = false
              }
            }
          }
        }
      }

      // A modal curation surface inside the cabinet, never a second focus
      // owner. Only corpus/target lists scroll; the close control stays visible.
      Rectangle {
        id: browseDrawer
        objectName: "browseDrawer"
        anchors.left: parent.left; anchors.right: parent.right
        anchors.top: topbar.bottom; anchors.bottom: statusStrip.top
        anchors.leftMargin: 22; anchors.rightMargin: 22
        anchors.topMargin: 10; anchors.bottomMargin: 10
        visible: root.browseOpen
        z: 100
        color: root.cabinetColor; border.width: 3; border.color: root.primaryColor
        clip: true
        MouseArea {
          objectName: "browseBackdrop"
          anchors.fill: parent
          onWheel: function(wheel) { wheel.accepted = true }
        }

        Row {
          id: browseHeader
          anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
          anchors.margins: 12
          height: 34; spacing: 8
          Rectangle {
            width: parent.width - 88; height: parent.height
            color: root.screenColor; border.width: 2; border.color: root.primaryColor
            SafeText {
              objectName: "browseTargetName"
              anchors.fill: parent; anchors.margins: 8
              verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
              text: i18n.t("browseTarget", { name: root.deckDisplayName(root.browseTarget) || i18n.t("browseTargetUnavailable") })
              color: root.inkColor; font.family: "monospace"; font.pixelSize: 12; font.bold: true
            }
            MouseArea {
              objectName: "browseTargetArea"
              anchors.fill: parent
              onClicked: root.browseTargetsOpen = !root.browseTargetsOpen
            }
          }
          BrowseChip {
            objectName: "browseClose"
            width: 80; height: parent.height; label: i18n.t("browseClose")
            onPicked: root.closeBrowse()
          }
        }

        Column {
          id: browseFilters
          anchors.left: parent.left; anchors.right: parent.right; anchors.top: browseHeader.bottom
          anchors.leftMargin: 12; anchors.rightMargin: 12; anchors.topMargin: 8
          spacing: 6
          enabled: !root.browseTargetsOpen
          ListView {
            id: browseCategoryList
            objectName: "browseCategories"
            width: parent.width; height: 28; orientation: ListView.Horizontal
            spacing: 6; clip: true; boundsBehavior: Flickable.StopAtBounds
            model: [""].concat(root.browseCategories)
            delegate: BrowseChip {
              required property string modelData
              objectName: "browseCategory:" + modelData
              label: modelData ? i18n.t("category_" + modelData) : i18n.t("browseAllCategories")
              selected: root.browseCategory === modelData
              onPicked: root.browseCategory = modelData
            }
          }
          ListView {
            id: browseSourceList
            objectName: "browseSources"
            width: parent.width; height: 28; orientation: ListView.Horizontal
            spacing: 6; clip: true; boundsBehavior: Flickable.StopAtBounds
            model: ["", "custom"].concat(root.browseExtras)
            delegate: BrowseChip {
              required property string modelData
              objectName: "browseSource:" + modelData
              label: modelData === "custom" ? i18n.t("browseCustom")
                  : modelData ? modelData.split(".").pop() : i18n.t("browseAllSources")
              selected: root.browseSource === modelData
              onPicked: root.browseSource = modelData
            }
          }
          Row {
            width: parent.width; height: 28; spacing: 6
            BrowseChip {
              objectName: "browseAllCards"
              label: i18n.t("browseAllCards"); selected: !root.browseInDeck
              onPicked: root.browseInDeck = false
            }
            BrowseChip {
              objectName: "browseInDeck"
              label: i18n.t("browseInDeck"); selected: root.browseInDeck
              onPicked: root.browseInDeck = true
            }
            SafeText {
              objectName: "browseCount"
              width: Math.max(0, parent.width - x); height: parent.height
              verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
              text: i18n.t("browseCounts", {
                cards: root.browseRows.length,
                total: root.deckProgress[root.browseTargetId] ? root.deckProgress[root.browseTargetId].total : 0
              })
              color: root.mutedColor; font.family: "monospace"; font.pixelSize: 10
            }
          }
        }

        ListView {
          id: browseList
          objectName: "browseList"
          anchors.left: parent.left; anchors.right: parent.right
          anchors.top: browseFilters.bottom; anchors.bottom: browseNotice.top
          anchors.leftMargin: 12; anchors.rightMargin: 12; anchors.topMargin: 8; anchors.bottomMargin: 6
          model: root.browseRows
          enabled: !root.browseTargetsOpen
          clip: true; spacing: 4; boundsBehavior: Flickable.StopAtBounds
          delegate: Rectangle {
            id: browseRow
            required property string modelData
            objectName: "browseRow:" + modelData
            readonly property var binding: root.browseCard(modelData)
            readonly property var membership: root.deckMembership(root.browseTargetId, modelData)
            width: browseList.width; height: 78
            color: root.screenColor
            Column {
              anchors.left: parent.left; anchors.top: parent.top
              anchors.leftMargin: 8; anchors.topMargin: 7
              width: Math.max(0, parent.width - browseAction.width - 24); spacing: 4
              SafeText {
                objectName: "browsePrompt"
                width: parent.width; elide: Text.ElideRight; maximumLineCount: 1
                text: root.actionName(browseRow.binding)
                color: root.inkColor; font.family: "monospace"; font.pixelSize: 12; font.bold: true
              }
              SafeText {
                objectName: "browseNotation"
                width: parent.width; elide: Text.ElideRight; maximumLineCount: 1
                text: browseRow.binding ? browseRow.binding.notation : ""
                color: root.coinColor; font.family: "monospace"; font.pixelSize: 11
              }
              SafeText {
                objectName: "browseBadges"
                width: parent.width; elide: Text.ElideRight; maximumLineCount: 1
                text: (browseRow.binding ? i18n.t("context_" + browseRow.binding.answer.context) : "")
                    + " · " + root.otherDecks(browseRow.modelData, root.browseTargetId).slice(0, 33)
                        .map(function(definition) { return root.deckDisplayName(definition) }).join(" · ")
                color: root.mutedColor; font.family: "monospace"; font.pixelSize: 10
              }
            }
            Rectangle {
              id: browseAction
              width: 150; height: 34
              anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
              color: root.voidColor; border.width: 2
              border.color: browseRow.membership.member ? root.successColor : root.mutedColor
              opacity: root.browseTarget && root.browseTargetId !== "all" ? 1 : 0.4
              SafeText {
                objectName: "browseMembership"
                anchors.fill: parent; anchors.margins: 6
                verticalAlignment: Text.AlignVCenter; horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight; maximumLineCount: 1
                text: root.browseMembershipLabel(browseRow.membership)
                color: browseRow.membership.member ? root.successColor : root.inkColor
                font.family: "monospace"; font.pixelSize: 10; font.bold: true
              }
              MouseArea {
                objectName: "browseMembershipArea"
                anchors.fill: parent
                enabled: root.browseAvailable && root.browseTarget !== null && root.browseTargetId !== "all"
                onClicked: root.toggleBrowseCard(browseRow.modelData)
              }
            }
          }
        }
        SafeText {
          anchors.centerIn: browseList
          width: browseList.width; horizontalAlignment: Text.AlignHCenter
          visible: !root.browseRows.length
          text: i18n.t("browseNoMatches")
          color: root.mutedColor; font.family: "monospace"; font.pixelSize: 12
          elide: Text.ElideRight
        }
        SafeText {
          id: browseNotice
          objectName: "browseNotice"
          anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
          anchors.margins: 12
          height: 30
          text: root.browseWarning || (!root.browseTarget ? i18n.t("browseTargetMissing")
              : root.browseTargetId === "all" ? i18n.t("browseAllReadOnly")
              : root.deckConfigNote())
          color: root.coinColor; font.family: "monospace"; font.pixelSize: 10
          wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
        }

        // The selector stays bounded even with all 33 definitions. Its blanket
        // dismisses only this menu, never activates a row underneath it.
        Item {
          anchors.fill: parent; anchors.topMargin: 52
          visible: root.browseTargetsOpen; z: 2
          MouseArea { anchors.fill: parent; onClicked: root.browseTargetsOpen = false }
          Rectangle {
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
            anchors.margins: 12
            height: Math.min(parent.height - 24, 230)
            color: root.voidColor; border.width: 2; border.color: root.primaryColor
            ListView {
              id: browseTargets
              objectName: "browseTargets"
              anchors.fill: parent; anchors.margins: 4
              clip: true; boundsBehavior: Flickable.StopAtBounds
              model: root.deckDefinitions.slice(0, 33)
              delegate: Rectangle {
                id: targetRow
                required property var modelData
                objectName: "browseTarget:" + modelData.id
                width: browseTargets.width; height: 30
                color: modelData.id === root.browseTargetId ? root.screenColor : root.voidColor
                SafeText {
                  objectName: "browseTargetLabel"
                  anchors.fill: parent; anchors.margins: 6
                  verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; maximumLineCount: 1
                  text: root.deckDisplayName(targetRow.modelData)
                  color: root.inkColor; font.family: "monospace"; font.pixelSize: 12
                }
                MouseArea {
                  objectName: "browseTargetPick"
                  anchors.fill: parent
                  onClicked: root.chooseBrowseTarget(targetRow.modelData.id)
                }
              }
            }
          }
        }
      }

      Rectangle {
        id: soundMenu
        x: topbar.x + topControls.x + soundButton.x + soundButton.width - width
        y: topbar.y + topbar.height + 8
        width: 250; height: 150
        visible: root.soundMenuOpen
        z: 100
        color: root.cabinetColor; border.width: 3; border.color: root.primaryColor
        Column {
          anchors.fill: parent; anchors.margins: 10; spacing: 8
          SafeText { text: i18n.t("soundSettings"); color: root.inkColor; font.family: "monospace"; font.bold: true; font.pixelSize: 11 }
          Row {
            spacing: 8
            Rectangle {
              width: 38; height: 30; color: root.screenColor; border.width: 2; border.color: root.mutedColor
              SafeText { anchors.centerIn: parent; text: "−"; color: root.inkColor; font.pixelSize: 18; font.bold: true }
              MouseArea { anchors.fill: parent; onClicked: root.adjustSoundVolume(-0.1) }
            }
            SafeText {
              width: 130; height: 30; verticalAlignment: Text.AlignVCenter; horizontalAlignment: Text.AlignHCenter
              text: i18n.t("volumePercent", { volume: Math.round(Number(store.settings.soundVolume || 0.4) * 100) })
              color: root.inkColor; font.family: "monospace"; font.pixelSize: 11; font.bold: true
            }
            Rectangle {
              width: 38; height: 30; color: root.screenColor; border.width: 2; border.color: root.mutedColor
              SafeText { anchors.centerIn: parent; text: "+"; color: root.inkColor; font.pixelSize: 18; font.bold: true }
              MouseArea { anchors.fill: parent; onClicked: root.adjustSoundVolume(0.1) }
            }
          }
          Row {
            spacing: 8
            Rectangle {
              width: 108; height: 32; color: store.settings.feedbackSound ? root.successColor : root.screenColor; border.width: 2; border.color: root.mutedColor
              SafeText { anchors.centerIn: parent; text: i18n.t(store.settings.feedbackSound ? "feedbackOn" : "feedbackOff"); color: store.settings.feedbackSound ? root.voidColor : root.mutedColor; font.family: "monospace"; font.pixelSize: 9; font.bold: true }
              MouseArea { anchors.fill: parent; onClicked: root.toggleSound() }
            }
            Rectangle {
              width: 108; height: 32; color: store.settings.countdownSound ? root.coinColor : root.screenColor; border.width: 2; border.color: root.mutedColor
              SafeText { anchors.centerIn: parent; text: i18n.t(store.settings.countdownSound ? "countdownOn" : "countdownOff"); color: store.settings.countdownSound ? root.voidColor : root.mutedColor; font.family: "monospace"; font.pixelSize: 9; font.bold: true }
              MouseArea { anchors.fill: parent; onClicked: root.toggleCountdownSound() }
            }
          }
        }
      }

      Rectangle {
        id: excludedMenu
        x: topbar.x + topControls.x + excludedButton.x + excludedButton.width - width
        y: topbar.y + topbar.height + 8
        width: 560
        height: 58 + Math.min(240, Math.max(28, root.excludedRows.length * 40))
                + (root.staleExcludedCount > 0 ? 40 : 0)
        visible: root.excludedMenuOpen
        z: 100
        color: root.cabinetColor; border.width: 3; border.color: root.primaryColor
        Column {
          anchors.fill: parent; anchors.margins: 10; spacing: 8
          SafeText { text: i18n.t("excludedTitle"); color: root.inkColor; font.family: "monospace"; font.bold: true; font.pixelSize: 11 }
          SafeText {
            width: parent.width
            visible: root.excludedRows.length === 0
            text: i18n.t("excludedEmpty"); color: root.mutedColor; font.pixelSize: 11
            wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
          }
          Flickable {
            width: parent.width
            height: Math.min(240, root.excludedRows.length * 40)
            visible: root.excludedRows.length > 0
            contentHeight: excludedRowList.height
            clip: true
            Column {
              id: excludedRowList
              width: parent.width
              Repeater {
                model: root.excludedRows
                delegate: Item {
                  id: excludedRow
                  required property var modelData
                  width: excludedRowList.width
                  height: 40
                  Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 10
                    SafeText {
                      width: 196; elide: Text.ElideRight; maximumLineCount: 1
                      text: root.answerDisplay(excludedRow.modelData)
                      color: root.inkColor; font.family: "monospace"; font.pixelSize: 11; font.bold: true
                    }
                    SafeText {
                      width: 204; elide: Text.ElideRight; maximumLineCount: 1
                      text: root.actionName(excludedRow.modelData)
                      color: root.mutedColor; font.pixelSize: 11
                    }
                  }
                  Rectangle {
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    width: 92; height: 28
                    visible: root.view !== "playing"
                    color: root.screenColor; border.width: 2; border.color: root.mutedColor
                    SafeText { anchors.centerIn: parent; text: i18n.t("restoreAction"); color: root.inkColor; font.family: "monospace"; font.pixelSize: 9; font.bold: true }
                    MouseArea { anchors.fill: parent; onClicked: root.restoreBinding(excludedRow.modelData.localId) }
                  }
                }
              }
            }
          }
          Item {
            width: parent.width; height: 32
            visible: root.staleExcludedCount > 0
            SafeText {
              anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
              width: 400; elide: Text.ElideRight; maximumLineCount: 1
              text: i18n.t("excludedStale", { count: root.staleExcludedCount })
              color: root.coinColor; font.family: "monospace"; font.pixelSize: 10; font.bold: true
            }
            Rectangle {
              anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
              width: 92; height: 28
              visible: root.view !== "playing"
              color: root.screenColor; border.width: 2; border.color: root.mutedColor
              SafeText { anchors.centerIn: parent; text: i18n.t("excludedClearStale"); color: root.inkColor; font.family: "monospace"; font.pixelSize: 9; font.bold: true }
              MouseArea { anchors.fill: parent; onClicked: root.clearStaleExclusions() }
            }
          }
        }
      }

      Rectangle {
        id: themeMenu
        x: topbar.x + topControls.x + themeButton.x + themeButton.width - width
        y: topbar.y + topbar.height + 8
        width: 176; height: Palettes.names().length * 36 + 8
        visible: root.themeMenuOpen
        z: 100
        color: root.cabinetColor; border.width: 3; border.color: root.primaryColor
        Column {
          anchors.fill: parent; anchors.margins: 4
          Repeater {
            model: Palettes.names()
            delegate: Rectangle {
              id: themeOption
              required property var modelData
              width: parent.width; height: 36
              color: themeOption.modelData === root.themeName ? root.primaryColor : root.screenColor
              SafeText {
                anchors.centerIn: parent; width: parent.width - 12
                horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; maximumLineCount: 1
                text: String(themeOption.modelData).toUpperCase()
                color: themeOption.modelData === root.themeName ? root.voidColor : root.inkColor
                font.family: "monospace"; font.pixelSize: 11; font.bold: true
              }
              MouseArea { anchors.fill: parent; onClicked: root.selectTheme(themeOption.modelData) }
            }
          }
        }
      }

      Rectangle {
        id: languageMenu
        x: topbar.x + topControls.x + languageButton.x + languageButton.width - width
        y: topbar.y + topbar.height + 8
        width: 164; height: i18n.supported.length * 36 + 8
        visible: root.languageMenuOpen
        z: 100
        color: root.cabinetColor; border.width: 3; border.color: root.primaryColor
        Column {
          anchors.fill: parent; anchors.margins: 4
          Repeater {
            model: i18n.supported
            delegate: Rectangle {
              id: languageOption
              required property string modelData
              width: parent.width; height: 36
              color: languageOption.modelData === i18n.locale ? root.primaryColor : root.screenColor
              SafeText { anchors.centerIn: parent; text: root.localeLabel(languageOption.modelData); color: languageOption.modelData === i18n.locale ? root.voidColor : root.inkColor; font.family: "monospace"; font.pixelSize: 11; font.bold: true }
              MouseArea { anchors.fill: parent; onClicked: root.selectLocale(languageOption.modelData) }
            }
          }
        }
      }

      Rectangle {
        id: screenArea
        objectName: "screenArea"
        anchors.left: parent.left; anchors.right: parent.right
        anchors.top: topbar.bottom
        anchors.bottom: statusStrip.top
        anchors.margins: 22
        color: root.screenColor
        border.width: 4
        border.color: "#05070e"

        // Scanlines belong to the screen, so they live inside it: a child of
        // this rectangle cannot reach the top bar however its z is set, and
        // the exclude and drawer buttons up there must stay clickable. It
        // takes no input of its own either.
        Image {
          anchors.fill: parent
          anchors.margins: 4
          z: 30
          visible: !root.reducedMotion
          enabled: false
          source: Qt.resolvedUrl("assets/scanline.png")
          fillMode: Image.Tile
          // Tuned on hardware: 0.05 was invisible on this panel. Half the
          // tile is opaque, so this is the darkening of every second line.
          opacity: 0.14
          smooth: false
        }

        Column {
          anchors.fill: parent
          anchors.margins: 18
          spacing: 12

          Row {
            width: parent.width; height: 58
            Repeater {
              model: [
                { key: "run", label: i18n.t("run"), value: String(root.runNumber).padStart(2, "0") },
                { key: "progress", label: i18n.t("progress"), value: String(root.completedCardCount()).padStart(2, "0") + " / " + root.sessionSize },
                { key: "runReview", label: i18n.t("runReview"), value: root.runReviewTarget },
                { key: "runNew", label: i18n.t("runNew"), value: root.runNewTarget },
                { key: "reinforce", label: i18n.t("reinforce"), value: root.pendingReinforcementCount() },
                { key: "accuracy", label: i18n.t("accuracy"), value: root.accuracyPercent() + "%" }
              ]
              delegate: Item {
                id: hudDatum
                required property var modelData
                width: parent.width / 6; height: 58
                Column {
                  width: parent.width
                  anchors.centerIn: parent
                  SafeText { width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; text: hudDatum.modelData.label; color: root.mutedColor; font.family: "monospace"; font.pixelSize: 9; font.bold: true }
                  // Deliberately the small cell: the widest reading here is
                  // "07 / 24", seven glyphs, and at cell 3 that outgrows a
                  // sixth of the strip on a 1024 wide screen. sessionSize is
                  // engine-bounded at runCardLimit, so that reading still holds.
                  Item {
                    width: parent.width; height: 26
                    DotNumber {
                      anchors.horizontalCenter: parent.horizontalCenter
                      anchors.verticalCenter: parent.verticalCenter
                      objectName: "hudValue:" + hudDatum.modelData.key
                      value: String(hudDatum.modelData.value)
                      cell: 2
                      gap: 1
                      color: root.inkColor
                    }
                  }
                }
              }
            }
          }

          Item {
            width: parent.width; height: 24
            SafeText {
              id: totalProgressLabel
              width: 118; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
              text: i18n.t("totalProgress")
              color: root.mutedColor; font.family: "monospace"; font.pixelSize: 10; font.bold: true
            }
            Rectangle {
              id: totalProgressTrack
              anchors.left: totalProgressLabel.right; anchors.right: totalProgressValue.left
              anchors.leftMargin: 10; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
              height: 12; color: "#293252"; border.width: 1; border.color: root.mutedColor
              Rectangle {
                id: masteredProgressSegment
                anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                anchors.margins: 1
                width: Math.max(0, (parent.width - 2) * root.progressCounts.mastered
                                / Math.max(1, root.progressCounts.total))
                color: root.successColor
              }
            }
            SafeText {
              id: totalProgressValue
              width: 154; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
              horizontalAlignment: Text.AlignRight
              text: root.progressCounts.mastered + " / " + root.progressCounts.total
                    + " · " + Math.round(root.progressCounts.mastered * 100
                                         / Math.max(1, root.progressCounts.total)) + "%"
              color: root.inkColor; font.family: "monospace"; font.pixelSize: 11; font.bold: true
            }
          }

          Item {
            width: parent.width
            height: parent.height - 106

            Column {
              width: 90
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: 8
              SafeText { anchors.horizontalCenter: parent.horizontalCenter; text: i18n.t("newLearned"); color: root.mutedColor; font.family: "monospace"; font.pixelSize: 10; font.bold: true }
              DotNumber {
                anchors.horizontalCenter: parent.horizontalCenter
                value: "+" + root.newLearned
                cell: 4
                gap: 1
                color: root.successColor
              }
            }

            Column {
              width: 90
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: 8
              SafeText { anchors.horizontalCenter: parent.horizontalCenter; text: i18n.t("due"); color: root.mutedColor; font.family: "monospace"; font.pixelSize: 10; font.bold: true }
              DotNumber {
                anchors.horizontalCenter: parent.horizontalCenter
                value: String(root.progressCounts.due)
                cell: 4
                gap: 1
                color: root.coinColor
              }
            }

            Item {
              id: cardHost
              width: Math.min(620, parent.width - 220)
              height: parent.height - 12
              anchors.centerIn: parent
              transform: Translate { id: cardShift; x: 0 }

              Rectangle {
                id: cardGlow
                anchors.fill: card
                anchors.margins: -8
                color: root.successColor
                opacity: 0
              }

              Rectangle {
                id: card
                objectName: "screenCard"
                anchors.fill: parent
                anchors.margins: 8
                color: root.cabinetColor
                border.width: 4
                border.color: root.feedbackKind === "hit" ? root.successColor : root.feedbackKind === "miss" ? root.dangerColor : root.primaryColor

                // The screen's own inner frame, in the same pixel language as
                // the stamp. It follows the border colour, so a hit or a miss
                // washes through the blocks as well as the edge.
                PixelFrame {
                  anchors.fill: parent
                  anchors.margins: 7
                  z: 4
                  color: card.border.color
                  running: !root.reducedMotion
                  tickMs: 120
                }

                Rectangle {
                  id: excludeStamp
                  z: 5
                  anchors.centerIn: parent
                  width: Math.min(parent.width - 60, 430); height: 88
                  color: root.voidColor
                  border.width: 4; border.color: root.coinColor
                  opacity: root.excludeStampVisible ? 1 : 0
                  visible: opacity > 0
                  // The fade is the only part reducedMotion removes. The stamp
                  // itself still holds for its full beat, because it is the
                  // confirmation that the key left training.
                  Behavior on opacity {
                    enabled: !root.reducedMotion
                    NumberAnimation { duration: 110; easing.type: Easing.OutQuad }
                  }
                  SafeText {
                    anchors.centerIn: parent
                    width: parent.width - 24
                    horizontalAlignment: Text.AlignHCenter
                    text: i18n.t("excludeStamp")
                    color: root.coinColor; font.family: "monospace"; font.bold: true; font.pixelSize: 15
                    wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
                  }
                }

                Loader {
                  anchors.fill: parent
                  sourceComponent: root.view === "playing" ? playCard
                                 : root.view === "mastery" ? masteryCard
                                 : root.view === "summary" ? summaryCard
                                 : root.view === "blocked" ? blockedCard
                                 : root.view === "closing" ? closingCard : homeCard
                }
              }
            }
          }
        }
      }

      Rectangle {
        id: statusStrip
        height: 42
        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
        anchors.leftMargin: 4; anchors.rightMargin: 4; anchors.bottomMargin: 4
        color: root.voidColor
        Row {
          anchors.centerIn: parent
          spacing: 28
          Repeater {
            model: [i18n.t("localOnly"), i18n.t("inputSafe"), i18n.t("noDispatch")]
            SafeText { required property var modelData; text: modelData; color: root.mutedColor; font.family: "monospace"; font.pixelSize: 10; font.bold: true; font.letterSpacing: 2 }
          }
        }
      }
    }
  }

  component BrowseChip: Rectangle {
    id: chip
    property string label: ""
    property bool selected: false
    signal picked()
    width: Math.min(190, chipLabel.implicitWidth + 20); height: 28
    color: selected ? root.primaryColor : root.screenColor
    border.width: 1; border.color: root.mutedColor
    SafeText {
      id: chipLabel
      anchors.centerIn: parent; width: parent.width - 12
      text: chip.label; elide: Text.ElideRight; maximumLineCount: 1
      color: chip.selected ? root.voidColor : root.inkColor
      font.family: "monospace"; font.pixelSize: 10; font.bold: true
    }
    MouseArea { objectName: "browseChipArea"; anchors.fill: parent; onClicked: chip.picked() }
  }

  Component {
    id: homeCard
    Item {
      id: homeArea
      objectName: "homeArea"
      // Short or narrow frames get the compact home: the decorative intro
      // yields its room so every essential element - status, list, config
      // note, hint and the start controls - stays inside the card frame.
      readonly property bool compact: homeArea.width < 560 || homeArea.height < 320
      Column {
        id: homeColumn
        anchors.centerIn: parent
        width: parent.width - 70
        // The cabinet is a fixed frame: this column has to fit inside it at
        // the smallest size the panel is drawn at, so it stays short.
        spacing: homeArea.compact ? 6 : 13

        // The list takes the room the other home elements actually leave, so
        // wrapped notes/hints and compact controls can never push anything
        // out of the card frame. Twenty pixels of vertical clearance keeps
        // content clear of the decorated frame, not just the border.
        function siblingsHeight() {
          var items = [homeStatus, homeTitle, allExcludedHint, decksTitleLabel,
                       deckConfigNote, emptyDeckHint, homeControls]
          var total = 0
          var gaps = deckListFrame.visible ? 1 : 0
          for (var i = 0; i < items.length; i++) {
            if (!items[i].visible) continue
            total += Math.max(items[i].height, items[i].implicitHeight)
            gaps += 1
          }
          return total + homeColumn.spacing * Math.max(0, gaps - 1)
        }

        SafeText {
          id: homeStatus
          objectName: "homeStatus"
          width: parent.width; horizontalAlignment: Text.AlignHCenter
          // The home screen stays up while a cabinet loads, so this line is
          // what says the wait is happening - the screen itself no longer goes
          // away and come back to say it.
          text: root.groundLoading || root.activeSource.loading ? i18n.t("loading")
                : root.view === "home" ? i18n.t("ready") : i18n.t("acquiring")
          color: root.successColor; font.family: "monospace"; font.bold: true; font.pixelSize: 13; font.letterSpacing: 2
        }
        SafeText {
          id: homeTitle
          objectName: "homeTitle"
          width: parent.width; horizontalAlignment: Text.AlignHCenter
          // The one redundant element on a compact home: the controls below
          // say how to start, so the big intro yields its room to them. The
          // loading and locked-out headlines are not decorative, they stay -
          // at a compact-legible size, so the frame still closes around them
          // and the recovery instructions below them.
          visible: !homeArea.compact || root.view !== "home" || root.trainingLockedOut
          text: root.view !== "home" ? "···"
                : root.trainingLockedOut ? i18n.t("allExcluded")
                : i18n.t(root.resumeAvailable ? "resumeTitle" : "start")
          color: root.inkColor; font.family: "monospace"; font.bold: true
          font.pixelSize: homeArea.compact ? 16 : 28; wrapMode: Text.WordWrap
        }
        // Only the line that tells you how to get out of a corner. The run's
        // shape - 24 cards, saved state - was on the card for its own sake and
        // the cabinet row needed the room more; the buttons below say how to
        // start, which is the only thing that line was still doing.
        SafeText {
          id: allExcludedHint
          objectName: "allExcludedHint"
          width: parent.width; horizontalAlignment: Text.AlignHCenter
          visible: root.trainingLockedOut
          text: i18n.t("allExcludedHint")
          color: root.coinColor
          font.pixelSize: homeArea.compact ? 12 : 15; wrapMode: Text.WordWrap
        }
        // D9: the cabinet grid is retired with the grounds. Decks are one
        // bounded, vertical, scrollable list - all pinned first, then
        // declaration order - showing name, live card count and mastery.
        SafeText {
          id: decksTitleLabel
          objectName: "decksTitleLabel"
          width: parent.width; horizontalAlignment: Text.AlignHCenter
          visible: root.view === "home" && !homeArea.compact
          text: i18n.t("decksTitle")
          color: root.mutedColor; font.family: "monospace"; font.pixelSize: 10
          font.bold: true; font.letterSpacing: 3
        }
        Rectangle {
          id: deckListFrame
          objectName: "deckListFrame"
          anchors.horizontalCenter: parent.horizontalCenter
          visible: root.view === "home"
          width: Math.min(parent.width, 470)
          height: Math.max(40, Math.min(homeArea.compact ? 96 : 132,
                                        homeArea.height - 20 - homeColumn.siblingsHeight()))
          color: root.voidColor; border.width: 2; border.color: root.mutedColor
          ListView {
            id: deckList
            objectName: "deckList"
            anchors.fill: parent; anchors.margins: 3
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            // Independently re-capped here as well: both config boundaries
            // already enforce one reserved deck plus at most 32 declared (R2).
            model: root.deckDefinitions.slice(0, 33)
            delegate: Rectangle {
              id: deckRow
              objectName: "deckRow:" + deckRow.modelData.id
              required property var modelData
              readonly property bool current: deckRow.modelData.id === root.deckId
              // Live per-deck standing. The map is null-prototyped and deck
              // ids are validated config tokens, never raw external keys (R4).
              readonly property var counts: root.deckProgress[deckRow.modelData.id]
              readonly property int total: deckRow.counts ? Number(deckRow.counts.total || 0) : 0
              readonly property int mastered: deckRow.counts ? Number(deckRow.counts.mastered || 0) : 0
              readonly property bool complete: deckRow.total > 0 && deckRow.mastered === deckRow.total
              width: deckList.width; height: 26
              color: deckRow.current ? root.screenColor : root.voidColor
              border.width: deckRow.current ? 2 : 0
              border.color: root.primaryColor
              SafeText {
                anchors.left: parent.left; anchors.leftMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                text: deckRow.current ? "▶" : ""
                color: root.primaryColor; font.family: "monospace"; font.pixelSize: 10; font.bold: true
              }
              SafeText {
                id: deckRowName
                objectName: "deckRowName"
                anchors.left: parent.left; anchors.leftMargin: 24
                anchors.right: deckRowCounts.left; anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight; maximumLineCount: 1
                text: root.deckDisplayName(deckRow.modelData)
                color: deckRow.current ? root.inkColor : root.mutedColor
                font.family: "monospace"; font.pixelSize: 12
                font.bold: deckRow.current
              }
              SafeText {
                id: deckRowCounts
                objectName: "deckRowCounts"
                anchors.right: parent.right; anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, 110)
                horizontalAlignment: Text.AlignRight
                elide: Text.ElideRight; maximumLineCount: 1
                text: (deckRow.complete ? "★ " : "") + deckRow.mastered + "/" + deckRow.total
                color: deckRow.complete ? root.coinColor
                     : deckRow.current ? root.successColor : root.mutedColor
                font.family: "monospace"; font.pixelSize: 10; font.bold: true
              }
              MouseArea {
                objectName: "deckRowArea"
                anchors.fill: parent
                onClicked: root.selectDeck(deckRow.modelData.id)
              }
            }
          }
        }
        // A config the reader rejected still trains (on all); say so plainly.
        SafeText {
          id: deckConfigNote
          objectName: "deckConfigNote"
          width: parent.width; horizontalAlignment: Text.AlignHCenter
          visible: root.view === "home" && root.deckConfigNote() !== ""
          text: root.deckConfigNote()
          color: root.coinColor; font.family: "monospace"; font.pixelSize: 10; font.bold: true
          wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
        }
        // Zero-card decks stay listed and selectable for later curation, but
        // there is nothing to deal: the controls refuse and this hint names
        // the usable top-bar control for adding cards.
        SafeText {
          id: emptyDeckHint
          objectName: "emptyDeckHint"
          width: parent.width; horizontalAlignment: Text.AlignHCenter
          visible: root.view === "home" && !root.groundLoading && !root.trainingLockedOut
                   && root.startRefusal === "empty-deck"
          text: i18n.t("emptyDeckHint")
          color: root.coinColor; font.pixelSize: homeArea.compact ? 11 : 12; font.bold: true
          wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
        }
        // A pack ground says where its table came from, so nothing here can
        // be read as "these are the keymaps on your machine". Two short lines
        // rather than one wrapping paragraph: the card has a fixed height.
        // Nothing about where a ground's table came from. It was all true and
        // none of it was acted on: what a ground read off this machine is
        // already visible where it can be changed - the configurable-keys menu
        // in the top bar names each value and says where it came from.
        // Continuing and starting over sit beside each other rather than
        // stacked. Two rows of buttons cost 51 pixels the card does not have
        // once a ground names where its table came from, and they were never
        // a sequence anyway - they are two ways to begin.
        Row {
          id: homeControls
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: 10
          visible: root.view === "home" && !root.trainingLockedOut
          // Reachable but not usable while the selected deck is still
          // coming in or has no cards to deal: a button that looks ready but
          // does nothing is worse than one that looks busy.
          opacity: root.groundLoading || root.startBlocked ? 0.4 : 1
          Rectangle {
            objectName: "startButton"
            width: homeArea.compact
                   ? (root.resumeAvailable
                      ? Math.max(110, Math.floor((homeColumn.width - 10) * 0.55))
                      : Math.min(200, homeColumn.width))
                   : (root.resumeAvailable ? 200 : 240)
            height: homeArea.compact ? 36 : 46
            color: root.primaryColor; border.width: 4; border.color: root.voidColor
            SafeText { anchors.centerIn: parent; width: parent.width - 16; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; text: "▶  " + i18n.t(root.resumeAvailable ? "resumeRun" : "startRun"); color: root.voidColor; font.family: "monospace"; font.bold: true; font.pixelSize: 15 }
            MouseArea {
              objectName: "startButtonArea"
              anchors.fill: parent
              enabled: !root.browseOpen && !root.groundLoading && !root.startBlocked
              onClicked: root.startPrimary()
            }
          }
          Rectangle {
            objectName: "startFreshButton"
            width: homeArea.compact ? Math.max(90, Math.floor((homeColumn.width - 10) * 0.45)) : 160
            height: homeArea.compact ? 36 : 46
            visible: root.resumeAvailable
            color: root.screenColor; border.width: 2; border.color: root.mutedColor
            SafeText { anchors.centerIn: parent; width: parent.width - 12; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; text: i18n.t("startFresh"); color: root.mutedColor; font.family: "monospace"; font.bold: true; font.pixelSize: 12 }
            MouseArea {
              objectName: "startFreshArea"
              anchors.fill: parent
              enabled: !root.browseOpen && !root.groundLoading && !root.startBlocked
              onClicked: root.startRun()
            }
          }
        }
      }
    }
  }

  Component {
    id: playCard
    Item {
      Row {
        id: comboBadge
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.leftMargin: 22
        anchors.topMargin: 22
        spacing: 8
        visible: root.combo >= 2
        opacity: 1
        SafeText {
          anchors.verticalCenter: parent.verticalCenter
          text: i18n.t("combo")
          color: root.coinColor
          font.family: "monospace"; font.pixelSize: 11; font.bold: true; font.letterSpacing: 2
        }
        DotNumber {
          anchors.verticalCenter: parent.verticalCenter
          value: String(root.combo)
          cell: 3
          gap: 1
          color: root.coinColor
        }
        SequentialAnimation {
          id: comboPulse
          NumberAnimation { target: comboBadge; property: "opacity"; to: 0.35; duration: 70 }
          NumberAnimation { target: comboBadge; property: "opacity"; to: 1; duration: 200 }
        }
        Connections {
          target: root
          function onComboChanged() {
            if (root.combo >= 2 && !root.reducedMotion) comboPulse.restart()
          }
        }
      }
      DotNumber {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.rightMargin: 22
        anchors.topMargin: 22
        visible: root.deadline > 0
        value: String(root.countdownSeconds)
        cell: 4
        gap: 1
        color: root.energy < 0.25 ? root.dangerColor : root.primaryColor
      }
      Column {
        anchors.fill: parent
        anchors.margins: 28
        spacing: 10
        SafeText {
          // Narrowed so a long category line cannot run under the countdown,
          // and narrowed further only while the streak badge is on the other
          // side - reserving that room permanently elided real category names.
          width: parent.width - (root.combo >= 2 ? 250 : 110)
          anchors.horizontalCenter: parent.horizontalCenter
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight; maximumLineCount: 1
          text: (root.currentAnswer && root.currentAnswer.context
                 ? i18n.t("context_" + root.currentAnswer.context) + " · " : "")
                + (root.currentBinding ? i18n.t("category_" + root.currentBinding.category) + " · " : "")
                + (root.currentBinding && root.currentBinding.customKind
                   ? i18n.t("mapping_" + root.currentBinding.customKind) + " · " : "")
                + i18n.t(root.correctionRequired ? "correction" : root.currentCard && root.currentCard.remedial ? "remedial" : root.currentCard && root.currentCard.tier === "guided" ? "guided" : root.currentCard && root.currentCard.tier === "maintenance" ? "maintenance" : "learning")
          color: root.currentCard && root.currentCard.tier === "maintenance" ? root.coinColor : root.secondaryColor
          font.family: "monospace"; font.pixelSize: 12; font.bold: true; font.letterSpacing: 2
        }
        SafeText {
          width: parent.width; height: 82; verticalAlignment: Text.AlignVCenter; horizontalAlignment: Text.AlignHCenter
          text: root.currentBinding ? root.actionName(root.currentBinding) : ""
          color: root.inkColor; font.pixelSize: 27; font.bold: true; wrapMode: Text.WordWrap
          maximumLineCount: 2; elide: Text.ElideRight; clip: true
        }
        SafeText {
          width: parent.width; horizontalAlignment: Text.AlignHCenter
          text: i18n.t(root.correctionRequired ? "correctionInstruction" : root.currentCard && root.currentCard.remedial ? "remedialInstruction" : root.currentCard && root.currentCard.tier === "guided" ? "guidedInstruction" : root.currentCard && root.currentCard.tier === "maintenance" ? "maintenanceInstruction" : "learningInstruction")
          color: root.mutedColor; font.pixelSize: 14; wrapMode: Text.WordWrap
        }
        // Correction only advances on the exact chord, so someone whose
        // keyboard cannot produce it is stuck. This line is how they learn
        // there is a way out; without it the top bar button may as well not
        // exist.
        SafeText {
          width: parent.width; horizontalAlignment: Text.AlignHCenter
          visible: root.correctionRequired
          text: i18n.t("excludeHint")
          color: root.coinColor; font.family: "monospace"; font.pixelSize: 11; font.bold: true
          elide: Text.ElideRight; maximumLineCount: 1
        }
        // One group of key caps per step. A chord has exactly one group, so
        // this draws what it always drew; a sequence reads left to right, and
        // the steps already typed stay lit.
        Item {
          width: parent.width; height: 74
          Row {
            anchors.centerIn: parent
            spacing: 10
            visible: root.revealChord
            Repeater {
              model: root.answerSteps
              delegate: Row {
                id: stepDatum
                required property var modelData
                required property int index
                spacing: 8
                readonly property bool typed: stepDatum.index < root.answerStep
                Repeater {
                  model: stepDatum.modelData
                  delegate: Row {
                    id: keyDatum
                    required property var modelData
                    required property int index
                    spacing: 8
                    Rectangle {
                      width: Math.max(54, keyText.implicitWidth + 24); height: 46
                      color: root.screenColor; border.width: 3
                      border.color: stepDatum.typed ? root.successColor : root.inkColor
                      Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 5; color: "#05070e" }
                      SafeText { id: keyText; anchors.centerIn: parent; width: parent.width - 8; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; maximumLineCount: 1; text: keyDatum.modelData; color: stepDatum.typed ? root.successColor : root.inkColor; font.family: "monospace"; font.pixelSize: 14; font.bold: true }
                    }
                    SafeText { visible: keyDatum.index < stepDatum.modelData.length - 1; text: "+"; color: root.mutedColor; font.family: "monospace"; font.pixelSize: 20; font.bold: true; anchors.verticalCenter: parent.verticalCenter }
                  }
                }
                SafeText { visible: stepDatum.index < root.answerSteps.length - 1; text: "›"; color: root.mutedColor; font.family: "monospace"; font.pixelSize: 22; font.bold: true; anchors.verticalCenter: parent.verticalCenter }
              }
            }
          }
        }
        // The other ways in, when the application accepts more than one. Shown
        // under the answer rather than beside it: there is one answer to
        // learn, and these are what will also be taken.
        SafeText {
          width: parent.width; horizontalAlignment: Text.AlignHCenter
          visible: root.revealChord && root.answerAlternates().length > 0
          text: i18n.t("alsoAccepts", { keys: root.answerAlternates().join("   ") })
          color: root.mutedColor; font.family: "monospace"; font.pixelSize: 11
          elide: Text.ElideRight; maximumLineCount: 1
        }
        Row {
          width: parent.width; height: 14; spacing: 3
          visible: root.deadline > 0
          Repeater {
            model: 20
            Rectangle {
              required property int index
              width: (parent.width - 57) / 20; height: 14
              color: index / 20 < root.energy ? (root.energy < 0.25 ? root.dangerColor : root.primaryColor) : "#293252"
            }
          }
        }
        SafeText {
          width: parent.width; horizontalAlignment: Text.AlignHCenter
          text: root.feedbackText
          color: root.feedbackKind === "hit" ? root.successColor : root.feedbackKind === "miss" ? root.dangerColor : root.mutedColor
          font.family: "monospace"; font.pixelSize: 13; font.bold: true; elide: Text.ElideRight; maximumLineCount: 1
        }
      }
    }
  }

  Component {
    id: masteryCard
    Item {
      Column {
        anchors.centerIn: parent; width: parent.width - 44; spacing: 10
        SafeText {
          width: parent.width; horizontalAlignment: Text.AlignHCenter
          text: "★  " + i18n.t("masteryCelebration") + "  ★"
          color: root.coinColor; font.family: "monospace"; font.bold: true; font.pixelSize: 24
        }
        SafeText {
          width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
          text: i18n.t("masteryBody", { count: root.progressCounts.total })
          color: root.inkColor; font.pixelSize: 13
        }
        Grid {
          width: parent.width; columns: 3; spacing: 7
          Repeater {
            model: [
              { label: i18n.t("shortcutTotal"), value: root.progressCounts.total },
              { label: i18n.t("totalRuns"), value: Number(root.profileCounters().runs || 0) },
              { label: i18n.t("trainingTime"), value: root.formatTrainingTime(root.profileCounters().totalTrainingMs) },
              { label: i18n.t("accuracy"), value: root.masterySnapshot.accuracy + "%" },
              { label: i18n.t("response"), value: root.masterySnapshot.response ? root.masterySnapshot.response + " ms" : "—" },
              { label: i18n.t("masteryDate"), value: root.formatMasteryDate(root.profileCounters().firstMasteryAt) }
            ]
            delegate: Rectangle {
              id: masteryDatum
              required property var modelData
              width: (parent.width - 14) / 3; height: 62
              color: root.screenColor; border.width: 2; border.color: root.successColor
              Column {
                width: parent.width - 10; anchors.centerIn: parent; spacing: 3
                SafeText { width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; text: masteryDatum.modelData.label; color: root.mutedColor; font.family: "monospace"; font.pixelSize: 9; font.bold: true }
                SafeText { width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; text: masteryDatum.modelData.value; color: root.inkColor; font.family: "monospace"; font.pixelSize: 17; font.bold: true }
              }
            }
          }
        }
        SafeText {
          width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
          text: i18n.t("maintenanceUnlocked")
          color: root.secondaryColor; font.pixelSize: 12; font.bold: true
        }
        SafeText {
          width: parent.width; height: 34; horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight; clip: true
          text: i18n.t("supportPrompt")
          color: root.inkColor; font.pixelSize: 12
        }
        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          Rectangle {
            width: 240; height: 36
            color: marketplaceSupportMouse.containsMouse ? root.coinColor : root.dangerColor
            border.width: 3; border.color: root.voidColor
            SafeText {
              anchors.centerIn: parent; width: parent.width - 12
              horizontalAlignment: Text.AlignHCenter
              maximumLineCount: 1; elide: Text.ElideRight; clip: true
              text: i18n.t("supportMarketplace")
              color: root.voidColor; font.family: "monospace"; font.pixelSize: 11; font.bold: true
            }
            MouseArea {
              id: marketplaceSupportMouse
              anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
              onClicked: root.openMarketplacePage()
            }
          }
        }
      }
    }
  }

  Component {
    id: summaryCard
    Item {
      Column {
        anchors.centerIn: parent; width: parent.width - 60; spacing: 18
        SafeText { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: i18n.t("summary"); color: root.coinColor; font.family: "monospace"; font.bold: true; font.pixelSize: 28 }
        Row {
          width: parent.width; spacing: 8
          Repeater {
            model: [
              { label: i18n.t("accuracy"), value: root.accuracyPercent() + "%" },
              { label: i18n.t("newLearned"), value: "+" + root.newLearned },
              { label: i18n.t("masteredNow"), value: "+" + root.masteredGained },
              { label: i18n.t("response"), value: root.p75Reaction() ? root.p75Reaction() + " ms" : "—" }
            ]
            delegate: Rectangle {
              id: summaryDatum
              required property var modelData
              width: (parent.width - 24) / 4; height: 94; color: root.screenColor; border.width: 2; border.color: root.primaryColor
              Column { anchors.centerIn: parent; spacing: 5
                SafeText { anchors.horizontalCenter: parent.horizontalCenter; text: summaryDatum.modelData.label; color: root.mutedColor; font.family: "monospace"; font.pixelSize: 10; font.bold: true }
                SafeText { anchors.horizontalCenter: parent.horizontalCenter; text: summaryDatum.modelData.value; color: root.inkColor; font.family: "monospace"; font.pixelSize: 22; font.bold: true }
              }
            }
          }
        }
        SafeText { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: i18n.t("again"); color: root.successColor; font.family: "monospace"; font.pixelSize: 14; font.bold: true }
        SafeText { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: i18n.t("review") + " · " + i18n.t("reviewHint"); color: root.mutedColor; font.family: "monospace"; font.pixelSize: 10; font.bold: true; wrapMode: Text.WordWrap }
        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: 8
          Repeater {
            model: root.reviewSuggestions
            delegate: Rectangle {
              id: reviewDatum
              required property var modelData
              width: 154; height: 42
              color: root.screenColor; border.width: 2; border.color: root.secondaryColor
              SafeText { anchors.centerIn: parent; width: parent.width - 12; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; text: root.answerDisplay(reviewDatum.modelData.binding); color: root.inkColor; font.family: "monospace"; font.pixelSize: 11; font.bold: true }
              MouseArea { anchors.fill: parent; onClicked: root.requestHint(reviewDatum.modelData.binding.id) }
            }
          }
        }
      }
    }
  }

  Component {
    id: blockedCard
    Item {
      Column {
        anchors.centerIn: parent; width: parent.width - 70; spacing: 18
        SafeText { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: "×  " + i18n.t("blocked"); color: root.dangerColor; font.family: "monospace"; font.bold: true; font.pixelSize: 24; wrapMode: Text.WordWrap }
        SafeText { width: parent.width; height: 150; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; text: root.errorMessage; color: root.inkColor; font.pixelSize: 15; wrapMode: Text.WordWrap; maximumLineCount: 5; elide: Text.ElideRight; clip: true }
      }
    }
  }

  Component {
    id: closingCard
    Item {
      SafeText { anchors.centerIn: parent; width: parent.width - 70; horizontalAlignment: Text.AlignHCenter; text: i18n.t("closing"); color: root.coinColor; font.pixelSize: 18; wrapMode: Text.WordWrap }
    }
  }
}
