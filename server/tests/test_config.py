"""`Config.from_env` -- the only configuration surface. Host handling lives in test_bind.py.

Environment parsing is exactly the kind of code that is never exercised until an installer
sets a variable slightly wrong at 2 a.m., so the failure modes matter more than the happy
path: a bad value must stop the process with a message naming the variable, never fall
back to a silent default.
"""

from __future__ import annotations

import pytest

from config import DEFAULT_MODEL, DEFAULT_PORT, Config, ConfigError, validate_reload_model, KNOWN_MODELS


def test_defaults_with_a_clean_environment(monkeypatch):
    for name in list(__import__("os").environ):
        if name.startswith("MARMOT_ASR_"):
            monkeypatch.delenv(name)
    cfg = Config.from_env()
    assert (cfg.host, cfg.port, cfg.model) == ("127.0.0.1", DEFAULT_PORT, DEFAULT_MODEL)
    assert cfg.language is None, "unset means auto-detect (decision 9), not a default language"
    assert cfg.preload is True
    assert (cfg.min_audio_seconds, cfg.max_audio_seconds) == (0.2, 300.0)
    assert cfg.sample_rate == 16000


@pytest.mark.parametrize("raw,expected", [
    ("1", True), ("true", True), ("YES", True), ("on", True),
    ("0", False), ("false", False), ("no", False), ("Off", False),
])
def test_preload_booleans(monkeypatch, raw, expected):
    monkeypatch.setenv("MARMOT_ASR_PRELOAD", raw)
    assert Config.from_env().preload is expected


@pytest.mark.parametrize("var,value", [
    ("MARMOT_ASR_PRELOAD", "maybe"),
    ("MARMOT_ASR_PORT", "not-a-number"),
    ("MARMOT_ASR_PORT", "0"),
    ("MARMOT_ASR_PORT", "70000"),
    ("MARMOT_ASR_MIN_AUDIO_SECONDS", "-1"),
    ("MARMOT_ASR_MAX_AUDIO_SECONDS", "0.1"),   # below the 0.2 s minimum
    ("MARMOT_ASR_MIN_AUDIO_SECONDS", "abc"),
])
def test_unusable_values_stop_the_process(monkeypatch, var, value):
    monkeypatch.setenv(var, value)
    with pytest.raises(ConfigError) as exc:
        Config.from_env()
    assert var in str(exc.value) or "MAX_AUDIO" in str(exc.value), \
        "the message must name the variable a human has to go and fix"


def test_language_blank_means_auto_detect(monkeypatch):
    monkeypatch.setenv("MARMOT_ASR_LANGUAGE", "   ")
    assert Config.from_env().language is None


def test_model_env_var_is_not_allowlisted(monkeypatch):
    """Deliberate asymmetry with /reload: startup has no working model to destroy, so a
    human may point it at a local directory or a repo newer than this file."""
    monkeypatch.setenv("MARMOT_ASR_MODEL", "/some/local/checkout")
    assert Config.from_env().model == "/some/local/checkout"


@pytest.mark.parametrize("model", KNOWN_MODELS)
def test_validate_reload_model_accepts_every_known_model(model):
    assert validate_reload_model(f"  {model}  ") == model


def test_known_models_are_the_two_that_actually_load():
    """Guards README §2: 8-bit fails strict load_weights and the upstream Qwen repo is
    thinker.-prefixed. If either is ever added here, that finding was overturned."""
    assert set(KNOWN_MODELS) == {
        "mlx-community/Qwen3-ASR-1.7B-bf16",
        "mlx-community/Qwen3-ASR-0.6B-bf16",
    }
    assert DEFAULT_MODEL == "mlx-community/Qwen3-ASR-1.7B-bf16"
