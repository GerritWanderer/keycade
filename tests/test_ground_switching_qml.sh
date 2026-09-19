#!/usr/bin/bash

# The retired cabinets are gone, but loading is still asynchronous: the bounded
# config reader calibrates the compiled LazyVim supply. Exercise repeated reads,
# extras, literal overrides, leader calibration and exclusions through the real
# overlay wiring. Never open the exclusive overlay or read personal config.

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
  printf 'ground-loading test skipped: no Wayland display\n'
  exit 0
fi

mkdir -p -- "$test_root/config" "$test_root/state" "$test_root/home/.config/nvim/lua/config"
cp -r -- "$repo_root" "$test_root/config/keycade"
rm -rf -- "$test_root/config/keycade/.git"

# Expected counts come from the unchanged shipped table and synthetic config,
# never from the source under test or the maintainer's local configuration.
expected=$(python3 - "$test_root/config/keycade" "$test_root" <<'PY'
import json, sys
from pathlib import Path
root, out = Path(sys.argv[1]), Path(sys.argv[2])
pack = json.loads((root / "assets/packs/lazyvim.json").read_text("utf-8"))
extra = "lazyvim.plugins.extras.editor.harpoon2"
assert extra in pack["extras"]
active = {entry["localId"] for entry in pack["bindings"]
          if not entry["extras"] or extra in entry["extras"]}
assert "normal/gZ" not in active
assert {"normal/<leader>ff", "normal/<C-h>", "normal/<C-j>"} <= active
active.remove("normal/<C-h>")
active.add("normal/gZ")
active.remove("normal/<C-j>")
config = out / "home/.config/nvim"
(config / "lazyvim.json").write_text(json.dumps({"extras": [extra]}), "utf-8")
(config / "lua/config/options.lua").write_text('vim.g.mapleader = ","\n', "utf-8")
(config / "lua/config/keymaps.lua").write_text('''vim.keymap.set("n", "<leader>ff", "<cmd>Files<cr>", { desc = "My file picker" })
vim.keymap.del("n", "<C-h>")
vim.keymap.set("n", "gZ", "<cmd>Custom<cr>", { desc = "My command" })
''', "utf-8")
(out / "settings.json").write_text(json.dumps({
    "schemaVersion": 3, "activeProfile": "tmux", "locale": "en",
    "feedbackSound": False, "countdownSound": False,
    "excludedBindings": ["lazyvim:normal/<C-j>", "tmux:prefix/x"],
}) + "\n", "utf-8")
(out / "stats.json").write_text(json.dumps({
    "schemaVersion": 4, "bindings": {}, "profiles": {"lazyvim": {"runs": 2}},
}) + "\n", "utf-8")
print(len(active))
PY
)
for kind in settings stats; do
  XDG_STATE_HOME="$test_root/state" "$repo_root/bin/state-store" write "$kind" \
    < "$test_root/$kind.json" > /dev/null
done

cat > "$test_root/config/shell.qml" <<EOF
import QtQuick
import Quickshell
import "keycade" as Keycade

ShellRoot {
  Keycade.Keycade { id: overlay }
  readonly property int expected: $expected
  property int phase: 0
  property int refreshes: 0
  property int failures: 0

  function check(label, actual, expectedValue) {
    if (actual !== expectedValue) {
      failures += 1
      console.error("GROUND_LOADING_WRONG " + label + " was " + actual
                    + " instead of " + expectedValue)
    }
  }

  function checkSupply(total) {
    check("only available supply", overlay.availableProfiles.join(","), "lazyvim")
    check("retired saved selection ignored", overlay.profileId, "lazyvim")
    check("total", overlay.eligibleBindings.length, total)
    check("progress total", overlay.progressCounts.total, total)
    check("home stays visible", overlay.view, "home")
    check("exclusive overlay never opened", overlay.opened, false)
    check("leader calibration", overlay.profileOptions().leader, ",")
    check("custom added", overlay.activeSource.customAdded, 1)
    check("custom changed", overlay.activeSource.customChanged, 1)
    check("custom deleted", overlay.activeSource.customDeleted, 1)
    check("custom skipped", overlay.activeSource.customSkipped, 0)
    check("foreign exclusions inert", overlay.staleExcludedCount, 0)
    for (var i = 0; i < overlay.eligibleBindings.length; i++) {
      var item = overlay.eligibleBindings[i]
      check("LazyVim namespace", item.id.indexOf("lazyvim/"), 0)
      check("text judging", item.answer.judgeMode, "text")
      if (item.localId === "normal/<leader>ff") {
        check("overridden description", overlay.actionName(item), "My file picker")
        check("resolved leader", item.answer.steps[0].text, ",")
      }
    }
  }

  Timer {
    interval: 40; running: true; repeat: true
    onTriggered: {
      if (phase === 0) {
        // This counter is a readiness sentinel from the isolated StateStore.
        if (overlay.profileCounters().runs !== 2) return
        overlay.view = "home"
        overlay.loadActiveGround()
        check("loading announced", overlay.groundLoading, true)
        phase = 1
      } else if (phase === 1) {
        // Force the reader's pending/restart path as well as ordinary loads.
        overlay.loadActiveGround()
        refreshes += 1
        if (refreshes === 8) phase = 2
      } else if (!overlay.groundLoading) {
        checkSupply(phase === 2 ? expected : expected + 1)
        if (phase === 2) {
          check("excluded row", overlay.excludedRows.length, 1)
          overlay.restoreBinding("normal/<C-j>")
          check("restore changes the denominator", overlay.progressCounts.total, expected + 1)
          check("restore empties live exclusions", overlay.excludedRows.length, 0)
          overlay.loadActiveGround()
          phase = 3
        } else {
          running = false
          done.start()
        }
      }
    }
  }
  Timer {
    id: done; interval: 1000; repeat: false
    onTriggered: {
      console.log(failures ? "GROUND_LOADING_FAILED" : "GROUND_LOADING_OK")
      Qt.quit()
    }
  }
  Timer {
    interval: 20000; running: true; repeat: false
    onTriggered: { console.error("GROUND_LOADING_FAILED: timeout"); Qt.quit() }
  }
}
EOF

output=$(
  HOME="$test_root/home" XDG_CONFIG_HOME="$test_root/home/.config" \
  XDG_STATE_HOME="$test_root/state" XDG_CACHE_HOME="$test_root/cache" \
  XDG_DATA_HOME="$test_root/data" \
  QT_QPA_PLATFORMTHEME= QT_STYLE_OVERRIDE=Fusion \
  timeout 25s quickshell --no-color --path "$test_root/config/shell.qml" 2>&1
) || { printf '%s\n' "$output" >&2; exit 1; }

if ! grep -Fq -- "GROUND_LOADING_OK" <<<"$output"; then
  grep -E "GROUND_LOADING" <<<"$output" >&2 || printf '%s\n' "$output" >&2
  exit 1
fi

python3 - "$test_root/state/omarchy/keycade/settings.json" <<'PY'
import json, sys
from pathlib import Path
settings = json.loads(Path(sys.argv[1]).read_text("utf-8"))
assert settings["excludedBindings"] == ["tmux:prefix/x"], settings
# Registry pruning falls back to the only reachable supply for this selector.
# It is a preference, not history: the foreign exclusion above stays verbatim.
assert settings["activeProfile"] == "lazyvim", settings
PY

printf 'single-supply ground-loading QML integration test passed\n'
