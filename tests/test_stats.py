"""Behavioral tests of the real Stats.js in Qt's JS engine, not source checks."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests/fixtures/migration"
RUNNER = "/usr/lib/qt6/bin/qmltestrunner"


def fixture(name):
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


def stats_eval(expression, value):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        runtime = root / "runtime"
        runtime.mkdir(mode=0o700)
        script = root / "tst_stats.qml"
        script.write_text('''import QtQuick
import QtTest
import "%s" as Stats
TestCase {
  name: "StatsBehavior"
  function test_evaluate() {
    var input = %s
    var result = %s
    console.log("STATS-RESULT " + JSON.stringify(result))
  }
}
''' % ((ROOT / "lib/Stats.js").as_uri(), json.dumps(value), expression), encoding="utf-8")
        environment = dict(os.environ, QT_QPA_PLATFORM="offscreen", XDG_RUNTIME_DIR=str(runtime),
                           HOME=directory, XDG_STATE_HOME=str(root / "state"),
                           XDG_CACHE_HOME=str(root / "cache"), QT_QPA_PLATFORMTHEME="")
        completed = subprocess.run([RUNNER, "-input", str(script), "-import", "/usr/lib/qt6/qml"],
                                   env=environment, capture_output=True, text=True, timeout=15)
        output = completed.stdout + completed.stderr
        if completed.returncode:
            raise AssertionError(output)
        results = [line.split("STATS-RESULT ", 1)[1] for line in output.splitlines()
                   if "STATS-RESULT " in line]
        if len(results) != 1:
            raise AssertionError(output)
        return json.loads(results[0])


class StatsMigrationTests(unittest.TestCase):
    def assert_card_records_identical(self, before, after):
        self.assertEqual(set(before), set(after))
        for key in before:
            with self.subTest(card=key):
                self.assertEqual(json.dumps(before[key], sort_keys=True, ensure_ascii=False),
                                 json.dumps(after[key], sort_keys=True, ensure_ascii=False))

    def test_wp0_v4_migration_preserves_every_canonical_binding_record(self):
        source = fixture("stats-v4.json")
        result = stats_eval('Stats.migrate(input, ["all"])', source)
        self.assertEqual(result["schemaVersion"], 5)
        self.assertEqual(result["runSequence"], 8)
        self.assertNotIn("profiles", result)
        expected = {k: v for k, v in source["profiles"]["lazyvim"].items()
                    if k not in ("knownTotal", "knownMastered")}
        self.assertEqual(result["decks"], {"all": expected})
        self.assert_card_records_identical(source["bindings"], result["bindings"])

    def test_high_water_ignores_foreign_max_and_preserves_legacy_boundary_records(self):
        source = fixture("stats-v4.json")
        for name, counters in source["profiles"].items():
            if name != "lazyvim":
                counters["runs"] = 1000000000
                counters["firstMasteryRun"] = 1000000000
        for key, entry in source["bindings"].items():
            if not key.startswith("lazyvim/"):
                entry["successfulRuns"] = [999999999, 1000000000]
                entry["lastSuccessfulRun"] = 1000000000
                entry["dueRun"] = 1000000000
        migrated = stats_eval('Stats.migrate(input, ["all"])', source)
        self.assertEqual(migrated["runSequence"], 8)
        self.assert_card_records_identical(source["bindings"], migrated["bindings"])
        entry = source["bindings"]["lazyvim/normal/<leader>ff"]
        entry["successfulRuns"] = [999999999, 1000000000]
        entry["lastSuccessfulRun"] = 1000000000
        entry["dueRun"] = 1000000000
        migrated = stats_eval('Stats.migrate(input, ["all"])', source)
        self.assertEqual(migrated["runSequence"], 1000000000)
        self.assert_card_records_identical(source["bindings"], migrated["bindings"])
        self.assertEqual(stats_eval('Stats.peekRunIdentity(Stats.migrate(input, ["all"]))', source), 0)

    def test_v5_roundtrip_keeps_deleted_deck_and_foreign_history(self):
        source = fixture("stats-v5.json")
        result = stats_eval('Stats.parse(JSON.stringify(Stats.migrate(input, ["all"])), ["all"])', source)
        self.assertEqual(result, source)
        self.assert_card_records_identical(source["bindings"], result["bindings"])

    def test_v2_v3_cards_are_forever_hyprland_not_all(self):
        for version in (2, 3):
            with self.subTest(version=version):
                source = fixture(f"stats-v{version}.json")
                result = stats_eval('Stats.migrate(input, ["all"])', source)
                self.assertEqual(result["decks"], {})
                self.assertEqual(result["runSequence"], 0)
                self.assertEqual(result["schemaVersion"], 5)
                self.assert_card_records_identical(
                    {"hyprland/" + key: value for key, value in source["bindings"].items()},
                    result["bindings"])

    def test_v1_history_converted_without_moving_retired_counters(self):
        result = stats_eval('Stats.migrate(input, ["all"])', fixture("stats-v1.json"))
        self.assertEqual(result["decks"], {})
        self.assertEqual(result["runSequence"], 0)
        self.assertEqual(result["bindings"], {"hyprland/64|Q|killactive|": {
            "state": "learning", "guidedCompleted": True, "dueAt": 0, "dueRun": 10,
            "intervalStep": 0, "firstTryAttempts": 3, "firstTryCorrect": 2,
            "recentFirstTry": [True, False, True], "reactions": [800, 700],
            "successfulRuns": [], "lastSuccessfulRun": 0, "lastSeenAt": 42, "lapseCount": 0}})

    def test_counter_pruning_protects_late_declared_ids_and_sorts_orphans(self):
        source = fixture("stats-v5-overcap.json")
        result = stats_eval('Stats.migrate(input, ["all", "zz-declared"])', source)
        self.assertEqual(len(result["decks"]), 48)
        self.assertEqual(set(result["decks"]), {"all", "zz-declared"} |
                         {f"orphan-{i:02d}" for i in range(46)})
        self.assertEqual(result["decks"]["zz-declared"]["runs"], 99)
        self.assert_card_records_identical(source["bindings"], result["bindings"])
        source["decks"] = dict(reversed(list(source["decks"].items())))
        reversed_result = stats_eval('Stats.migrate(input, ["zz-declared", "all"])', source)
        self.assertEqual(result, reversed_result)

    def test_complete_qml_state_algorithms(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = dict(os.environ, QT_QPA_PLATFORM="offscreen", XDG_RUNTIME_DIR=directory,
                               QT_QPA_PLATFORMTHEME="", HOME=directory,
                               XDG_STATE_HOME=directory + "/state", XDG_CACHE_HOME=directory + "/cache")
            result = subprocess.run([RUNNER, "-input", str(ROOT / "tests/qml/tst_migrations.qml"),
                                     "-import", "/usr/lib/qt6/qml"], env=environment,
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
