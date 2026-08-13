"""POST /reconfigure, and the overlay file it writes.

The failure this endpoint must never cause: a setting that leaves the server unable to
start and the settings page unable to reach it. Most of what is asserted here is that
nothing is written until the merged config has been validated, and that a damaged or
unrecognised overlay is survivable rather than fatal.
"""

from __future__ import annotations

import json
import os
import sys
import threading
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import _write_overlay, create_app  # noqa: E402
from config import DEFAULT_MODEL, DEFAULT_PORT, KNOWN_MODELS, Config  # noqa: E402

from conftest import base_config  # noqa: E402

OTHER_MODEL = KNOWN_MODELS[1]
assert OTHER_MODEL != DEFAULT_MODEL


@pytest.fixture
def overlay(tmp_path, monkeypatch):
    """Point the overlay at a temp file for the whole test."""
    path = tmp_path / "asr" / "config.json"
    monkeypatch.setenv("MARMOT_ASR_OVERLAY", str(path))
    return path


# --------------------------------------------------------------- layering

def test_the_overlay_beats_the_environment(overlay, monkeypatch):
    """The plist is install-time bootstrap; the overlay is what the user just chose.

    The other order would let `install_asr.sh` silently revert a deliberate change.
    """
    monkeypatch.setenv("MARMOT_ASR_PORT", "51000")
    overlay.parent.mkdir(parents=True)
    overlay.write_text(json.dumps({"port": 52000}), encoding="utf-8")

    assert Config.load(str(overlay)).port == 52000


def test_without_an_overlay_the_environment_still_decides(overlay, monkeypatch):
    monkeypatch.setenv("MARMOT_ASR_PORT", "51000")
    assert Config.load(str(overlay)).port == 51000


@pytest.mark.parametrize("content", [
    "{ not json at all",
    '["a", "list", "not", "an", "object"]',
    '{"port": 70000}',          # parses, but validate() refuses it
    '{"host": "0.0.0.0"}',      # parses, but is a non-loopback bind
])
def test_a_damaged_overlay_is_ignored_rather_than_fatal(overlay, content):
    """A bad overlay must never keep the server down.

    If it did, the only way back would be a terminal -- and this whole feature exists so
    that settings changes cannot strand you there.
    """
    overlay.parent.mkdir(parents=True)
    overlay.write_text(content, encoding="utf-8")

    cfg = Config.load(str(overlay))
    assert cfg.port == DEFAULT_PORT, "it should fall back, not raise"


def test_unknown_keys_are_ignored_so_an_older_server_still_boots(overlay):
    overlay.parent.mkdir(parents=True)
    overlay.write_text(json.dumps({"port": 52000, "invented_by_a_newer_ui": True}),
                       encoding="utf-8")

    assert Config.load(str(overlay)).port == 52000


# --------------------------------------------------------------- validation

@pytest.mark.parametrize("payload", [
    {"port": 70000},
    {"port": 0},
    {"host": "0.0.0.0"},
    {"model": "mlx-community/Qwen3-ASR-1.7B-8bit"},   # README §2: cannot load
    {"max_audio_seconds": 0.05},                      # below min_audio_seconds
    {"log_level": "chatty"},
])
def test_an_unusable_payload_is_refused_and_writes_nothing(loader, overlay, payload):
    app = create_app(config=base_config(), loader=loader)
    with TestClient(app) as client:
        r = client.post("/reconfigure", json=payload)

    assert r.status_code == 400
    assert r.json()["error"] == "bad_config"
    assert not overlay.exists(), \
        "a rejected payload must not reach disk -- that is what stops a bad port bricking the next start"


def test_a_rejected_payload_leaves_the_running_config_alone(loader, overlay):
    app = create_app(config=base_config(), loader=loader)
    with TestClient(app) as client:
        before = app.state.config
        client.post("/reconfigure", json={"port": 70000})
        assert app.state.config is before


# --------------------------------------------------------------- classification

def test_a_model_change_applies_live_without_a_restart(loader, overlay):
    """The point of routing through /reconfigure rather than making everything restart."""
    app = create_app(config=base_config(), loader=loader)
    with TestClient(app) as client:
        app.state.manager.join(timeout=10)

        r = client.post("/reconfigure", json={"model": OTHER_MODEL})
        assert r.status_code == 202
        body = r.json()
        assert body["applied"] == ["model"]
        assert body["restart_required"] is False, "a model switch is seconds; a restart is not"

        app.state.manager.join(timeout=10)
        assert app.state.manager.snapshot().model == OTHER_MODEL


def test_a_port_change_asks_for_a_restart(loader, overlay, monkeypatch):
    # Do not actually take the process down inside the suite.
    fired = threading.Event()
    monkeypatch.setattr("app._schedule_restart", lambda *a, **k: fired.set())

    app = create_app(config=base_config(), loader=loader)
    with TestClient(app) as client:
        r = client.post("/reconfigure", json={"port": 52001})

    assert r.status_code == 202
    assert r.json()["restart_required"] is True
    assert fired.is_set(), "the restart has to actually be scheduled, not just reported"
    assert json.loads(overlay.read_text())["port"] == 52001


def test_posting_values_that_already_hold_changes_nothing(loader, overlay, monkeypatch):
    """Guards against thrashing: the settings page fires on every edit."""
    monkeypatch.setattr("app._schedule_restart", lambda *a, **k: pytest.fail(
        "no restart may be scheduled when nothing actually differs"))

    cfg = base_config()
    app = create_app(config=cfg, loader=loader)
    with TestClient(app) as client:
        r = client.post("/reconfigure", json={"port": cfg.port, "model": cfg.model})

    assert r.status_code == 202
    body = r.json()
    assert body["applied"] == []
    assert body["restart_required"] is False
    assert not overlay.exists(), "an unchanged config should not even be written"


# --------------------------------------------------------------- durability

def test_the_overlay_is_written_atomically_and_leaves_no_litter(tmp_path):
    target = tmp_path / "asr" / "config.json"
    _write_overlay(Config(port=52002), str(target))

    assert json.loads(target.read_text())["port"] == 52002
    leftovers = [p for p in os.listdir(target.parent) if p.startswith(".config-")]
    assert leftovers == [], f"temp files left behind: {leftovers}"


def test_a_written_overlay_round_trips_through_load(tmp_path, monkeypatch):
    target = tmp_path / "asr" / "config.json"
    _write_overlay(Config(port=52003, model=OTHER_MODEL), str(target))

    cfg = Config.load(str(target))
    assert (cfg.port, cfg.model) == (52003, OTHER_MODEL)
