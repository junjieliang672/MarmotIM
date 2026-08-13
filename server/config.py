"""Environment-variable configuration for the local ASR service.

Everything is read once at import of `Config.from_env()`; there is no config file and no
CLI flag surface. The installer sets these in the LaunchAgent plist; a human debugging by
hand sets them in the shell (see README §6).
"""

from __future__ import annotations

import ipaddress
import os
from dataclasses import dataclass

# Only the two repos that `qwen3-asr-mlx` 0.2.0 can actually load. See README §2 --
# the 8-bit checkpoints fail strict `load_weights`, and `Qwen/Qwen3-ASR-0.6B` is
# `thinker.`-prefixed and matches zero tensors.
KNOWN_MODELS = (
    "mlx-community/Qwen3-ASR-1.7B-bf16",
    "mlx-community/Qwen3-ASR-0.6B-bf16",
)

DEFAULT_MODEL = KNOWN_MODELS[0]
DEFAULT_PORT = 58471

# Contract version reported by /health.
API_VERSION = "1"


class ConfigError(ValueError):
    """Raised for an unusable environment. The process must not start."""


def _env_str(name: str, default: str) -> str:
    raw = os.environ.get(name)
    if raw is None:
        return default
    raw = raw.strip()
    return raw if raw else default


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError as exc:
        raise ConfigError(f"{name}={raw!r} is not an integer") from exc


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        return float(raw)
    except ValueError as exc:
        raise ConfigError(f"{name}={raw!r} is not a number") from exc


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name, "").strip().lower()
    if not raw:
        return default
    if raw in ("1", "true", "yes", "on"):
        return True
    if raw in ("0", "false", "no", "off"):
        return False
    raise ConfigError(f"{name}={raw!r} is not a boolean")


def resolve_loopback_host(host: str) -> str:
    """Return `host` if it is a loopback address, else raise.

    The service is unauthenticated by deliberate choice (contract: "no auth token: the
    surface is loopback-bound"). Binding it anywhere reachable would publish an open
    transcription endpoint on the local network, so a non-loopback host is a hard
    startup failure rather than a warning -- there is no env var that can widen the bind.
    """
    candidate = host.strip()
    if not candidate:
        raise ConfigError("host is empty")
    if candidate == "localhost":
        # Resolves to a loopback address on any sane machine, but the literal is
        # ambiguous (v4 vs v6, /etc/hosts editable). Pin it.
        return "127.0.0.1"
    try:
        addr = ipaddress.ip_address(candidate)
    except ValueError as exc:
        raise ConfigError(
            f"host {host!r} is not an IP literal; only loopback literals are accepted"
        ) from exc
    if not addr.is_loopback:
        raise ConfigError(
            f"refusing to bind {host!r}: this service is unauthenticated and may only "
            f"bind a loopback address (127.0.0.1 or ::1)"
        )
    return str(addr)


def validate_reload_model(model_id: str) -> str:
    """Return `model_id` if `/reload` may switch to it, else raise ConfigError.

    An allowlist, and only on the *runtime* switch. The asymmetry with
    `MARMOT_ASR_MODEL` -- which is not checked -- is deliberate rather than an oversight:

    - Startup is human-driven, has no working model to destroy, and a bad id shows up in
      the log within seconds. Constraining it would only stop someone pointing the server
      at a local directory or a repo published after this file was written.
    - `/reload` is GUI-driven and *destructive*: it closes the running model before it
      tries the new one (see `ModelManager.start_load`). A settings page offering the
      three variants the plan originally named would let one click on `1.7B-8bit` -- a
      repo README §2 proves cannot load with this library -- take a working server down to
      `error`. That is the exact mistake worth a cheap 400.

    Adding a variant is a one-line edit to KNOWN_MODELS; that is the intended escape.
    """
    candidate = model_id.strip()
    if not candidate:
        raise ConfigError("model is empty")
    if candidate not in KNOWN_MODELS:
        raise ConfigError(
            f"{candidate!r} is not a supported model; qwen3-asr-mlx 0.2.0 can load only "
            + ", ".join(KNOWN_MODELS)
        )
    return candidate


@dataclass(frozen=True)
class Config:
    host: str = "127.0.0.1"
    port: int = DEFAULT_PORT
    model: str = DEFAULT_MODEL
    # None => auto-detect (decision 9).
    language: str | None = None
    # Load the weights and run warm_up() during startup. Off is for tests only.
    preload: bool = True
    # Contract error taxonomy: below `min_audio_seconds` => audio_too_short,
    # above `max_audio_seconds` => audio_too_long. The client already guards at 120 s,
    # so the server ceiling is deliberately generous.
    min_audio_seconds: float = 0.2
    max_audio_seconds: float = 300.0
    # The only sample rate the model accepts. A mismatch is `bad_audio`.
    sample_rate: int = 16000
    log_level: str = "info"

    @classmethod
    def from_env(cls, env_prefix: str = "MARMOT_ASR_") -> "Config":
        p = env_prefix
        cfg = cls(
            host=resolve_loopback_host(_env_str(f"{p}HOST", "127.0.0.1")),
            port=_env_int(f"{p}PORT", DEFAULT_PORT),
            model=_env_str(f"{p}MODEL", DEFAULT_MODEL),
            language=os.environ.get(f"{p}LANGUAGE", "").strip() or None,
            preload=_env_bool(f"{p}PRELOAD", True),
            min_audio_seconds=_env_float(f"{p}MIN_AUDIO_SECONDS", 0.2),
            max_audio_seconds=_env_float(f"{p}MAX_AUDIO_SECONDS", 300.0),
            log_level=_env_str(f"{p}LOG_LEVEL", "info").lower(),
        )
        if not 1 <= cfg.port <= 65535:
            raise ConfigError(f"{p}PORT={cfg.port} is out of range")
        if cfg.min_audio_seconds < 0:
            raise ConfigError(f"{p}MIN_AUDIO_SECONDS must be >= 0")
        if cfg.max_audio_seconds <= cfg.min_audio_seconds:
            raise ConfigError(f"{p}MAX_AUDIO_SECONDS must exceed {p}MIN_AUDIO_SECONDS")
        return cfg
