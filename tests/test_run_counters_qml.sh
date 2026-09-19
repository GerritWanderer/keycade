#!/usr/bin/bash

# The single LazyVim supply must still adopt saved run counters on asynchronous
# load, reset them for a fresh run, and save an interrupted run exactly. Retired
# history is retained but contributes nothing to the displayed totals. Drive
# the real store/source wiring without ever opening the exclusive overlay.

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d)

cleanup() {
  if [[ $test_root == /tmp/* && -d $test_root ]]; then
    rm -rf -- "$test_root"
  fi
}
trap cleanup EXIT

if [[ -z ${WAYLAND_DISPLAY:-} ]]; then
  printf 'run-counters test skipped: no Wayland display\n'
  exit 0
fi

mkdir -p -- "$test_root/config" "$test_root/state" "$test_root/home"
cp -r -- "$repo_root" "$test_root/config/keycade"
rm -rf -- "$test_root/config/keycade/.git"

# Empty, isolated HOME means the core table: no local extras or overrides.
expected=$(python3 - "$test_root/config/keycade" "$test_root" <<'PY'
import json, sys
from pathlib import Path
root, out = Path(sys.argv[1]), Path(sys.argv[2])
pack = json.loads((root / "assets/packs/lazyvim.json").read_text("utf-8"))
ids = ["lazyvim/" + entry["localId"] for entry in pack["bindings"] if not entry["extras"]]

(out / "session.json").write_text(json.dumps({
    "schemaVersion": 1, "profileId": "lazyvim", "runId": 3, "offset": 5,
    "cards": [{"bindingId": binding, "tier": "learning", "queue": "weak",
               "remedial": False} for binding in ids[:6]],
    "correct": 5, "attempts": 7, "newLearned": 3, "masteredGained": 2,
    "runReviewTarget": 4, "runNewTarget": 6,
    "pendingReinforcements": ids[:2], "reactions": [900, 1200],
    "correctionRequired": True,
}) + "\n", "utf-8")

# Stats promotes learning entries with sufficient evidence, so these shapes
# differ in the evidence rather than just in their state field.
def mastered():
    return {"state": "mastered", "guidedCompleted": True,
            "dueAt": 4102444800000, "dueRun": 0, "intervalStep": 3,
            "firstTryAttempts": 3, "firstTryCorrect": 3,
            "recentFirstTry": [True, True], "reactions": [800],
            "successfulRuns": [1, 2], "lastSuccessfulRun": 2,
            "lastSeenAt": 1, "lapseCount": 0}

def due():
    return {"state": "learning", "guidedCompleted": True, "dueAt": 1, "dueRun": 0,
            "intervalStep": 1, "firstTryAttempts": 2, "firstTryCorrect": 1,
            "recentFirstTry": [False, True], "reactions": [900],
            "successfulRuns": [2], "lastSuccessfulRun": 2,
            "lastSeenAt": 1, "lapseCount": 1}

bindings = {binding: mastered() for binding in ids[:7]}
bindings.update({binding: due() for binding in ids[7:11]})
bindings["tmux/prefix/x"] = mastered()
(out / "stats.json").write_text(json.dumps({
    "schemaVersion": 4, "bindings": bindings,
    "profiles": {
        "lazyvim": {"runs": 2, "totalTrainingMs": 60000},
        "tmux": {"runs": 9, "coverageCursor": 5, "totalTrainingMs": 90000,
                 "firstMasteryAt": 0, "firstMasteryRun": 0,
                 "firstMasteryCelebrated": False, "knownTotal": 86, "knownMastered": 1},
    },
}) + "\n", "utf-8")
(out / "settings.json").write_text(json.dumps({
    "schemaVersion": 3, "activeProfile": "tmux", "locale": "en",
    "feedbackSound": False, "countdownSound": False,
}) + "\n", "utf-8")
print(len(ids))
PY
)
for kind in session stats settings; do
  XDG_STATE_HOME="$test_root/state" "$repo_root/bin/state-store" write "$kind" \
    < "$test_root/$kind.json" > /dev/null
done

cat > "$test_root/config/shell.qml" <<EOF
import QtQuick
import Quickshell
import "keycade" as Keycade

ShellRoot {
  Keycade.Keycade { id: overlay }
  readonly property int expectedTotal: $expected
  property int phase: 0
  property int failures: 0

  function check(label, actual, expected) {
    if (actual !== expected) {
      failures += 1
      console.error("RUN_COUNTERS_WRONG " + label + " was " + actual
                    + " instead of " + expected)
    }
  }

  function checkSaved(round, runNumber, identity) {
    check(round + " internal identity", overlay.activeRunId, identity)
    check(round + " resumeAvailable", overlay.resumeAvailable, true)
    check(round + " canResume", overlay.hasResumableSession(), true)
    check(round + " runNumber", overlay.runNumber, runNumber)
    check(round + " progress", overlay.completedCardCount(), 5)
    check(round + " runReviewTarget", overlay.runReviewTarget, 4)
    check(round + " runNewTarget", overlay.runNewTarget, 6)
    check(round + " reinforcements", overlay.pendingReinforcementCount(), 2)
    check(round + " accuracy", overlay.accuracyPercent(), 71)
    check(round + " newLearned", overlay.newLearned, 3)
    check(round + " masteredGained", overlay.masteredGained, 2)
    check(round + " mastered", overlay.progressCounts.mastered, 7)
    check(round + " due", overlay.progressCounts.due, 4)
    check(round + " total", overlay.progressCounts.total, expectedTotal)
    check(round + " own cabinet", overlay.groundProgressLabel("lazyvim"), "7/" + expectedTotal)
    check(round + " retired cabinet hidden", overlay.groundProgressLabel("tmux"), "—")
    check(round + " only LazyVim", Object.keys(overlay.groundProgress).join(","), "lazyvim")
    check(round + " exclusive overlay never opened", overlay.opened, false)
  }

  Timer {
    interval: 100; running: true; repeat: true
    onTriggered: {
      if (phase === 0) {
        if (overlay.profileCounters().runs !== 2) return
        check("retired selection ignored", overlay.profileId, "lazyvim")
        overlay.view = "home"
        overlay.loadActiveGround()
        phase = 1
        return
      }
      if (overlay.groundLoading) return
      if (phase === 1) {
        checkSaved("initial", 3, 3)
        // Deliberately stale run-local values must be replaced by the saved
        // run on the next load, not leak into the home-screen header.
        overlay.newLearned = 9
        overlay.masteredGained = 8
        overlay.correct = 20
        overlay.attempts = 24
        overlay.runNumber = 7
        overlay.runReviewTarget = 11
        overlay.runNewTarget = 13
        overlay.runOffset = 17
        overlay.loadActiveGround()
        check("home survives refresh", overlay.view, "home")
        check("loading announced", overlay.groundLoading, true)
        check("cabinet keeps its number", overlay.groundProgressLabel("lazyvim"), "7/" + expectedTotal)
        phase = 2
      } else if (phase === 2) {
        checkSaved("reloaded", 3, 3)
        // Finishing consumes the saved run and advances the reactive run id.
        // Adopting home state afterwards must clear every run-local tally.
        overlay.finishRun(false)
        overlay.view = "home"
        overlay.adoptRunState()
        check("fresh resumeAvailable", overlay.resumeAvailable, false)
        check("fresh canResume", overlay.hasResumableSession(), false)
        check("fresh activeRunId", overlay.activeRunId, 4)
        check("fresh runNumber", overlay.runNumber, 4)
        check("fresh progress", overlay.completedCardCount(), 0)
        check("fresh review target", overlay.runReviewTarget, 0)
        check("fresh new target", overlay.runNewTarget, 0)
        check("fresh reinforcements", overlay.pendingReinforcementCount(), 0)
        check("fresh accuracy", overlay.accuracyPercent(), 0)
        check("fresh newLearned", overlay.newLearned, 0)
        check("fresh masteredGained", overlay.masteredGained, 0)
        check("fresh reactions", overlay.reactions.length, 0)
        check("fresh results", Object.keys(overlay.runResults).length, 0)
        // Abandon one newly reserved session without completing it, then
        // restart: visible run 4 must use identity 5, never reuse identity 4.
        check("new identity", overlay.allocateSessionIdentity(), 4)
        check("abandoned restart identity", overlay.allocateSessionIdentity(), 5)
        check("abandon leaves display counters alone", overlay.profileCounters().runs, 3)
        check("display independent of identity", overlay.runNumber, 4)
        // Simulate the interrupted run without activating InputGuard.
        // leaveRun must retain the exact remaining cards, score and correction.
        overlay.deck = overlay.eligibleBindings.slice(0, 6).map(function(binding) {
          return { binding: binding, tier: "learning", queue: "weak", remedial: false }
        })
        overlay.runOffset = 5
        overlay.correct = 5
        overlay.attempts = 7
        overlay.newLearned = 3
        overlay.masteredGained = 2
        overlay.runReviewTarget = 4
        overlay.runNewTarget = 6
        overlay.reactions = [900, 1200]
        overlay.setReinforcementPending(overlay.deck[0].binding.id, true)
        overlay.setReinforcementPending(overlay.deck[1].binding.id, true)
        overlay.correctionRequired = true
        overlay.activeSegmentStartedAt = Date.now() - 1000
        overlay.view = "playing"
        overlay.leaveRun()
        check("leave returns home", overlay.view, "home")
        check("study time recorded", overlay.profileCounters().totalTrainingMs >= 61000, true)
        overlay.loadActiveGround()
        phase = 3
      } else {
        checkSaved("interrupted", 4, 5)
        overlay.adoptRunState()
        checkSaved("resumed identity unchanged", 4, 5)
        running = false
        done.start()
      }
    }
  }
  Timer {
    id: done; interval: 1500; repeat: false
    onTriggered: {
      console.log(failures ? "RUN_COUNTERS_FAILED" : "RUN_COUNTERS_OK")
      Qt.quit()
    }
  }
  Timer {
    interval: 25000; running: true; repeat: false
    onTriggered: { console.error("RUN_COUNTERS_FAILED: timeout"); Qt.quit() }
  }
}
EOF

output=$(
  HOME="$test_root/home" XDG_CONFIG_HOME="$test_root/home/.config" \
  XDG_STATE_HOME="$test_root/state" XDG_CACHE_HOME="$test_root/cache" \
  XDG_DATA_HOME="$test_root/data" \
  QT_QPA_PLATFORMTHEME= QT_STYLE_OVERRIDE=Fusion \
  timeout 30s quickshell --no-color --path "$test_root/config/shell.qml" 2>&1
) || { printf '%s\n' "$output" >&2; exit 1; }

if ! grep -Fq -- "RUN_COUNTERS_OK" <<<"$output"; then
  grep -E "RUN_COUNTERS" <<<"$output" >&2 || printf '%s\n' "$output" >&2
  exit 1
fi

python3 - "$test_root" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
state = root / "state/omarchy/keycade"
session = json.loads((state / "session.json").read_text("utf-8"))
original = json.loads((root / "session.json").read_text("utf-8"))
assert session["schemaVersion"] == 2 and session["deckId"] == "all" and session["runId"] == 5, session
assert session["sessionSize"] == 11 and session["runNumber"] == 4, session
for key in ("cards", "offset", "correct", "attempts", "newLearned", "masteredGained",
            "runReviewTarget", "runNewTarget", "pendingReinforcements", "reactions",
            "correctionRequired"):
    assert session[key] == original[key], (key, session)
stats = json.loads((state / "stats.json").read_text("utf-8"))
previous = json.loads((root / "stats.json").read_text("utf-8"))
assert stats["schemaVersion"] == 5 and stats["decks"]["all"]["runs"] == 3, stats
assert stats["runSequence"] == 5, stats
assert "profiles" not in stats and "tmux" not in stats["decks"], stats
assert "knownTotal" not in stats["decks"]["all"], stats
for binding, entry in previous["bindings"].items():
    assert stats["bindings"][binding] == entry, (binding, stats["bindings"][binding])
# Counting the corpus may materialize fresh unseen entries, never progress.
for binding in stats["bindings"].keys() - previous["bindings"].keys():
    entry = stats["bindings"][binding]
    assert binding.startswith("lazyvim/") and entry["state"] == "unseen", (binding, entry)
    assert entry["firstTryAttempts"] == 0 and entry["successfulRuns"] == [], (binding, entry)
PY

printf 'run-counters QML integration test passed\n'
