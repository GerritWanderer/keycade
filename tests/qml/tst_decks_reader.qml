import QtQuick
import QtTest
import "../../lib/DeckValidation.js" as DeckValidation
import "../../lib/Packs.js" as Packs
import "../../lib/Profiles.js" as Profiles

TestCase {
  name: "DeckReaderBoundary"
  readonly property int maxPayloadBytes: 256 * 1024

  function packet(decks) { return { schemaVersion: 1, status: "valid", reason: "", decks: decks, rejected: 0 } }
  function validate(value) { return DeckValidation.validate(value, Packs.pack("lazyvim"), Profiles.contexts("lazyvim")) }
  function envelope(config) { return { schemaVersion: 1, profile: "lazyvim", deckConfig: config } }
  function one(seed) {
    var deck = { id: "safe", name: "Safe" }
    if (seed !== undefined) deck.seed = seed
    return deck
  }

  function test_valid_order_and_no_implicit_starters_or_all() {
    var declarations = [{ id: "marks", name: "Marks", seed: { extras: ["lazyvim.plugins.extras.editor.harpoon2"] } },
                        { id: "lsp", name: "LSP", seed: { categories: ["lsp", "diagnostics"], contexts: ["normal"] } },
                        { id: "nemesis", name: "Nemesis" }]
    var result = validate(packet(declarations))
    compare(result.status, "valid")
    compare(JSON.stringify(result.decks), JSON.stringify(declarations))
    compare(result.rejected, 0)
    compare(validate(packet([])).decks.length, 0)
    compare(validate(packet([])).status, "valid")
    verify(!Object.prototype.hasOwnProperty.call(result.decks[2], "seed"))
  }

  function test_absent_invalid_and_empty_preserve_distinct_fallback_signals() {
    compare(validate(DeckValidation.result("absent")).status, "absent")
    compare(validate(packet([])).status, "valid")
    compare(validate(DeckValidation.invalid("invalid-json")).status, "invalid")
    compare(validate(null).status, "invalid")
    compare(validate({}).status, "invalid")
    var absent = DeckValidation.result("absent")
    absent.decks = [one()]
    compare(validate(absent).status, "invalid")
    absent.decks = []
    absent.reason = "not actually absent"
    compare(validate(absent).status, "invalid")
  }

  function test_hostile_status_and_counter_schema() {
    var bad = [undefined, null, [], true, 1, "valid"]
    for (var i = 0; i < bad.length; i++) compare(validate(bad[i]).status, "invalid")
    var fields = ["schemaVersion", "status", "decks", "reason", "rejected"]
    for (var f = 0; f < fields.length; f++) {
      var missing = packet([])
      delete missing[fields[f]]
      compare(validate(missing).status, "invalid", fields[f])
    }
    var counters = [-1, 100001, 0.5, "2", null, true, Infinity, NaN]
    for (var c = 0; c < counters.length; c++) {
      var value = packet([])
      value.rejected = counters[c]
      compare(validate(value).status, "invalid")
    }
    var malformed = packet([])
    malformed.schemaVersion = true
    compare(validate(malformed).status, "invalid")
    malformed = packet([])
    malformed.status = "success"
    compare(validate(malformed).status, "invalid")
    malformed = DeckValidation.invalid("\u001b[31m" + "x".repeat(300))
    compare(validate(malformed).reason, "invalid-schema")
    malformed = packet([])
    malformed.rejected = 100000
    malformed.unknown = 1
    compare(validate(malformed).rejected, 100000)
  }

  function test_caps_first_32_declarations_and_duplicates() {
    var decks = []
    for (var i = 0; i < 40; i++) decks.push({ id: "deck-" + i, name: String(i) })
    var result = validate(packet(decks))
    compare(result.decks.length, 32)
    compare(result.decks[31].id, "deck-31")
    compare(result.rejected, 8)
    decks[0].id = "INVALID"
    result = validate(packet(decks))
    compare(result.decks.length, 31)
    compare(result.rejected, 9)
    result = validate(packet([{ id: "a", name: "First" }, { id: "a", name: "Second" },
                              { id: "bad", name: null }, { id: "bad", name: "Cannot replace" }]))
    compare(result.decks.length, 1)
    compare(result.decks[0].name, "First")
    compare(result.rejected, 3)
  }

  function test_id_and_record_schema() {
    var ids = ["", "A", "a_b", "a/b", "a b", "a\n", "a".repeat(33), "__proto__", "constructor", "prototype", 1, null, {}]
    var decks = ids.map(function(id) { return { id: id, name: "Bad" } })
    decks.push({ id: "a".repeat(32), name: "At limit" })
    var result = validate(packet(decks))
    compare(result.decks.length, 1)
    compare(result.rejected, ids.length)
    result = validate(packet([null, [], "deck", 2, { id: "a" }, { id: "b", name: {} },
                              { id: "c", name: "\u001b[31m\n\u202e" }, one([])]))
    compare(result.decks.length, 0)
    compare(result.rejected, 8)
  }

  function test_all_honors_name_and_ignores_any_seed_without_reordering() {
    var seeds = [{ categories: ["telepathy"] }, null, "invalid", [1, 2]]
    for (var i = 0; i < seeds.length; i++) {
      var result = validate(packet([one(), { id: "all", name: "Everything", seed: seeds[i] }]))
      compare(result.decks[0].id, "safe")
      compare(result.decks[1].name, "Everything")
      verify(!Object.prototype.hasOwnProperty.call(result.decks[1], "seed"))
      compare(result.rejected, 0)
    }
  }

  function test_unknown_keys_prototypes_and_owned_fresh_records() {
    var input = JSON.parse('{"schemaVersion":1,"status":"valid","reason":"","rejected":0,"decks":['
        + '{"id":"safe","name":"Safe","__proto__":{},"constructor":{},"prototype":{},"unknown":0,'
        + '"seed":{"categories":["lsp"],"__proto__":{},"constructor":{},"prototype":{},"unknown":0}}],'
        + '"__proto__":{},"constructor":{},"prototype":{},"unknown":0}')
    var result = validate(input)
    compare(result.rejected, 12)
    compare(result.decks.length, 1)
    compare(Object.keys(result.decks[0]).sort().join(","), "id,name,seed")
    compare(Object.getPrototypeOf(result.decks[0].seed), null)
    input.decks[0].seed.categories.push("git")
    input.decks[0].name = "Changed externally"
    compare(result.decks[0].seed.categories.length, 1)
    compare(result.decks[0].name, "Safe")
    var inherited = Object.create({ id: "inherited", name: "Inherited" })
    compare(validate(packet([inherited])).decks.length, 0)
  }

  function test_unknown_values_not_trusted_and_empty_dimensions_retained() {
    var seed = { categories: ["telepathy", "constructor", "__proto__", "prototype", 1, null, "x".repeat(33)],
                 extras: ["lazyvim.plugins.extras.lang.imaginary", "x".repeat(129)],
                 contexts: ["prefix", "normal", "normal", {}] }
    var result = validate(packet([one(seed)]))
    compare(result.rejected, 12)
    compare(JSON.stringify(result.decks[0].seed), '{"categories":[],"extras":[],"contexts":["normal"]}')
    result = validate(packet([one({ categories: "lsp", extras: null, contexts: { normal: true } })]))
    compare(result.rejected, 3)
    compare(JSON.stringify(result.decks[0].seed), '{"categories":[],"extras":[],"contexts":[]}')
    compare(JSON.stringify(validate(packet([one({})])).decks[0].seed), '{}')
  }

  function test_each_seed_cap_and_duplicate_counts() {
    var seed = { categories: Array(26).fill("lsp"),
                 extras: Array(34).fill("lazyvim.plugins.extras.editor.harpoon2"), contexts: Array(10).fill("normal") }
    var result = validate(packet([one(seed)]))
    compare(result.rejected, 67)
    compare(result.decks[0].seed.categories.length, 1)
    compare(result.decks[0].seed.extras.length, 1)
    compare(result.decks[0].seed.contexts.length, 1)
  }

  function test_real_loaded_pack_and_profile_vocabulary_only() {
    var pack = Packs.pack("lazyvim")
    var vocab = DeckValidation.vocabulary(pack, Profiles.contexts("lazyvim"))
    compare(Object.getPrototypeOf(vocab), null)
    compare(Object.keys(vocab.categories).sort(), pack.categories.slice().sort())
    compare(Object.keys(vocab.extras).sort(), pack.extras.slice().sort())
    compare(Object.keys(vocab.contexts).sort(), Profiles.contexts("lazyvim").slice().sort())
    var keys = ["categories", "extras", "contexts"]
    var caps = [24, 32, 8]
    for (var i = 0; i < keys.length; i++) {
      var seed = Object.create(null)
      seed[keys[i]] = pack[keys[i]].slice(0, caps[i])
      compare(validate(packet([one(seed)])).rejected, 0)
    }
    var reducedContexts = DeckValidation.validate(packet([one({ contexts: ["normal"] })]), pack, ["visual"])
    compare(reducedContexts.decks[0].seed.contexts.length, 0)
    compare(reducedContexts.rejected, 1)
    compare(DeckValidation.validate(packet([one()]), null, []).status, "invalid")
  }

  function test_names_data() {
    return [
      { tag: "ansi-bidi-controls", input: "\u001b[31mRed\u001b[0m\u0000\u0085\u061c\u200e\u2028\u2029\u202e\u2069\u206a\u206f", expected: "Red" },
      { tag: "osc", input: "\u001b]0;secret\u0007Name\u001b]8;;link\u001b\\X\u001b]8;;\u001b\\", expected: "NameX" },
      { tag: "c1-dcs", input: "\u009dtitle\u009cA\u009b31mB\u009b0m\u001bPsecret\u001b\\C", expected: "ABC" },
      { tag: "unfinished-osc", input: "Name\u001b]unfinished", expected: "Name" },
      { tag: "cap", input: "a".repeat(80), expected: "a".repeat(48) },
      { tag: "unicode-codepoints", input: "😀".repeat(49), expected: "😀".repeat(48) },
      { tag: "lone-surrogates", input: "A\ud800B\udfffC", expected: "ABC" },
      { tag: "markup-stays-plain", input: "<b>Plain text</b>", expected: "<b>Plain text</b>" }
    ]
  }
  function test_names(data) {
    compare(validate(packet([{ id: "safe", name: data.input }])).decks[0].name, data.expected)
  }

  function test_terminal_escape_grammar_data() {
    return [
      { tag: "save", input: "A\u001b7B", expected: "AB" },
      { tag: "restore", input: "A\u001b8B", expected: "AB" },
      { tag: "keypad-on", input: "A\u001b=B", expected: "AB" },
      { tag: "keypad-off", input: "A\u001b>B", expected: "AB" },
      { tag: "reset", input: "A\u001bcB", expected: "AB" },
      { tag: "alignment", input: "A\u001b#8B", expected: "AB" },
      { tag: "charset", input: "A\u001b(B\u001b%GB", expected: "AB" },
      { tag: "truncated-escape", input: "A\u001b", expected: "A" },
      { tag: "truncated-intermediate", input: "A\u001b#", expected: "A" },
      { tag: "truncated-csi", input: "A\u001b[31;", expected: "A" },
      { tag: "truncated-c1-csi", input: "A\u009b31;", expected: "A" },
      { tag: "truncated-dcs", input: "A\u001bPsecret", expected: "A" },
      { tag: "truncated-osc", input: "A\u001b]secret\u001b", expected: "A" },
      { tag: "restarted-csi", input: "A\u001b[31\u001b7B", expected: "AB" },
      { tag: "restarted-escape", input: "A\u001b#\u001b8B", expected: "AB" },
      { tag: "restarted-c1-csi", input: "A\u001b#\u009b31mB", expected: "AB" },
      { tag: "restarted-c1-osc", input: "A\u001b[31\u009dtitle\u0007B", expected: "AB" },
      { tag: "malformed-csi-order", input: "A\u001b[1 2mB", expected: "AB" },
      { tag: "malformed-csi-unicode", input: "A\u001b[12é34mB", expected: "AB" },
      { tag: "malformed-escape-unicode", input: "A\u001bé7B", expected: "AB" },
      { tag: "malformed-string-escape", input: "A\u001b]title\u001bxsecret\u0007B", expected: "AB" },
      { tag: "truncated-malformed-string", input: "A\u001b]title\u001bxsecret", expected: "A" },
      { tag: "dcs-bel-not-terminator", input: "A\u001bPsecret\u0007hidden\u001b\\B", expected: "AB" },
      { tag: "cancel-csi", input: "A\u001b[31\u0018B", expected: "AB" },
      { tag: "cancel-escape", input: "A\u001b#\u001aB", expected: "AB" },
      { tag: "control-in-csi", input: "A\u001b[31\nmB", expected: "AB" },
      { tag: "del-in-escape", input: "A\u001b#\u007f8B", expected: "AB" }
    ]
  }
  function test_terminal_escape_grammar(data) {
    compare(validate(packet([{ id: "safe", name: data.input }])).decks[0].name, data.expected)
  }
  function test_terminal_escape_final_and_intermediate_ranges() {
    for (var final = 0x30; final <= 0x7e; final++) {
      var char = String.fromCharCode(final)
      compare(DeckValidation.safeName("A\u001b#" + char + "B"), "AB")
      if ("[]PX^_".indexOf(char) === -1) compare(DeckValidation.safeName("A\u001b" + char + "B"), "AB")
    }
    for (var intermediate = 0x20; intermediate <= 0x2f; intermediate++)
      compare(DeckValidation.safeName("A\u001b" + String.fromCharCode(intermediate) + "cB"), "AB")
    for (var csiFinal = 0x40; csiFinal <= 0x7e; csiFinal++)
      compare(DeckValidation.safeName("A\u001b[?1;2 $" + String.fromCharCode(csiFinal) + "B"), "AB")
    var strings = ["\u001bP", "\u001bX", "\u001b]", "\u001b^", "\u001b_", "\u0090", "\u0098", "\u009d", "\u009e", "\u009f"]
    for (var s = 0; s < strings.length; s++) {
      compare(DeckValidation.safeName("A" + strings[s] + "hidden\u001b\\B"), "AB")
      compare(DeckValidation.safeName("A" + strings[s] + "hidden\u009cB"), "AB")
      compare(DeckValidation.safeName("A" + strings[s] + "truncated"), "A")
    }
  }

  function test_independent_config_byte_cap_even_unknown_fields() {
    var value = packet([one()])
    value.unknown = "x".repeat(65536)
    compare(validate(value).reason, "too-large")
    value.unknown = "名".repeat(24000)
    compare(validate(value).reason, "too-large")
    compare(DeckValidation.utf8Bytes("a名😀"), 8)
  }

  function test_consumer_revalidates_before_retaining() {
    var input = packet([one({ categories: ["lsp", "telepathy"] })])
    input.decks[0].name = "\u001b[31mSafe\u001b[0m\u202e"
    verify(DeckValidation.validEnvelope(envelope(input), "lazyvim", maxPayloadBytes))
    var accepted = validate(input)
    compare(accepted.decks[0].name, "Safe")
    compare(accepted.decks[0].seed.categories.join(","), "lsp")
    compare(accepted.rejected, 1)
    input.decks[0].name = "Outside"
    compare(accepted.decks[0].name, "Safe")
    compare(validate(null).status, "invalid")
    verify(!DeckValidation.validEnvelope({ schemaVersion: 1, profile: "other" }, "lazyvim", maxPayloadBytes))
    verify(!DeckValidation.validEnvelope({ schemaVersion: 1, profile: "lazyvim", type: "error" }, "lazyvim", maxPayloadBytes))
  }

  function test_consumer_independent_aggregate_byte_cap() {
    var value = envelope(packet([one()]))
    value.unknown = "名".repeat(90000)
    verify(!DeckValidation.validEnvelope(value, "lazyvim", maxPayloadBytes))
    value.unknown = "x".repeat(maxPayloadBytes)
    verify(!DeckValidation.validEnvelope(value, "lazyvim", maxPayloadBytes))
  }

  function test_stream_incremental_split_record() {
    var state = DeckValidation.newStream()
    var text = JSON.stringify(envelope(packet([{ id: "safe", name: "Name" }]))) + "\n"
    var record = null
    for (var i = 0; i < text.length; i++) {
      record = DeckValidation.consumeStream(state, text[i], maxPayloadBytes)
      if (i < text.length - 1) compare(record, null)
    }
    verify(state.received)
    verify(DeckValidation.validEnvelope(record, "lazyvim", maxPayloadBytes))
    compare(validate(record.deckConfig).decks[0].name, "Name")
    compare(state.buffer, "")
    verify(!state.rejected)
    verify(DeckValidation.completeStream(state))
    verify(!Object.prototype.hasOwnProperty.call(state, "record"))
  }

  function test_stream_ascii_escapes_split_safely() {
    var state = DeckValidation.newStream()
    var text = '{"schemaVersion":1,"profile":"lazyvim","deckConfig":{"schemaVersion":1,"status":"valid",'
        + '"reason":"","rejected":0,"decks":[{"id":"safe","name":"\\u540d\\ud83d\\ude00"}]}}\n'
    var record = null
    for (var i = 0; i < text.length; i++) record = DeckValidation.consumeStream(state, text[i], maxPayloadBytes)
    compare(validate(record.deckConfig).decks[0].name, "名😀")
  }

  function test_stream_unterminated_aggregate_overflow_stops_retaining() {
    var state = DeckValidation.newStream()
    for (var i = 0; i < 65; i++) compare(DeckValidation.consumeStream(state, "x".repeat(4096), maxPayloadBytes), null)
    verify(state.rejected)
    compare(state.buffer, "")
    verify(state.bytes <= maxPayloadBytes + 1)
    DeckValidation.consumeStream(state, "x".repeat(10000), maxPayloadBytes)
    compare(state.buffer, "")
    verify(!DeckValidation.completeStream(state))
    state = DeckValidation.newStream()
    DeckValidation.consumeStream(state, "名".repeat(90000), maxPayloadBytes)
    verify(state.rejected)
    compare(state.buffer, "")
  }

  function test_stream_multiple_records_invalidates_not_last_wins() {
    var text = JSON.stringify(envelope(packet([one()]))) + "\n"
    var state = DeckValidation.newStream()
    verify(DeckValidation.consumeStream(state, text, maxPayloadBytes) !== null)
    compare(DeckValidation.consumeStream(state, text, maxPayloadBytes), null)
    verify(state.rejected)
    verify(!DeckValidation.completeStream(state))
    state = DeckValidation.newStream()
    compare(DeckValidation.consumeStream(state, text + text, maxPayloadBytes), null)
    verify(state.rejected)
  }

  function test_stream_missing_malformed_or_incomplete_payload_never_means_absent() {
    var texts = ["", "null\n", "[]\n", "{oops}\n", "{", JSON.stringify(envelope(packet([])))]
    for (var i = 0; i < texts.length; i++) {
      var state = DeckValidation.newStream()
      compare(DeckValidation.consumeStream(state, texts[i], maxPayloadBytes), null)
      verify(!DeckValidation.completeStream(state))
    }
  }
}
