"""Model lifecycle: load once, stay warm, report state cheaply.

Two hard requirements shape this module.

1. `/health` must answer in < 50 ms *while a transcription is running*. So the state a
   health check reads is guarded by its own tiny lock that is never held across model
   work -- acquisitions are microseconds. The model object itself is published by plain
   assignment under that same lock; nothing else contends for it.
2. The whole suite must run with the weights absent. So `qwen3_asr_mlx` is imported
   lazily, inside the loader, and the loader is injectable.

One-transcription-at-a-time is *already* enforced by the library: `Qwen3ASR.transcribe`
takes an instance-level `threading.Lock` around the entire inference (README §1). The
server nonetheless owns an inference lock of its own, for a reason the library's lock
cannot cover: the library serialises calls on *one* instance, but a model swap closes a
*displaced* instance, and `close()` does not take that lock. Without our own guard a
`/reload` landing mid-transcription would free the encoder out from under a running
inference. So `run_transcribe()` holds `_inference_lock`, and every teardown path
acquires it before calling `close()`.

Neither lock is ever touched by `/health`.
"""

from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass
from enum import Enum
from typing import Any, Callable, Optional

log = logging.getLogger("marmot_asr.model")

Loader = Callable[[str], Any]

# How long a teardown waits for an in-flight inference before giving up on freeing the
# displaced model. The two callers get different numbers, which the single 60 s constant
# that used to live here got wrong in both directions.
#
# The old comment justified 60 s with "a 300 s utterance is the server's own ceiling" --
# conflating the audio's duration with the time it takes to decode. Measured: a 286.6 s
# utterance on 1.7B-bf16 takes **55.8 s** of server-side decode. So a single max-length
# request came within ~4 s of the timeout, and a second one queued behind it would sail
# past it -- leaking a ~3.5 GB model while the replacement loads on top of it, which is
# the double residency the close-first design exists to prevent.
#
# The swap path runs on a daemon loader thread, so waiting there cannot keep the process
# alive; it may as well wait far longer than any decode. Shutdown runs on the lifespan
# thread and must stay bounded, because a wedged inference must not make the process
# un-exitable -- that is where dropping the reference (and reclaiming on exit) is right.
_SWAP_CLOSE_WAIT_SECONDS = 600.0
_SHUTDOWN_CLOSE_WAIT_SECONDS = 60.0


class Status(str, Enum):
    LOADING = "loading"
    READY = "ready"
    ERROR = "error"


class ModelNotReady(RuntimeError):
    """The model is loading, swapping, or failed. Maps to 503 model_not_ready."""


@dataclass(frozen=True)
class HealthSnapshot:
    status: Status
    model: str
    model_loaded: bool
    detail: Optional[str]


def default_loader(model_id: str) -> Any:
    """Load real weights. Imported here so the module stays importable without mlx."""
    from qwen3_asr_mlx import Qwen3ASR  # noqa: PLC0415 -- deliberately lazy

    started = time.monotonic()
    model = Qwen3ASR.from_pretrained(model_id)
    log.info("loaded %s in %.1fs", model_id, time.monotonic() - started)
    # Pre-compiles the MLX graph on 0.5 s of silence so the first real request does not
    # pay for it. This is what "warm" means here.
    model.warm_up()
    log.info("warm_up complete for %s (%.1fs total)", model_id, time.monotonic() - started)
    return model


