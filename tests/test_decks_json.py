"""Deck boundary tests: synthetic files only, no configuration writes outside tmp."""
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader("decks_app_config", str(ROOT / "bin/app-config-json"))
spec = importlib.util.spec_from_loader(loader.name, loader)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)

# Kept in step with tst_decks_reader.qml; also sent directly to the real QML
# AppConfigSource.accept() below, without passing through the Python sanitizer.
TERMINAL_CASES = [
    ("save", "A\x1b7B", "AB"), ("restore", "A\x1b8B", "AB"),
    ("keypad-on", "A\x1b=B", "AB"), ("keypad-off", "A\x1b>B", "AB"),
    ("reset", "A\x1bcB", "AB"), ("alignment", "A\x1b#8B", "AB"),
    ("charset", "A\x1b(B\x1b%GB", "AB"),
    ("truncated-escape", "A\x1b", "A"), ("truncated-intermediate", "A\x1b#", "A"),
    ("truncated-csi", "A\x1b[31;", "A"), ("truncated-c1-csi", "A\x9b31;", "A"),
    ("truncated-dcs", "A\x1bPsecret", "A"), ("truncated-osc", "A\x1b]secret\x1b", "A"),
    ("restarted-csi", "A\x1b[31\x1b7B", "AB"),
    ("restarted-escape", "A\x1b#\x1b8B", "AB"),
    ("restarted-c1-csi", "A\x1b#\x9b31mB", "AB"),
    ("restarted-c1-osc", "A\x1b[31\x9dtitle\x07B", "AB"),
    ("malformed-csi-order", "A\x1b[1 2mB", "AB"),
    ("malformed-csi-unicode", "A\x1b[12é34mB", "AB"),
    ("malformed-escape-unicode", "A\x1bé7B", "AB"),
    ("malformed-string-escape", "A\x1b]title\x1bxsecret\x07B", "AB"),
    ("truncated-malformed-string", "A\x1b]title\x1bxsecret", "A"),
    ("dcs-bel-not-terminator", "A\x1bPsecret\x07hidden\x1b\\B", "AB"),
    ("cancel-csi", "A\x1b[31\x18B", "AB"), ("cancel-escape", "A\x1b#\x1aB", "AB"),
    ("control-in-csi", "A\x1b[31\nmB", "AB"), ("del-in-escape", "A\x1b#\x7f8B", "AB"),
]


class DeckReaderTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="keycade-decks-test-")
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        self.files = helper.FILES["keycade"]["decks"]
        self.path = self.home / self.files[0]
        self.path.parent.mkdir(parents=True)
        environment = patch.dict(os.environ, {"XDG_CONFIG_HOME": ""})
        environment.start()
        self.addCleanup(environment.stop)

    def read(self):
        result = helper.read_decks(self.home, self.files)
        self.assertEqual(set(result), {"schemaVersion", "status", "decks", "reason", "rejected"})
        self.assertEqual(result["schemaVersion"], 1)
        self.assertLessEqual(len(result["reason"]), 128)
        self.assertLessEqual(len(result["decks"]), 32)
        self.assertLessEqual(len(json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode()), 65536)
        return result

    def write(self, decks, **extra):
        self.path.write_text(json.dumps({"schemaVersion": 1, "decks": decks, **extra}), encoding="utf-8")
        return self.read()

    def test_three_valid_declarations_preserve_order_and_seed_presence(self):
        decks = [{"id": "marks", "name": "Marks & Jumps", "seed": {
            "extras": ["lazyvim.plugins.extras.editor.harpoon2"]}},
            {"id": "lsp", "name": "LSP", "seed": {"categories": ["lsp", "diagnostics"],
                                                        "contexts": ["normal"]}},
            {"id": "nemesis", "name": "Keeps Getting Me"}]
        self.assertEqual(self.write(decks), helper.deck_result("valid", decks=decks))

    def test_absent_valid_empty_and_invalid_are_three_distinct_outcomes(self):
        self.assertEqual(self.read(), helper.deck_result("absent"))
        self.assertEqual(self.write([]), helper.deck_result("valid"))
        for text in ("null", "false", "[]", "{}", "", "{broken", '{"schemaVersion":true,"decks":[]}',
                     '{"schemaVersion":1.0,"decks":[]}', '{"schemaVersion":2,"decks":[]}',
                     '{"schemaVersion":1,"decks":null}', '{"schemaVersion":1,"decks":[],"x":NaN}',
                     "[" * 2000 + "]" * 2000):
            with self.subTest(text=text[:80]):
                self.path.write_text(text)
                found = self.read()
                self.assertEqual(found["status"], "invalid")
                self.assertEqual(found["decks"], [])
                self.assertTrue(found["reason"])
                self.assertGreater(found["rejected"], 0)

    def test_all_honors_name_ignores_any_seed_without_minting_or_reordering(self):
        for seed in ({"categories": ["telepathy"]}, None, "invalid", {"__proto__": True}):
            with self.subTest(seed=seed):
                found = self.write([{"id": "other", "name": "Other"},
                                    {"id": "all", "name": "Everything", "seed": seed}])
                self.assertEqual(found["decks"], [{"id": "other", "name": "Other"},
                                                   {"id": "all", "name": "Everything"}])
                self.assertEqual(found["rejected"], 0)

    def test_first_32_declarations_only_not_first_32_valid(self):
        declarations = [{"id": "deck-" + str(i), "name": str(i)} for i in range(40)]
        found = self.write(declarations)
        self.assertEqual(found["decks"], declarations[:32])
        self.assertEqual(found["rejected"], 8)
        declarations[0] = {"id": "INVALID", "name": "Bad"}
        found = self.write(declarations)
        self.assertEqual(found["decks"], declarations[1:32])
        self.assertEqual(found["rejected"], 9)

    def test_id_schema_duplicates_and_first_declaration_wins(self):
        bad = ["", "A", "a_b", "a/b", "a b", "a\n", "a" * 33,
               "__proto__", "constructor", "prototype", 1, None, {}]
        declarations = [{"id": value, "name": "Bad"} for value in bad]
        declarations += [{"id": "a" * 32, "name": "At limit"}, {"id": "a", "name": "First"},
                         {"id": "a", "name": "Second"}, {"id": "broken", "name": None},
                         {"id": "broken", "name": "Cannot replace first"}]
        found = self.write(declarations)
        self.assertEqual(found["decks"], declarations[len(bad):len(bad) + 2])
        self.assertEqual(found["rejected"], len(bad) + 3)

    def test_rejects_wrong_deck_name_and_seed_types(self):
        found = self.write([None, [], "deck", 2, {"id": "a"}, {"id": "b", "name": {}},
                            {"id": "c", "name": "\x1b[31m\n\u202e"},
                            {"id": "d", "name": "D", "seed": []},
                            {"id": "e", "name": "E", "seed": None},
                            {"id": "good", "name": "Good"}])
        self.assertEqual(found["decks"], [{"id": "good", "name": "Good"}])
        self.assertEqual(found["rejected"], 9)

    def test_unknown_keys_and_prototype_keys_are_ignored_and_counted(self):
        found = self.write([{"id": "safe", "name": "Safe", "unknown": True, "__proto__": {},
                            "constructor": {}, "prototype": {}, "seed": {
                                "categories": ["lsp"], "unknown": 1, "__proto__": {},
                                "constructor": {}, "prototype": {}}}],
                           unknown=1, __proto__={}, constructor={}, prototype={})
        self.assertEqual(found["decks"], [{"id": "safe", "name": "Safe", "seed": {"categories": ["lsp"]}}])
        self.assertEqual(found["rejected"], 12)

    def test_closed_vocabulary_rejections_preserve_empty_dimensions(self):
        seed = {"categories": ["telepathy", "constructor", "__proto__", "prototype", 1, None, "x" * 33],
                "extras": ["lazyvim.plugins.extras.lang.imaginary", "x" * 129],
                "contexts": ["prefix", "normal", "normal", {}]}
        found = self.write([{"id": "safe", "name": "Safe", "seed": seed}])
        self.assertEqual(found["decks"][0]["seed"], {"categories": [], "extras": [], "contexts": ["normal"]})
        self.assertEqual(found["rejected"], 12)
        found = self.write([{"id": "safe", "name": "Safe", "seed": {
            "categories": "lsp", "extras": None, "contexts": {"normal": True}}}])
        self.assertEqual(found["decks"][0]["seed"], {"categories": [], "extras": [], "contexts": []})
        self.assertEqual(found["rejected"], 3)

    def test_caps_each_seed_dimension_and_counts_duplicates(self):
        seed = {"categories": ["lsp"] * 26,
                "extras": ["lazyvim.plugins.extras.editor.harpoon2"] * 34,
                "contexts": ["normal"] * 10}
        found = self.write([{"id": "safe", "name": "Safe", "seed": seed}])
        self.assertEqual(found["rejected"], 67)
        self.assertEqual(found["decks"][0]["seed"], {key: values[:1] for key, values in seed.items()})

    def test_vocabulary_is_shipped_pack_data_not_enabled_extras_or_a_copy(self):
        pack = json.loads((ROOT / "assets/packs/lazyvim.json").read_text())
        self.assertEqual(helper.deck_vocabulary(), {key: set(pack[key]) for key in helper.SEED_LIMITS})
        # An inactive but shipped provider is still a legal seed declaration.
        for key, (cap, _chars) in helper.SEED_LIMITS.items():
            found = self.write([{"id": "safe", "name": "Safe", "seed": {key: pack[key][:cap]}}])
            self.assertEqual(found["rejected"], 0)
            self.assertEqual(found["decks"][0]["seed"][key], pack[key][:cap])
        with patch.object(helper, "PACK_ROOT", self.home):
            self.assertEqual(self.read()["status"], "invalid")

    def test_names_strip_terminal_controls_bidi_surrogates_and_cap_codepoints(self):
        cases = [("\x1b[31mRed\x1b[0m\x00\x85\u061c\u200e\u2028\u2029\u202e\u2069\u206a\u206f", "Red"),
                 ("\x1b]0;secret\x07Name\x1b]8;;link\x1b\\X\x1b]8;;\x1b\\", "NameX"),
                 ("\x9dtitle\x9cA\x9b31mB\x9b0m\x1bPsecret\x1b\\C", "ABC"),
                 ("Name\x1b]unfinished", "Name"), ("a" * 80, "a" * 48),
                 ("😀" * 49, "😀" * 48), ("A\ud800B\udfffC", "ABC"),
                 ("<b>Plain text</b>", "<b>Plain text</b>")]
        for value, expected in cases:
            with self.subTest(value=repr(value)):
                self.assertEqual(self.write([{"id": "safe", "name": value}])["decks"][0]["name"], expected)

    def test_terminal_escape_grammar_and_malformed_sequences(self):
        for tag, text, expected in TERMINAL_CASES:
            with self.subTest(tag=tag):
                self.assertEqual(self.write([{"id": "safe", "name": text}])["decks"][0]["name"], expected)
        # Every generic ESC final and intermediate, not just the reported six.
        for final in range(0x30, 0x7f):
            text = "A\x1b#" + chr(final) + "B"
            self.assertEqual(helper.deck_name(text), "AB", repr(text))
            if chr(final) not in "[]PX^_":
                self.assertEqual(helper.deck_name("A\x1b" + chr(final) + "B"), "AB")
        for intermediate in range(0x20, 0x30):
            self.assertEqual(helper.deck_name("A\x1b" + chr(intermediate) + "cB"), "AB")
        for final in range(0x40, 0x7f):
            self.assertEqual(helper.deck_name("A\x1b[?1;2 $" + chr(final) + "B"), "AB")
        for prefix in ("\x1bP", "\x1bX", "\x1b]", "\x1b^", "\x1b_", "\x90", "\x98", "\x9d", "\x9e", "\x9f"):
            for terminator in ("\x1b\\", "\x9c"):
                self.assertEqual(helper.deck_name("A" + prefix + "hidden" + terminator + "B"), "AB")
            self.assertEqual(helper.deck_name("A" + prefix + "truncated"), "A")

    def test_64k_file_cap_invalid_utf8_and_non_regular_inputs(self):
        for raw, reason in ((b" " * 65537, "too-large"), (b"\xff", "invalid-utf8")):
            self.path.write_bytes(raw)
            self.assertEqual(self.read(), helper.deck_result("invalid", reason, rejected=1))
        raw = b'{"schemaVersion":1,"decks":[]}'
        self.path.write_bytes(raw + b" " * (65536 - len(raw)))
        self.assertEqual(self.read()["status"], "valid")
        self.path.unlink()
        self.path.mkdir()
        self.assertEqual(self.read()["reason"], "non-regular")
        self.path.rmdir()
        os.mkfifo(self.path)
        self.assertEqual(self.read()["reason"], "non-regular")

    def test_unreadable_is_invalid_not_absent_and_other_calibration_survives(self):
        self.write([])
        self.path.chmod(0)
        self.addCleanup(self.path.chmod, 0o600)
        self.assertEqual(self.read()["status"], "invalid")
        options = self.home / ".config/nvim/lua/config/options.lua"
        options.parent.mkdir(parents=True)
        options.write_text('vim.g.mapleader = ","')
        found = helper.snapshot("lazyvim", self.home)
        self.assertEqual(found["options"]["leader"], ",")
        self.assertEqual(found["deckConfig"]["status"], "invalid")

    def test_file_parent_and_home_ancestor_symlinks_are_never_followed(self):
        target = self.home / "target.json"
        target.write_text('{"schemaVersion":1,"decks":[]}')
        self.path.symlink_to(target)
        self.assertEqual(self.read()["status"], "invalid")
        self.path.unlink()
        self.path.symlink_to(self.home / "missing.json")
        self.assertEqual(self.read()["status"], "invalid")
        self.path.unlink()
        parent = self.path.parent
        parent.rmdir()
        parent.symlink_to(self.home)
        self.assertEqual(self.read()["status"], "invalid")
        alias = self.home / "alias"
        alias.symlink_to(self.home)
        self.assertEqual(helper.read_decks(alias / "child", self.files)["status"], "invalid")

    def test_xdg_absolute_root_and_missing_xdg_do_not_read_default_file(self):
        self.write([{"id": "default", "name": "Default"}])
        root = self.home / "xdg"
        config = root / "omarchy/keycade/decks.json"
        config.parent.mkdir(parents=True)
        with patch.dict(os.environ, {"XDG_CONFIG_HOME": str(root)}):
            self.assertEqual(self.read()["status"], "absent")
            config.write_text('{"schemaVersion":1,"decks":[{"id":"xdg","name":"XDG"}]}')
            self.assertEqual(self.read()["decks"], [{"id": "xdg", "name": "XDG"}])
        alias = self.home / "alias"
        alias.symlink_to(root)
        for value in ("relative/path", str(alias), str(alias / "child"), str(root) + "/../xdg", "/tmp/bad\x01"):
            with self.subTest(value=value), patch.dict(os.environ, {"XDG_CONFIG_HOME": value}):
                self.assertEqual(self.read()["status"], "invalid")

    def test_aggregate_deck_output_bound(self):
        pack = json.loads((ROOT / "assets/packs/lazyvim.json").read_text())
        seed = {"categories": pack["categories"], "extras": pack["extras"], "contexts": pack["contexts"]}
        declarations = [{"id": "deck-" + str(i), "name": "名" * 48, "seed": seed} for i in range(32)]
        result = self.write(declarations)
        self.assertEqual(result["status"], "valid")
        self.assertEqual(len(result["decks"]), 32)
        result = self.write(declarations, padding="x" * 65536)
        self.assertEqual(result["status"], "invalid")
        self.assertEqual(result["reason"], "too-large")

    def test_combined_config_transport_aggregate_budget(self):
        # Each input is within its own 64 KiB cap, but ASCII transport escaping
        # can push the COMBINED calibration + deck payload over 256 KiB.
        nvim = self.home / ".config/nvim"
        (nvim / "lua/config").mkdir(parents=True)
        extras = ["extra" + str(i) + "x" * (123 - len(str(i))) for i in range(128)]
        (nvim / "lazyvim.json").write_text(json.dumps({"extras": extras}))
        (nvim / "lua/config/options.lua").write_text('vim.g.mapleader = ","')
        lines = []
        for index in range(128):
            line = 'vim.keymap.set("n", "<leader>x%d", "noop", { desc = "%s" })\n' % (index, "é" * 512)
            if len(("".join(lines) + line).encode()) > helper.MAX_FILE_BYTES:
                break
            lines.append(line)
        keymaps = nvim / "lua/config/keymaps.lua"
        keymaps.write_text("".join(lines), encoding="utf-8")
        pack = json.loads((ROOT / "assets/packs/lazyvim.json").read_text())
        seed = {key: pack[key] for key in helper.SEED_LIMITS}
        declarations = [{"id": "deck-" + str(i), "name": "😀" * 48, "seed": seed} for i in range(32)]
        self.path.write_text(json.dumps({"schemaVersion": 1, "decks": declarations},
                                       ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
        for path in (keymaps, nvim / "lazyvim.json", self.path):
            self.assertLessEqual(path.stat().st_size, helper.MAX_FILE_BYTES)
        snapshot = helper.snapshot("lazyvim", self.home)
        self.assertEqual(len(snapshot["bindings"]), len(lines))
        self.assertEqual(len(snapshot["extras"]), 128)
        self.assertEqual(len(snapshot["deckConfig"]["decks"]), 32)
        self.assertGreater(len(json.dumps(snapshot, ensure_ascii=True, separators=(",", ":")).encode()),
                           helper.MAX_PAYLOAD_BYTES)
        command = ["/usr/bin/python3", str(ROOT / "bin/bounded-relay"), "--max-bytes", "524288",
                   "--deadline", "3", "--", "/usr/bin/python3", str(ROOT / "bin/app-config-json"),
                   "--profile", "lazyvim"]
        environment = {"PATH": "/usr/bin", "HOME": str(self.home), "XDG_CONFIG_HOME": ""}
        overflow = subprocess.run(command, env=environment, capture_output=True, timeout=5, check=True)
        self.assertLessEqual(len(overflow.stdout), helper.MAX_PAYLOAD_BYTES + 1)
        self.assertEqual(json.loads(overflow.stdout)["error"], "payload exceeds its limit")
        # The same combined launch succeeds when under the aggregate budget.
        keymaps.write_text("".join(lines[:40]), encoding="utf-8")
        accepted = subprocess.run(command, env=environment, capture_output=True, timeout=5, check=True)
        self.assertLessEqual(len(accepted.stdout), helper.MAX_PAYLOAD_BYTES + 1)
        payload = json.loads(accepted.stdout)
        self.assertEqual(payload["options"]["leader"], ",")
        self.assertEqual(len(payload["bindings"]), 40)
        self.assertEqual(len(payload["extras"]), 128)
        self.assertEqual(len(payload["deckConfig"]["decks"]), 32)
        self.assertEqual(payload["deckConfig"]["status"], "valid")

    def test_actual_app_config_source_launch_and_accept_retention(self):
        # qmltestrunner cannot instantiate Quickshell's executable-only plugin.
        # Use the REAL component in offscreen Quickshell, not a copied accept()
        # implementation, stub, or source-rewriting test bypass. All config,
        # caches and runtime/log files stay in this synthetic home.
        nvim = self.home / ".config/nvim"
        (nvim / "lua/config").mkdir(parents=True)
        (nvim / "lua/config/options.lua").write_text('vim.g.mapleader = ","\nvim.g.maplocalleader = ";"')
        extra = "lazyvim.plugins.extras.editor.harpoon2"
        (nvim / "lazyvim.json").write_text(json.dumps({"extras": [extra]}))
        (nvim / "lazy-lock.json").write_text(json.dumps({"LazyVim": {"commit": "a" * 40}}))
        (nvim / "lua/config/keymaps.lua").write_text(
            'vim.keymap.set("n", "<leader>zz", "noop", { desc = "Combined mapping" })')
        self.write([{"id": "loaded", "name": "\x1b7Launch\x1b#8", "seed": {"categories": ["lsp", "telepathy"]}}])
        xdg = self.home / "xdg"
        deck_path = xdg / "omarchy/keycade/decks.json"
        deck_path.parent.mkdir(parents=True)
        deck_path.write_bytes(self.path.read_bytes())
        runtime = self.home / "runtime"
        runtime.mkdir(mode=0o700)
        shell = self.home / "shell.qml"
        shell.write_text(r'''import QtQuick
import Quickshell
import "__SOURCE_URL__" as Sources
Scope {
  property int assertions: 0
  property var escapeCases: __ESCAPE_CASES__
  function check(condition, message) {
    assertions++
    if (!condition) throw new Error(message)
  }
  function retained() {
    return JSON.stringify([source.options, source.extras, source.bindings,
                           source.bindingSkipped, source.skipped, source.deckConfig])
  }
  function packet(name) {
    return { schemaVersion: 1, profile: "lazyvim", options: { leader: ";" },
             extras: ["lazyvim.plugins.extras.editor.harpoon2"],
             bindings: [{ op: "set", lhs: "<leader>zz", desc: "Accepted mapping", contexts: ["normal"] }],
             bindingSkipped: { "unsupported-shape": 2 }, skipped: { leader: "test reason" },
             deckConfig: { schemaVersion: 1, status: "valid", reason: "", rejected: 0,
                           decks: [{ id: "safe", name: name, unknown: true,
                                     seed: { categories: ["lsp", "telepathy"] } }] } }
  }
  function exercise() {
    // First assert that the real, existing helper launch combined all fields.
    check(source.options.leader === "," && source.options.localleader === ";", "launched options")
    check(source.extras[0] === "lazyvim.plugins.extras.editor.harpoon2", "launched extras")
    check(source.bindings.length === 1 && source.bindings[0].desc === "Combined mapping", "launched bindings")
    check(source.deckConfig.status === "valid" && source.deckConfig.decks[0].name === "Launch", "launched decks")
    check(source.deckConfig.rejected === 1, "launched rejected value")
    // Then bypass the PRODUCER, never the consumer: hostile helper output must
    // be independently checked by AppConfigSource.accept before retention.
    for (var i = 0; i < escapeCases.length; i++) {
      var row = escapeCases[i]
      check(source.accept(packet(row[1])), "accept " + row[0])
      check(source.deckConfig.decks[0].name === row[2], "escape " + row[0])
      check(source.deckConfig.rejected === 2, "count unknown key/value " + row[0])
      check(source.deckConfig.decks[0].seed.categories.join(",") === "lsp", "closed vocabulary " + row[0])
    }
    var original = packet("Owned")
    check(source.accept(original), "accept owned")
    var before = retained()
    original.options.leader = "mutated"
    original.extras.push("mutated")
    original.bindings[0].desc = "mutated"
    original.bindings[0].contexts.push("visual")
    original.skipped.leader = "mutated"
    original.deckConfig.decks[0].name = "mutated"
    original.deckConfig.decks[0].seed.categories.push("git")
    check(retained() === before, "retained no external aliases")
    var huge = packet("Unretained")
    huge.padding = "名".repeat(90000)
    check(!source.accept(huge), "reject combined byte overflow")
    check(retained() === before, "aggregate rejection retained nothing")
    var wrong = packet("Wrong profile")
    wrong.profile = "other"
    check(!source.accept(wrong) && retained() === before, "envelope rejection retained nothing")
    var overDeck = packet("x".repeat(65536))
    check(source.accept(overDeck), "valid aggregate with invalid deck sub-cap")
    check(source.deckConfig.status === "invalid" && source.deckConfig.reason === "too-large"
          && source.deckConfig.decks.length === 0, "deck sub-cap retained no declarations")
    check(source.options.leader === ";" && source.bindings.length === 1, "invalid deck did not block calibration")
    var prototype = packet("Prototype")
    prototype.deckConfig.decks[0] = JSON.parse('{"id":"safe","name":"Safe","__proto__":{},"constructor":{},"prototype":{},"seed":{"categories":["lsp","constructor"]}}')
    check(source.accept(prototype), "accept prototype attempt envelope")
    check(source.deckConfig.rejected === 4, "prototype keys and value counted")
    check(Object.keys(source.deckConfig.decks[0]).sort().join(",") === "id,name,seed", "foreign keys not retained")
    check(Object.getPrototypeOf(source.deckConfig.decks[0].seed) === null, "retained map is prototype-safe")
    var badSchema = packet("Invalid")
    badSchema.deckConfig.status = "success"
    check(source.accept(badSchema) && source.deckConfig.status === "invalid"
          && source.deckConfig.decks.length === 0, "hostile status not retained")
    // Also exercise the real consumer's incremental path and clearing behavior.
    source.reset()
    var text = JSON.stringify(packet("Stream")) + "\n"
    for (var at = 0; at < text.length; at += 17) source.consume(text.slice(at, at + 17))
    check(source.deckConfig.status === "valid" && source.deckConfig.decks[0].name === "Stream", "actual stream acceptance")
    source.consume("x".repeat(source.maxPayloadBytes))
    check(source.deckConfig.status === "invalid" && source.deckConfig.decks.length === 0, "overflow clears decks")
    check(Object.keys(source.options).length === 0 && source.extras.length === 0
          && source.bindings.length === 0, "overflow clears combined calibration")
  }
  Sources.AppConfigSource {
    id: source
    profileId: "lazyvim"
    onFinished: {
      try {
        exercise()
        console.log("DECK-INTEGRATION " + JSON.stringify({ ok: true, assertions: assertions }))
      } catch (error) {
        console.log("DECK-INTEGRATION " + JSON.stringify({ ok: false, error: String(error), assertions: assertions }))
      }
      Qt.quit()
    }
  }
  Timer { interval: 10; running: true; onTriggered: source.refresh() }
  Timer {
    interval: 8000; running: true
    onTriggered: { console.log('DECK-INTEGRATION {"ok":false,"error":"timeout"}'); Qt.quit() }
  }
}
'''.replace("__SOURCE_URL__", (ROOT / "lib/sources").as_uri())
            .replace("__ESCAPE_CASES__", json.dumps(TERMINAL_CASES)), encoding="utf-8")
        environment = {"PATH": "/usr/bin", "HOME": str(self.home), "XDG_CONFIG_HOME": str(xdg),
                       "XDG_RUNTIME_DIR": str(runtime), "XDG_CACHE_HOME": str(self.home / "cache"),
                       "XDG_STATE_HOME": str(self.home / "state"), "QT_QPA_PLATFORM": "offscreen"}
        completed = subprocess.run(["/usr/bin/quickshell", "-p", str(shell), "--no-color"],
                                   env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, timeout=12)
        self.assertEqual(completed.returncode, 0, completed.stdout)
        reports = [line.split("DECK-INTEGRATION ", 1)[1] for line in completed.stdout.splitlines()
                   if "DECK-INTEGRATION " in line]
        self.assertEqual(len(reports), 1, completed.stdout)
        report = json.loads(reports[0])
        self.assertTrue(report["ok"], report)
        self.assertGreaterEqual(report["assertions"], len(TERMINAL_CASES) * 4 + 20)

    def test_cli_existing_launch_has_decks_ascii_transport_and_only_lazyvim_profile(self):
        self.write([{"id": "safe", "name": "名字😀"}])
        # Match the consumer's fixed, sanitized environment and existing relay.
        command = ["/usr/bin/python3", str(ROOT / "bin/bounded-relay"), "--max-bytes", "524288",
                   "--deadline", "3", "--", "/usr/bin/python3", str(ROOT / "bin/app-config-json"),
                   "--profile", "lazyvim"]
        found = subprocess.run(command, env={"PATH": "/usr/bin", "HOME": str(self.home),
                                             "XDG_CONFIG_HOME": ""}, capture_output=True, timeout=5, check=True)
        self.assertTrue(found.stdout.isascii())
        self.assertLessEqual(len(found.stdout), helper.MAX_PAYLOAD_BYTES + 1)
        self.assertEqual(json.loads(found.stdout)["deckConfig"]["decks"][0]["name"], "名字😀")
        rejected = subprocess.run(["/usr/bin/python3", str(ROOT / "bin/app-config-json"),
                                   "--profile", "keycade", "--home", str(self.home)],
                                  capture_output=True, timeout=5)
        self.assertNotEqual(rejected.returncode, 0)


if __name__ == "__main__":
    unittest.main()
