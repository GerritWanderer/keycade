"""Atheris target for the bounded, descriptor-relative decks.json reader.

Each input exercises BOTH raw hostile bytes (including malformed JSON/UTF-8)
and structured mutation that reaches deck/name/seed validation. No old helper
imports, swallowed programming errors, conditional targets, or user config I/O.
"""
from __future__ import annotations

import atexit
import importlib.util
import json
import os
import sys
import tempfile
from importlib.machinery import SourceFileLoader
from pathlib import Path

import atheris

ROOT = Path(__file__).resolve().parent.parent
with atheris.instrument_imports():
    loader = SourceFileLoader("fuzz_app_config_json", str(ROOT / "bin" / "app-config-json"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    APP_CONFIG = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(APP_CONFIG)

HOME = tempfile.TemporaryDirectory(prefix="keycade-lazyvim-decks-fuzz-")
atexit.register(HOME.cleanup)
HOME_PATH = Path(HOME.name)
FILES = APP_CONFIG.FILES["keycade-lazyvim"]["decks"]
DECK_PATH = HOME_PATH / FILES[0]
DECK_PATH.parent.mkdir(parents=True)
# This isolated process must never follow the caller's personal config root.
os.environ.pop("XDG_CONFIG_HOME", None)
VOCAB = APP_CONFIG.deck_vocabulary()


def assert_result(result: dict) -> None:
    assert set(result) == {"schemaVersion", "status", "reason", "decks", "rejected"}
    assert result["schemaVersion"] == 1
    assert result["status"] in ("absent", "valid", "invalid")
    assert isinstance(result["reason"], str) and len(result["reason"]) <= 128
    assert type(result["rejected"]) is int and 0 <= result["rejected"] <= 100000
    assert len(json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode("utf-8")) <= APP_CONFIG.MAX_FILE_BYTES
    assert len(result["decks"]) <= 32
    assert result["status"] == "valid" or result["decks"] == []
    seen = set()
    for deck in result["decks"]:
        assert set(deck) <= {"id", "name", "seed"}
        assert APP_CONFIG.DECK_ID.fullmatch(deck["id"])
        assert deck["id"] not in APP_CONFIG.FORBIDDEN_KEYS and deck["id"] not in seen
        seen.add(deck["id"])
        assert 0 < len(deck["name"]) <= 48 and deck["name"].strip()
        assert APP_CONFIG.deck_name(deck["name"]) == deck["name"]
        assert deck["id"] != "all" or "seed" not in deck
        for key, values in deck.get("seed", {}).items():
            cap, chars = APP_CONFIG.SEED_LIMITS[key]
            assert len(values) <= cap and len(set(values)) == len(values)
            assert all(isinstance(value, str) and 0 < len(value) <= chars
                       and value in VOCAB[key] and value not in APP_CONFIG.FORBIDDEN_KEYS
                       for value in values)


def read_bytes(data: bytes) -> None:
    DECK_PATH.write_bytes(data)
    assert_result(APP_CONFIG.read_decks(HOME_PATH, FILES))


def test_one_input(data: bytes) -> None:
    read_bytes(data[:APP_CONFIG.MAX_FILE_BYTES + 1])
    fuzz = atheris.FuzzedDataProvider(data)
    sample = data.decode("utf-8", errors="replace")[:140]
    # Always reach all three seed dimensions, even from an empty corpus. Keep
    # mutation control bytes separate from text; consuming arbitrary strings
    # first otherwise starves later seed branches in short fuzz inputs.
    decks = [{"id": "seeded", "name": "Seeded", "seed": {
        "categories": [sorted(VOCAB["categories"])[0], sample],
        "extras": [sorted(VOCAB["extras"])[0], sample],
        "contexts": [sorted(VOCAB["contexts"])[0], sample],
    }}]
    for index in range(fuzz.ConsumeIntInRange(1, 40)):
        deck = {
            "id": fuzz.PickValueInList(["deck-" + str(index), "all", "duplicate",
                                       "constructor", "__proto__", "prototype", "Bad Id",
                                       sample[:40]]),
            "name": fuzz.PickValueInList(["Deck " + str(index), "\x1b[31mRed\x1b[0m\u202e",
                                         "\x1b]title\x07Name", "名" * 60, None,
                                         sample[:100]]),
        }
        if fuzz.ConsumeBool():
            seed = {}
            for key, (cap, _chars) in APP_CONFIG.SEED_LIMITS.items():
                if fuzz.ConsumeBool():
                    seed[key] = [fuzz.PickValueInList(sorted(VOCAB[key]) + [
                        "constructor", "__proto__", "prototype", "unknown", None, 1,
                        sample])
                        for _ in range(fuzz.ConsumeIntInRange(0, cap + 4))]
            if fuzz.ConsumeBool():
                seed["__proto__"] = {"polluted": True}
            deck["seed"] = fuzz.PickValueInList([seed, seed, None, [], "invalid"])
        if fuzz.ConsumeBool():
            deck["unknown"] = sample[:80]
        decks.append(deck)
    config = {"schemaVersion": fuzz.PickValueInList([1, 1, 1, None, True, 2]), "decks": decks}
    read_bytes(json.dumps(config, ensure_ascii=True).encode("ascii"))


if __name__ == "__main__":
    # SourceFileLoader's extensionless target is outside ordinary import hooks.
    # Instrument it (and this callback) explicitly before starting coverage.
    atheris.instrument_all()
    atheris.Setup(sys.argv, test_one_input)
    atheris.Fuzz()