class ModelManager:
    """Owns the single model instance and its load state."""

    def __init__(self, model_id: str, loader: Loader = default_loader) -> None:
        self._loader = loader
        # Guards every field below. Held only for assignments and reads -- never across
        # a load, never across an inference.
        self._lock = threading.Lock()
        # Held for the whole of an inference, and by any path that closes a model.
        # Lock order is always _inference_lock -> _lock; nothing takes them the other way.
        self._inference_lock = threading.Lock()
        self._status = Status.LOADING
        self._detail: Optional[str] = "startup"
        self._model: Any = None
        self._model_id = model_id
        # Monotonic token identifying the current load intent. A loader thread whose
        # generation is stale (because a /reload superseded it) discards its result
        # instead of publishing a model nobody asked for.
        self._generation = 0
        self._thread: Optional[threading.Thread] = None

    # -- state, read by /health -------------------------------------------------

    def snapshot(self) -> HealthSnapshot:
        with self._lock:
            return HealthSnapshot(
                status=self._status,
                model=self._model_id,
                model_loaded=self._model is not None,
                detail=self._detail,
            )

    def require_ready(self) -> Any:
        """Return the live model, or raise ModelNotReady. Never blocks on a load."""
        with self._lock:
            if self._status is not Status.READY or self._model is None:
                # Always lead with the state: the raw detail alone ("startup") tells a
                # human reading a client log nothing.
                why = f"model is {self._status.value}"
                raise ModelNotReady(f"{why}: {self._detail}" if self._detail else why)
            return self._model

    # -- inference --------------------------------------------------------------

    def run_transcribe(
        self,
        samples: Any,
        *,
        language: Optional[str] = None,
        context: Optional[str] = None,
        max_tokens: Optional[int] = None,
    ) -> Any:
        """Blocking. Run one transcription; raise ModelNotReady if there is no model.

        Holding `_inference_lock` for the whole call is what makes a `/reload` landing
        mid-inference safe (see the module docstring). A second concurrent request
        *waits* here rather than being rejected: the contract has no `busy` code, and the
        client's 15 s transcribe timeout is the backstop.

        `max_tokens=None` is the normal path -- the library then computes
        `max(256, int(duration * 50))` for itself. Anything else is the caller's number,
        passed through untouched.
        """
        with self._inference_lock:
            model = self.require_ready()
            return model.transcribe(
                samples, language=language, context=context, max_tokens=max_tokens
            )

    # -- lifecycle --------------------------------------------------------------

    def start_load(self, model_id: Optional[str] = None) -> int:
        """Begin loading in a background thread. Returns the load generation.

        Safe to call while a load is in flight: the older thread is orphaned and its
        result dropped.

        The displaced model is closed **before** the replacement is loaded, not after.
        That is a deliberate memory trade and it has a real cost: a swap whose load fails
        leaves the process with no model at all, `/health` reporting `error`, and the only
        way back a further `/reload` or a restart. The alternative -- hold the old model
        until the new one is up -- would make a failed swap harmless but would put both
        variants resident at once (1.7B-bf16 + 0.6B-bf16 is ~5.3 GB of unified memory on a
        machine that is also running an IME and everything else). A visible, retryable
        `error` state is the better failure than an allocation storm during what is meant
        to be a routine variant switch. (An earlier version of this docstring claimed the
        close happened after the replacement was up; `_load` has always done it first.)
        """
        with self._lock:
            if model_id is not None:
                self._model_id = model_id
            target = self._model_id
            self._generation += 1
            generation = self._generation
            self._status = Status.LOADING
            self._detail = f"loading {target}"
            previous, self._model = self._model, None
        thread = threading.Thread(
            target=self._load, args=(target, generation, previous),
            name=f"model-load-{generation}", daemon=True,
        )
        with self._lock:
            self._thread = thread
        thread.start()
        return generation

    def _load(self, model_id: str, generation: int, previous: Any) -> None:
        self._close_when_idle(previous, _SWAP_CLOSE_WAIT_SECONDS)
        try:
            model = self._loader(model_id)
        except BaseException as exc:  # noqa: BLE001 -- the state machine must record any failure
            log.exception("failed to load %s", model_id)
            with self._lock:
                if generation != self._generation:
                    return
                self._status = Status.ERROR
                self._detail = f"{type(exc).__name__}: {exc}"
            return
        with self._lock:
            if generation != self._generation:
                # A newer load superseded us while we were working.
                stale = model
            else:
                self._model = model
                self._status = Status.READY
                self._detail = None
                stale = None
        _close_quietly(stale)

    def shutdown(self) -> None:
        with self._lock:
            self._generation += 1  # orphan any in-flight loader
            model, self._model = self._model, None
            self._status = Status.LOADING
            self._detail = "shutting down"
        self._close_when_idle(model, _SHUTDOWN_CLOSE_WAIT_SECONDS)

    def _close_when_idle(self, model: Any, timeout: float) -> None:
        """Free a displaced model, but never while an inference is still using it.

        The wait is bounded (see the constants above for why the two callers pass
        different bounds). If it expires we simply drop the reference -- the memory is
        reclaimed when the inference releases it, or by process exit, which is strictly
        safer than freeing an encoder out from under a running decode.
        """
        if model is None:
            return
        if not self._inference_lock.acquire(timeout=timeout):
            log.warning("inference still in flight after %.0fs; leaking a displaced model "
                        "rather than freeing it under a running decode", timeout)
            return
        try:
            _close_quietly(model)
        finally:
            self._inference_lock.release()

    def join(self, timeout: Optional[float] = None) -> None:
        """Wait for the current loader thread. For tests and clean shutdown only."""
        with self._lock:
            thread = self._thread
        if thread is not None:
            thread.join(timeout)


def _close_quietly(model: Any) -> None:
    if model is None:
        return
    try:
        model.close()
    except Exception:  # noqa: BLE001 -- teardown must never mask the real outcome
        log.warning("model.close() raised during teardown", exc_info=True)
