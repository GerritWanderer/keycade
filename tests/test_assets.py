import json
import re
import struct
import sys
import tempfile
import unittest
import wave
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import build_locales  # noqa: E402

# The real reader, loaded the same way tests/test_decks_json.py loads it, so
# the documented decks.json example is validated against production parsing
# rather than a reimplementation.
import importlib.machinery  # noqa: E402
import importlib.util  # noqa: E402

_loader = importlib.machinery.SourceFileLoader("assets_app_config", str(ROOT / "bin/app-config-json"))
_spec = importlib.util.spec_from_loader(_loader.name, _loader)
app_config = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(app_config)

PLACEHOLDER = re.compile(r"\{(\w+)\}")
# R5: catalog values must never smuggle terminal controls or bidi overrides.
CONTROL_OR_BIDI = re.compile(
    "[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069\ufeff]")
# Chips and short buttons elide inside fixed-width controls; notices wrap to
# two bounded lines. These bounds keep both languages inside that geometry.
CHIP_KEYS = {
    "browse", "browseAdd", "browseAllCards", "browseAllCategories",
    "browseAllSources", "browseClose", "browseCustom", "browseInDeck",
    "browseInDeckAdded", "browseInDeckSeeded", "browseTargetUnavailable",
    "decksTitle",
}
MAX_UI_CHARS = 120
MAX_CHIP_CHARS = 48


