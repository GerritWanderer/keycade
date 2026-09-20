import json
import os
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHUNK_CHARACTERS = 8 * 1024
SCRIPT = ROOT / "bin" / "state-store"


class StateStoreHelperTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.state_home = self.root / "state"
        self.environment = os.environ.copy()
        self.environment["XDG_STATE_HOME"] = str(self.state_home)

    def tearDown(self):
        self.temporary.cleanup()

    @property
    def state_dir(self):
        return self.state_home / "omarchy" / "keycade-lazyvim"

    def run_helper(self, *arguments, payload=None, check=True, timeout=2):
        return subprocess.run(
            [str(SCRIPT), *arguments],
            input=payload,
            capture_output=True,
            env=self.environment,
            check=check,
            timeout=timeout,
        )

    def load(self):
        """Reassemble the newline-delimited load stream into the old shape.

        The helper streams a header, one record per file and its chunks so the
        QML consumer can bound the response while reading it; the tests assert
        against the reassembled result.
        """
        records = [json.loads(line) for line in self.run_helper("load").stdout.splitlines() if line.strip()]
        self.assertEqual(records[0]["type"], "header")
        self.assertEqual(records[-1]["type"], "end")
        payload = {"schemaVersion": records[0]["schemaVersion"], "files": {}}
        current = None
        for record in records[1:-1]:
            if record["type"] == "file":
                current = {"status": record["status"], "text": "", "chunks": record["chunks"]}
                if "quarantinedAs" in record:
                    current["quarantinedAs"] = record["quarantinedAs"]
                payload["files"][record["kind"]] = current
            else:
                self.assertEqual(record["type"], "chunk")
                payload["files"][record["kind"]]["text"] += record["data"]
        for entry in payload["files"].values():
            declared = entry.pop("chunks")
            expected = -(-len(entry["text"]) // CHUNK_CHARACTERS)
            self.assertEqual(declared, expected, "chunk count did not match the streamed text")
        return payload

    def test_load_creates_private_directory(self):
        payload = self.load()
        self.assertEqual(payload["schemaVersion"], 1)
        self.assertEqual(payload["files"]["stats"]["status"], "missing")
        self.assertEqual(stat.S_IMODE(self.state_dir.stat().st_mode), 0o700)

    def test_atomic_write_uses_private_regular_file(self):
        value = {"schemaVersion": 3, "bindings": {}}
        self.run_helper("write", "stats", payload=json.dumps(value).encode() + b"\n")
        path = self.state_dir / "stats.json"
        self.assertTrue(path.is_file())
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(json.loads(path.read_text()), value)
        self.assertFalse(list(self.state_dir.glob(".stats.json.tmp-*")))

    def test_symlink_is_quarantined_without_touching_target(self):
        self.load()
        victim = self.root / "victim"
        victim.write_text("unchanged", encoding="utf-8")
        (self.state_dir / "settings.json").symlink_to(victim)
        payload = self.load()
        self.assertEqual(payload["files"]["settings"]["status"], "quarantined")
        self.assertEqual(victim.read_text(encoding="utf-8"), "unchanged")
        self.assertFalse((self.state_dir / "settings.json").exists())
        self.assertEqual(len(list(self.state_dir.glob("settings.json.corrupt-*"))), 1)

    def test_fifo_is_rejected_without_blocking(self):
        self.load()
        os.mkfifo(self.state_dir / "session.json")
        started = time.monotonic()
        payload = self.load()
        self.assertLess(time.monotonic() - started, 1)
        self.assertEqual(payload["files"]["session"]["status"], "quarantined")

    def test_hard_link_is_rejected_without_modifying_other_link(self):
        self.load()
        victim = self.root / "victim"
        victim.write_text('{"schemaVersion":3}', encoding="utf-8")
        os.link(victim, self.state_dir / "stats.json")
        payload = self.load()
        self.assertEqual(payload["files"]["stats"]["status"], "quarantined")
        self.assertEqual(victim.read_text(encoding="utf-8"), '{"schemaVersion":3}')

    def test_oversized_file_is_quarantined(self):
        self.load()
        (self.state_dir / "settings.json").write_bytes(b"x" * (64 * 1024 + 1))
        payload = self.load()
        self.assertEqual(payload["files"]["settings"]["status"], "quarantined")

    def test_quarantine_write_preserves_bad_file_and_installs_new_value(self):
        self.load()
        path = self.state_dir / "settings.json"
        path.write_text("not-json", encoding="utf-8")
        value = {"schemaVersion": 3, "locale": "en"}
        self.run_helper(
            "write", "settings", "--quarantine",
            payload=json.dumps(value).encode() + b"\n",
        )
        self.assertEqual(json.loads(path.read_text()), value)
        quarantined = list(self.state_dir.glob("settings.json.corrupt-*"))
        self.assertEqual(len(quarantined), 1)
        self.assertEqual(quarantined[0].read_text(), "not-json")

    def test_symlinked_private_directory_is_refused(self):
        target = self.root / "target"
        target.mkdir()
        (self.state_home / "omarchy").mkdir(parents=True)
        (self.state_home / "omarchy" / "keycade-lazyvim").symlink_to(target)
        result = self.run_helper("load", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(target.iterdir()), [])

    @property
    def legacy_dir(self):
        return self.state_home / "omarchy" / "keycade"

    def seed_legacy(self, locale="en", mode=None):
        """A pre-rename state directory, as the keycade release left it."""
        self.legacy_dir.mkdir(parents=True)
        (self.legacy_dir / "settings.json").write_text(
            json.dumps({"schemaVersion": 4, "locale": locale}), encoding="utf-8")
        if mode is not None:
            self.legacy_dir.chmod(mode)

    def test_legacy_directory_is_adopted_with_its_history(self):
        self.seed_legacy(mode=0o755)
        loaded = self.load()
        self.assertEqual(json.loads(loaded["files"]["settings"]["text"])["locale"], "en")
        self.assertFalse(self.legacy_dir.exists())
        self.assertTrue((self.state_dir / "settings.json").exists())
        # The adopted directory is held to the same privacy as a fresh one.
        self.assertEqual(stat.S_IMODE(self.state_dir.stat().st_mode), 0o700)

    def test_current_directory_wins_and_legacy_is_left_untouched(self):
        self.seed_legacy(locale="en")
        self.state_dir.mkdir(parents=True, mode=0o700)
        (self.state_dir / "settings.json").write_text(
            json.dumps({"schemaVersion": 4, "locale": "zh-CN"}), encoding="utf-8")
        loaded = self.load()
        self.assertEqual(json.loads(loaded["files"]["settings"]["text"])["locale"], "zh-CN")
        # Never merged, never deleted: the user can still inspect the old one.
        self.assertEqual(json.loads((self.legacy_dir / "settings.json").read_text())["locale"], "en")

    def test_symlinked_legacy_directory_is_not_followed(self):
        target = self.root / "elsewhere"
        target.mkdir()
        (target / "settings.json").write_text(
            json.dumps({"schemaVersion": 4, "locale": "en"}), encoding="utf-8")
        (self.state_home / "omarchy").mkdir(parents=True)
        self.legacy_dir.symlink_to(target)
        loaded = self.load()
        self.assertEqual(loaded["files"]["settings"]["status"], "missing")
        self.assertTrue(self.legacy_dir.is_symlink())
        self.assertTrue((target / "settings.json").exists())

    def test_legacy_name_that_is_not_a_directory_is_ignored(self):
        (self.state_home / "omarchy").mkdir(parents=True)
        self.legacy_dir.write_text("not a directory", encoding="utf-8")
        loaded = self.load()
        self.assertEqual(loaded["files"]["settings"]["status"], "missing")
        self.assertEqual(self.legacy_dir.read_text(), "not a directory")
        self.assertTrue(self.state_dir.is_dir())

    def test_oversized_stdin_is_rejected(self):
        result = self.run_helper(
            "write", "settings",
            payload=b"x" * (64 * 1024 + 1) + b"\n",
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.state_dir / "settings.json").exists())


if __name__ == "__main__":
    unittest.main()
