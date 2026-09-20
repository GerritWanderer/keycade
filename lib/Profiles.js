.pragma library
.import "TextKey.js" as TextKey

// The compiled LazyVim card supply. The registry is static and decided at
// build time: user data cannot add a profile. Qualified-id helpers remain
// syntactic, independently of this registry, so retired history stays intact.

var ID_PATTERN = /^[a-z][a-z0-9-]{0,31}$/
var MAX_ID_CHARS = 32
// Separates the profile from the id its own source minted. "/" cannot be
// confused with the start of a profile id, so a legacy unqualified id is
// recognisable by the name in front of the first separator failing the
// pattern above - see profileOf().
var SEPARATOR = "/"

var DEFAULT_ID = "lazyvim"
// Pre-profile state always belonged to Hyprland, regardless of today's
// default supply. This is a compatibility namespace, not a registered source.
var LEGACY_ID = "hyprland"
var FORBIDDEN_IDS = ["__proto__", "constructor", "prototype"]

var registry = [
  {
    id: "lazyvim",
    // A terminal application reads the characters the layout produced, so `g`
    // and `G` are two mappings and the character round-trip is the answer.
    judgeMode: "text",
    answerModel: "sequence",
    // A pack: the upstream's own published key table, compiled in. LazyVim has
    // no read-only query for its mappings, and it does have a standard set -
    // which is what someone installing it was choosing in the first place.
    origin: "pack",
    nameKey: "profile_lazyvim",
    // The modes a card can pose, which the card shows as a badge.
    contexts: ["normal", "visual", "insert", "operator"],
    // A configurable key every other binding hangs off. The pack stores a
    // placeholder rather than the character it happened to be built with, so
    // moving it retrains the mapping instead of a key nobody presses.
    options: { leader: " ", localleader: "\\" }
  }
]

// The modes a ground's cards can pose. Empty when it has none to name.
function contexts(id) {
  var item = profile(id)
  return item && Array.isArray(item.contexts) ? item.contexts : []
}

// Grounds that carry a compiled-in key table rather than reading the machine.
function isPack(id) {
  var item = profile(id)
  return Boolean(item && item.origin === "pack")
}

function options(id) {
  var item = profile(id)
  return item && item.options ? item.options : ({})
}

function optionUsable(value) {
  return Boolean(TextKey.parseKeySpec(String(value === undefined || value === null ? "" : value)))
}

// Resolve detected leader values over upstream defaults. Only declared
// option names can reach the result; arbitrary external keys are never copied.
function resolvedOptions(id, detected) {
  var declared = options(id)
  var source = detected && typeof detected === "object" && !Array.isArray(detected)
      ? detected : ({})
  var result = Object.create(null)
  Object.keys(declared).forEach(function(name) {
    var fallback = String(declared[name] || "")
    var candidate = source[name] !== undefined ? String(source[name]) : fallback
    result[name] = optionUsable(candidate) ? candidate : fallback
  })
  return result
}

// The options a ground has, in a stable order.
function optionNames(id) {
  return Object.keys(options(id))
}

function ids() {
  return registry.map(function(item) { return item.id })
}

function defaultId() { return DEFAULT_ID }

function known(id) {
  return Boolean(profile(id))
}

// A syntactically usable profile name. Kept separate from known(): stored
// state may name a profile this build does not carry, and that has to be
// rejected as unknown rather than as malformed.
function valid(id) {
  var name = String(id === undefined || id === null ? "" : id)
  return name.length <= MAX_ID_CHARS && ID_PATTERN.test(name)
      && FORBIDDEN_IDS.indexOf(name) === -1
}

function profile(id) {
  var name = String(id === undefined || id === null ? "" : id)
  for (var index = 0; index < registry.length; index++) {
    if (registry[index].id === name) return registry[index]
  }
  return null
}

// The namespaced id every layer above the source uses. Returns "" rather than
// a half-formed id, so a caller cannot key state on an unusable name.
function qualify(profileId, localId) {
  var local = String(localId === undefined || localId === null ? "" : localId)
  return valid(profileId) && local ? String(profileId) + SEPARATOR + local : ""
}

// The profile in front of the first separator, or "" when there is none. A
// local id may itself contain "/" (a dispatcher argument holding a path, for
// one), which is why only the first segment is considered and why it has to
// pass the id pattern to count.
function profileOf(qualifiedId) {
  var value = String(qualifiedId === undefined || qualifiedId === null ? "" : qualifiedId)
  var separator = value.indexOf(SEPARATOR)
  if (separator <= 0) return ""
  var name = value.slice(0, separator)
  return valid(name) ? name : ""
}

function localOf(qualifiedId) {
  var name = profileOf(qualifiedId)
  return name ? String(qualifiedId).slice(name.length + SEPARATOR.length) : ""
}

function isQualified(qualifiedId) {
  return Boolean(profileOf(qualifiedId))
}

// Used when state written before profiles existed is read back: everything a
// previous version stored belonged to the Hyprland training ground.
function qualifyLegacy(id, profileId) {
  var value = String(id === undefined || id === null ? "" : id)
  if (!value) return ""
  return profileOf(value) ? value : qualify(profileId || LEGACY_ID, value)
}