class AssetTests(unittest.TestCase):
    def test_generated_locale_module_matches_the_json_sources(self):
        generated = (ROOT / "lib" / "Locales.js").read_text(encoding="utf-8")
        self.assertEqual(
            generated,
            build_locales.render(),
            "lib/Locales.js is stale; regenerate it with python3 tools/build_locales.py",
        )

    def test_generated_locale_module_has_no_runtime_io(self):
        generated = (ROOT / "lib" / "Locales.js").read_text(encoding="utf-8")
        self.assertTrue(generated.startswith(".pragma library"))
        # The generated module may only expose its embedded catalogue; it must
        # not import another source or perform runtime file/network reads.
        for forbidden in ("FileView", "XMLHttpRequest", "Qt.include", "import "):
            self.assertNotIn(forbidden, generated)

    def test_locales_have_the_same_message_keys(self):
        locale_dir = ROOT / "assets" / "locales"
        locale_files = sorted(locale_dir.glob("*.json"))
        self.assertEqual({path.name for path in locale_files}, {"en.json", "zh-CN.json"})
        messages = {
            path.name: json.loads(path.read_text(encoding="utf-8"))
            for path in locale_files
        }
        expected_ui = {key for key in messages["en.json"] if not key.startswith("action_")}
        common_actions = {key for key in messages["en.json"] if key.startswith("action_")}
        for name, value in messages.items():
            self.assertEqual(value["schemaVersion"], 1, name)
            actual_ui = {key for key in value if not key.startswith("action_")}
            self.assertEqual(actual_ui, expected_ui, name)
            self.assertTrue(common_actions.issubset(value), name)

    def test_locale_placeholders_match_across_languages(self):
        # A translation that drops or renames a {placeholder} would surface a
        # raw token in the UI; every key must interpolate the same fields in
        # every language.
        locale_dir = ROOT / "assets" / "locales"
        messages = {
            path.stem: json.loads(path.read_text(encoding="utf-8"))
            for path in locale_dir.glob("*.json")
        }
        reference = messages["en"]
        for name, catalog in messages.items():
            for key, template in reference.items():
                if not isinstance(template, str):
                    continue
                self.assertEqual(
                    set(PLACEHOLDER.findall(template)),
                    set(PLACEHOLDER.findall(catalog[key])),
                    f"{name}:{key}",
                )

    def test_ui_copy_is_bounded_plain_and_control_free(self):
        # Translations ship inside bounded, elided SafeText controls (R5):
        # they must stay plain, free of control/bidi codepoints, and short
        # enough for the fixed geometry they render into.
        locale_dir = ROOT / "assets" / "locales"
        messages = {
            path.stem: json.loads(path.read_text(encoding="utf-8"))
            for path in locale_dir.glob("*.json")
        }
        for name, catalog in messages.items():
            for key, value in catalog.items():
                if not isinstance(value, str):
                    continue
                self.assertNotEqual(value.strip(), "", f"{name}:{key}")
                self.assertIsNone(CONTROL_OR_BIDI.search(value), f"{name}:{key}")
                if key.startswith("packdesc_"):
                    continue
                self.assertLessEqual(len(value), MAX_UI_CHARS, f"{name}:{key}")
                if key in CHIP_KEYS:
                    self.assertLessEqual(len(value), MAX_CHIP_CHARS, f"{name}:{key}")

    def test_manifest_metadata_and_framing(self):
        manifest = json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))
        # Packaging identity is pinned by the marketplace contract: no
        # version bump, entry-point or lifecycle change in this package.
        self.assertEqual(manifest["schemaVersion"], 1)
        self.assertEqual(manifest["id"], "gerritwanderer.keycade-lazyvim")
        self.assertEqual(manifest["version"], "2.0.1")
        self.assertEqual(manifest["kinds"], ["overlay"])
        self.assertEqual(manifest["entryPoints"], {"overlay": "Keycade.qml"})
        self.assertIs(manifest["keepLoaded"], True)
        description = manifest["description"].lower()
        self.assertIn("lazyvim", description)
        self.assertIn("omarchy", description)
        self.assertIn("deck", description)
        for retired in ("herdr", "tmux", "neovim", "six", "cabinet", "ground"):
            self.assertNotIn(retired, description)

    def test_docs_have_no_stale_ground_framing(self):
        documents = {
            name: (ROOT / name).read_text(encoding="utf-8")
            for name in ("README.md", "README.zh-CN.md")
        }
        stale = [
            "herdr-keys-json", "tmux-keys-json",  # deleted helpers
            "test_hyprland_source_qml",  # deleted test command
            "Keyboard Layouts", "键盘布局",  # removed keysym-judging sections
            "Six dedicated training grounds", "6 个独立的快捷键机台",
            "keycade-grounds-",  # retired cabinet-grid screenshot links
        ]
        for name, text in documents.items():
            for phrase in stale:
                self.assertNotIn(phrase, text, f"{name}: {phrase}")
            # The current contract must be what the documents describe.
            self.assertIn("decks.json", text, name)
            self.assertIn("LazyVim", text, name)
            self.assertIn("Omarchy", text, name)

    def test_docs_link_no_obsolete_current_ground_images(self):
        # The generic learning-screen captures still depict the removed
        # Omarchy ground; only the LazyVim sequence captures are accurate.
        # Pin that so a grounds-era image cannot be reintroduced as current.
        obsolete = ("keycade-en.png", "keycade-zh-CN.png", "keycade-grounds-")
        expected = {"README.md": "docs/screenshots/keycade-lazyvim-en.png",
                    "README.zh-CN.md": "docs/screenshots/keycade-lazyvim-zh-CN.png"}
        for name, image in expected.items():
            text = (ROOT / name).read_text(encoding="utf-8")
            linked = [href for href in re.findall(r"!\[[^\]]*\]\(([^)]+)\)", text)
                      if href.startswith("docs/screenshots/")]
            self.assertEqual(linked, [image], name)
            for phrase in obsolete:
                self.assertNotIn(phrase, text, f"{name}: {phrase}")

    def test_docs_document_seed_rules_and_the_downgrade_limitation(self):
        # D4 coherence, and the user-chosen documented limitation: upgrades
        # preserve card records, but automatic downgrade compatibility or
        # recovery by an older release is never promised.
        anchors = {
            "README.md": {
                "present": ("seed: {}", "matches nothing", "manual-only",
                            "Back up", "quarantine", "not promised"),
                "absent": ("card history survives either way",),
            },
            "README.zh-CN.md": {
                "present": ("seed: {}", "不匹配任何卡片", "纯手工牌组",
                            "备份", "隔离", "不承诺"),
                "absent": ("两个方向都不会丢失",),
            },
        }
        for name, rules in anchors.items():
            text = (ROOT / name).read_text(encoding="utf-8")
            for phrase in rules["present"]:
                self.assertIn(phrase, text, f"{name}: {phrase}")
            for phrase in rules["absent"]:
                self.assertNotIn(phrase, text, f"{name}: {phrase}")

    def test_readme_decks_example_passes_the_real_reader(self):
        # The documented configuration example must load cleanly through the
        # production descriptor-relative reader, with nothing rejected.
        for name in ("README.md", "README.zh-CN.md"):
            text = (ROOT / name).read_text(encoding="utf-8")
            blocks = re.findall(r"```json\n(.*?)```", text, re.DOTALL)
            self.assertEqual(len(blocks), 1, f"{name}: exactly one json example")
            example = json.loads(blocks[0])
            with tempfile.TemporaryDirectory(prefix="keycade-lazyvim-readme-example-") as tmp:
                home = Path(tmp)
                files = app_config.FILES["keycade-lazyvim"]["decks"]
                target = home / files[0]
                target.parent.mkdir(parents=True)
                target.write_text(blocks[0], encoding="utf-8")
                with patch.dict("os.environ", {"XDG_CONFIG_HOME": ""}):
                    result = app_config.read_decks(home, files)
            self.assertEqual(result["status"], "valid", name)
            self.assertEqual(result["rejected"], 0, name)
            self.assertEqual([deck["id"] for deck in result["decks"]],
                             [deck["id"] for deck in example["decks"]], name)

    def test_sound_effects_are_short_mono_pcm_waves(self):
        expected = {
            "correct.wav",
            "wrong.wav",
            "countdown.wav",
            "countdown-final.wav",
            "eject.wav",
            "combo.wav",
            "mastery.wav",
        }
        sound_dir = ROOT / "assets" / "sfx"
        self.assertEqual({path.name for path in sound_dir.glob("*.wav")}, expected)
        for name in expected:
            with wave.open(str(sound_dir / name), "rb") as sound:
                self.assertEqual(sound.getnchannels(), 1, name)
                self.assertEqual(sound.getsampwidth(), 2, name)
                self.assertEqual(sound.getframerate(), 44100, name)
                duration = sound.getnframes() / sound.getframerate()
                self.assertGreater(duration, 0.04, name)
                self.assertLess(duration, 0.35, name)

    def test_scanline_tile_is_a_tiny_transparent_png(self):
        # The overlay is a tiled 1x2 image rather than hundreds of rectangles
        # or a shader, so the only thing worth pinning is that it stays tiny
        # and keeps the shape that makes tiling produce lines.
        tile = ROOT / "assets" / "scanline.png"
        data = tile.read_bytes()
        self.assertLess(len(data), 1024)
        self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
        width, height, depth, colour_type = struct.unpack(">IIBB", data[16:26])
        self.assertEqual((width, height), (1, 2))
        self.assertEqual(depth, 8)
        self.assertEqual(colour_type, 6)


if __name__ == "__main__":
    unittest.main()
