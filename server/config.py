"""Configuration for the local ASR service.

Three layers, later wins: dataclass defaults <- environment <- overlay file.

The environment comes from the LaunchAgent plist and is install-time bootstrap, written
only by `scripts/install_asr.sh`. The overlay is the user's live intent from MarmotIM's
转写 settings page, applied through `POST /reconfigure`. The overlay wins because a
reinstall must not silently revert a setting someone deliberately changed.

`Config.load()` is the entry point that layers all three. `Config.from_env()` remains the
environment-only path and is what the tests and a hand-run server use.
"""

from __future__ import annotations

import ipaddress
import json
import logging
import os
from dataclasses import asdict, dataclass
from typing import Any

# Only the two repos that `qwen3-asr-mlx` 0.2.0 can actually load. See README §2 --
# the 8-bit checkpoints fail strict `load_weights`, and `Qwen/Qwen3-ASR-0.6B` is
# `thinker.`-prefixed and matches zero tensors.
KNOWN_MODELS = (
    "mlx-community/Qwen3-ASR-1.7B-bf16",
    "mlx-community/Qwen3-ASR-0.6B-bf16",
)

DEFAULT_MODEL = KNOWN_MODELS[0]
DEFAULT_PORT = 58471

# uvicorn's own levels. Anything else and it refuses to start -- which, for a value the
# settings page can write, would mean a server that cannot boot and no UI to fix it from.
KNOWN_LOG_LEVELS = frozenset({"critical", "error", "warning", "info", "debug", "trace"})

# The keys /reconfigure accepts and the overlay may carry. `preload` and `sample_rate`
# are deliberately absent: the first is a test-only switch, the second is fixed by the
# model and a mismatch is already reported as bad_audio.
OVERLAY_KEYS = (
    "host",
    "port",
    "model",
    "language",
    "min_audio_seconds",
    "max_audio_seconds",
    "log_level",
)

# Changing any of these means rebinding the socket or re-initialising logging, neither of
# which is possible in place -- the server writes the overlay and exits, and launchd's
# KeepAlive restarts it. Everything else in OVERLAY_KEYS applies live.
RESTART_KEYS = frozenset({"host", "port", "log_level"})

log = logging.getLogger("marmot.asr.config")


def overlay_path_default() -> str:
    """Where the overlay lives: the runtime dir `install_asr.sh` already owns.

    Kept beside the venv and the copied server tree rather than in the repo, so it
    survives the checkout moving and is removed by `install_asr.sh --reinstall` -- which
    is the documented way back from a configuration that cannot reach a working server.
    """
    return os.path.expanduser(
        os.environ.get(
            "MARMOT_ASR_OVERLAY",
            "~/Library/Application Support/MarmotIM/asr/config.json",
        )
    )

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

    def validate(self, env_prefix: str | None = None) -> "Config":
        """Return self if the values are usable, else raise ConfigError.

        Shared by every path that can produce a Config -- env at startup and the overlay
        written by /reconfigure -- so the settings page cannot store a configuration the
        server would have refused from the environment.

        `env_prefix` only shapes the message, never the rules: from the environment a
        human has to go and edit `MARMOT_ASR_PORT`, so that is what the error must name;
        from the overlay the same value is the JSON key `port`.
        """
        def name(field: str) -> str:
            return f"{env_prefix}{field.upper()}" if env_prefix else field

        if not 1 <= self.port <= 65535:
            raise ConfigError(f"{name('port')}={self.port} is out of range (1-65535)")
        if self.min_audio_seconds < 0:
            raise ConfigError(f"{name('min_audio_seconds')} must be >= 0")
        if self.max_audio_seconds <= self.min_audio_seconds:
            raise ConfigError(
                f"{name('max_audio_seconds')} must exceed {name('min_audio_seconds')}"
            )
        if self.log_level not in KNOWN_LOG_LEVELS:
            raise ConfigError(
                f"{name('log_level')}={self.log_level!r} is not one of "
                + ", ".join(sorted(KNOWN_LOG_LEVELS))
            )
        return self

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
        return cfg.validate(env_prefix=p)

    # ------------------------------------------------------------------ overlay

    def merged_with(self, overlay: dict[str, Any]) -> "Config":
        """Return a copy with the overlay's recognised keys applied, then validated.

        Unknown keys are ignored rather than rejected: an overlay written by a newer
        MarmotIM must not stop an older server from booting -- the server would be down
        with no UI left to fix it from, which is the one failure this whole feature
        exists to avoid.
        """
        values = asdict(self)
        for key in OVERLAY_KEYS:
            if key not in overlay:
                continue
            raw = overlay[key]
            if key == "host":
                values[key] = resolve_loopback_host(str(raw))
            elif key == "model":
                values[key] = validate_reload_model(str(raw))
            elif key == "language":
                text = str(raw).strip() if raw is not None else ""
                values[key] = text or None
            elif key == "port":
                values[key] = int(raw)
            elif key in ("min_audio_seconds", "max_audio_seconds"):
                values[key] = float(raw)
            elif key == "log_level":
                values[key] = str(raw).strip().lower()
        return Config(**values).validate()

    @classmethod
    def load(cls, path: str | None = None, env_prefix: str = "MARMOT_ASR_") -> "Config":
        """Defaults <- environment (the LaunchAgent) <- overlay file (the settings page).

        The overlay wins because it is the user's live intent, expressed in the UI, while
        the plist is install-time bootstrap that only `install_asr.sh` rewrites. Making it
        the other way round would let a reinstall silently revert settings someone had
        deliberately changed.

        A missing overlay is the normal state. A CORRUPT one is logged and ignored rather
        than fatal, for the same reason unknown keys are: refusing to boot leaves no way
        back except a terminal. `install_asr.sh --reinstall` deletes the overlay, and that
        is the documented escape.
        """
        cfg = cls.from_env(env_prefix)
        overlay_path = path or overlay_path_default()
        try:
            with open(overlay_path, "r", encoding="utf-8") as handle:
                overlay = json.load(handle)
        except FileNotFoundError:
            return cfg
        except (OSError, ValueError) as exc:
            log.warning("ignoring unreadable overlay %s: %s", overlay_path, exc)
            return cfg
        if not isinstance(overlay, dict):
            log.warning("ignoring overlay %s: expected an object", overlay_path)
            return cfg
        try:
            return cfg.merged_with(overlay)
        except ConfigError as exc:
            # Same reasoning: a bad overlay must not be able to keep the server down.
            log.warning("ignoring invalid overlay %s: %s", overlay_path, exc)
            return cfg
