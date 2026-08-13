"""marmot-asr-server -- FastAPI app.

Implements the pinned contract in `.flow/plan/2026-08-12-transcribe/reference-api-contract.md`.
This service knows nothing about MarmotIM; it takes float32 PCM over loopback and returns text.

Run it by hand:  python app.py       (see README §6)
"""

from __future__ import annotations

import base64
import binascii
import json
import logging
import os
import signal
import tempfile
import threading
import time
from contextlib import asynccontextmanager
from typing import Any, Optional

import numpy as np
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict

from config import (
    API_VERSION,
    OVERLAY_KEYS,
    RESTART_KEYS,
    Config,
    ConfigError,
    overlay_path_default,
    validate_reload_model,
)
from model import HealthSnapshot, ModelNotReady, Loader, ModelManager, default_loader

log = logging.getLogger("marmot_asr")

# float32 little-endian, exactly as the contract specifies the wire format. Apple Silicon
# is little-endian so the byte order is a no-op here, but saying it makes the payload
# self-describing rather than host-dependent.
PCM_DTYPE = np.dtype("<f4")


class ApiError(Exception):
    """One of the five contract error codes. Rendered as {"error", "detail"}."""

    def __init__(self, code: str, status: int, detail: str) -> None:
        super().__init__(detail)
        self.code = code
        self.status = status
        self.detail = detail


class TranscribeRequest(BaseModel):
    # Unknown keys are ignored rather than rejected: a newer client must not be broken by
    # an older server over a contract that may grow optional fields.
    model_config = ConfigDict(extra="ignore")

    audio_base64: str
    sample_rate: int = 16000
    language: Optional[str] = None
    context: Optional[str] = None
    # Optional *and* defaulted, which is what makes an absent key and an explicit
    # `"max_new_tokens": null` mean the same thing. Swift's synthesized Codable encoder
    # uses encodeIfPresent, so the real client omits the key entirely for a nil Int?; the
    # null spelling is accepted anyway because a hand-written encode(to:) or any non-Swift
    # client may send it, and a wire format that turns on which of two equivalent
    # spellings arrives is a trap. Absent/null => library auto-cap; present => passed
    # through verbatim as `max_tokens`, no clamping and no floor at 256 (README §3).
    max_new_tokens: Optional[int] = None


class ReloadRequest(BaseModel):
    model_config = ConfigDict(extra="ignore")

    model: str


class ReconfigureRequest(BaseModel):
    """A partial settings payload. Absent keys are left alone.

    Every field is optional because the settings page sends what the user touched, not a
    full snapshot -- and a full snapshot would make an older page silently revert a
    setting a newer one added.
    """

    model_config = ConfigDict(extra="ignore")

    host: Optional[str] = None
    port: Optional[int] = None
    model: Optional[str] = None
    language: Optional[str] = None
    min_audio_seconds: Optional[float] = None
    max_audio_seconds: Optional[float] = None
    log_level: Optional[str] = None


class TranscribeResponse(BaseModel):
    text: str
    language: Optional[str]
    duration: float
    elapsed: float


def health_body(s: HealthSnapshot) -> dict[str, Any]:
    """The contract's /health shape. Shared with /reload so a client can reuse one decoder."""
    return {
        "status": s.status.value,
        "model": s.model,
        "model_loaded": s.model_loaded,
        "version": API_VERSION,
        "detail": s.detail,
    }


def decode_pcm(audio_base64: str, sample_rate: int, cfg: Config) -> np.ndarray:
    """base64 -> 1-D float32 numpy, entirely in memory. No file is ever written.

    Every failure here is `bad_audio` per the contract ("undecodable payload / wrong
    sample rate"). The sample-rate check comes first because it is the cheapest and the
    most likely client bug; the payload is not even decoded if the rate is wrong.
    """
    if sample_rate != cfg.sample_rate:
        raise ApiError(
            "bad_audio", 400,
            f"sample_rate {sample_rate} is not supported; the model requires "
            f"{cfg.sample_rate} Hz mono float32",
        )
    try:
        raw = base64.b64decode(audio_base64, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ApiError("bad_audio", 400, f"audio_base64 is not valid base64: {exc}") from exc
    if len(raw) % PCM_DTYPE.itemsize:
        raise ApiError(
            "bad_audio", 400,
            f"payload is {len(raw)} bytes, not a whole number of float32 samples "
            f"(truncated, or not raw PCM -- WAV headers are not accepted)",
        )
    # .copy() is deliberate: np.frombuffer aliases an immutable bytes object, and the
    # library casts/normalises the array on its way into the mel front end. One memcpy of
    # at most a few MB buys a writable, aligned array; it is not a temp file or a re-encode.
    samples = np.frombuffer(raw, dtype=PCM_DTYPE).copy()
    if samples.size and not np.isfinite(samples).all():
        raise ApiError(
            "bad_audio", 400,
            "PCM contains NaN or infinity; the mel front end would silently produce garbage",
        )
    return samples


def _write_overlay(cfg: Config, path: Optional[str] = None) -> None:
    """Persist the overlay atomically: temp file in the same dir, then os.replace.

    Same directory matters -- os.replace is only atomic within a filesystem, and a temp
    file in /tmp can land on a different one. A torn overlay would be read at the next
    boot, which is the moment there is no UI left to fix it from.
    """
    target = path or overlay_path_default()
    os.makedirs(os.path.dirname(target), exist_ok=True)
    payload = {k: getattr(cfg, k) for k in OVERLAY_KEYS}
    handle = tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=os.path.dirname(target),
        prefix=".config-", suffix=".tmp", delete=False,
    )
    try:
        with handle:
            json.dump(payload, handle, indent=2, ensure_ascii=False)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(handle.name, target)
    except BaseException:
        # Never leave the temp file behind on a failure; the directory is the runtime
        # root and litter there is confusing to anyone debugging an install.
        try:
            os.unlink(handle.name)
        except OSError:
            pass
        raise


def _schedule_restart(delay: float = 0.25) -> None:
    """Exit shortly, so launchd's KeepAlive restarts us with the new overlay.

    Deferred rather than immediate because the 202 has to reach the client first -- a
    client that never sees the answer cannot know a restart is coming, and would report a
    dead server instead of 重启中.

    SIGTERM rather than os._exit: uvicorn installs a handler and shuts the socket down
    cleanly, so the port is free when the replacement process binds it. A hard exit races
    the new process for the port and loses roughly half the time.
    """
    def _stop() -> None:
        time.sleep(delay)
        os.kill(os.getpid(), signal.SIGTERM)

    threading.Thread(target=_stop, name="marmot-restart", daemon=True).start()


def create_app(config: Optional[Config] = None, loader: Optional[Loader] = None) -> FastAPI:
    """Build the app. `loader` is injectable so the suite runs with no weights present."""
    cfg = config if config is not None else Config.load()
    manager = ModelManager(cfg.model, loader=loader or default_loader)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        if cfg.preload:
            # Fire and forget: startup must not block, so /health can report `loading`
            # from the first instant the socket is accepting connections.
            manager.start_load()
        else:
            log.warning("preload disabled; model will not be loaded")
        try:
            yield
        finally:
            manager.shutdown()

    app = FastAPI(
        title="marmot-asr-server",
        version=API_VERSION,
        lifespan=lifespan,
        # Nothing here is a public API; the docs routes are dead weight on a loopback service.
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )
    app.state.config = cfg
    app.state.manager = manager

    @app.exception_handler(ApiError)
    async def _api_error(request: Request, exc: ApiError) -> JSONResponse:
        return JSONResponse({"error": exc.code, "detail": exc.detail}, status_code=exc.status)

    @app.exception_handler(RequestValidationError)
    async def _validation_error(request: Request, exc: RequestValidationError) -> JSONResponse:
        """Keep the error taxonomy closed.

        FastAPI's default is a 422 whose body is a list under "detail" -- a shape the
        client cannot parse, and a status the contract never mentions. A body that is not
        JSON, is missing `audio_base64`, or has a non-integer `sample_rate` is an
        undecodable payload by any reading, so it maps onto `bad_audio` (400).

        The code is chosen per route, not globally: a malformed `/reload` body has nothing
        to do with audio, and answering `bad_audio` there would send the client looking at
        a microphone. It gets `/reload`'s own `bad_model`.
        """
        code = "bad_model" if request.url.path == "/reload" else "bad_audio"
        first = exc.errors()[0] if exc.errors() else {}
        # Keep only the named path parts: "body" is noise and a bare index (which is what
        # a whole-body JSON syntax error reports) is meaningless to the client.
        where = ".".join(p for p in first.get("loc", ()) if isinstance(p, str) and p != "body")
        return JSONResponse(
            {"error": code,
             "detail": "malformed request: "
                       + (f"{where}: " if where else "")
                       + str(first.get("msg", "invalid body"))},
            status_code=400,
        )

    @app.get("/health")
    async def health() -> dict[str, Any]:
        """Must answer < 50 ms even mid-transcription.

        `async def` on purpose: this runs on the event loop rather than the threadpool,
        so it cannot be queued behind the blocked worker that `/transcribe` occupies, and
        its only blocking operation is a microsecond-scale lock acquire in `snapshot()`
        that is never held across inference. Returns a plain dict -- no response_model,
        no pydantic round-trip.

        Measured, not assumed (README §4). With a real 0.6B-bf16 decode in flight,
        p99 is 13 ms and the median 0.8 ms -- so GIL contention from the library's
        token-by-token loop is real but small, roughly 3x the idle median. The tail is
        NOT in that loop: it sits in the first ~0.4 s, the mel/encoder pass, where single
        MLX ops hold the GIL for tens of ms. That tail scales with utterance length, and
        at the 300 s ceiling one sample in two runs reached 90 ms. For the ~5 s
        utterances this service actually receives, worst observed is 3.9 ms.
        """
        return health_body(manager.snapshot())

    @app.post("/reload", status_code=202)
    async def reload(req: ReloadRequest) -> dict[str, Any]:
        """Switch model variant without a restart. 202 + the /health body, per the contract.

        `async def`, unlike `/transcribe`: `start_load()` only spawns a thread and takes
        two microsecond-scale locks, so it belongs on the event loop. Putting it in the
        threadpool would let it queue behind an in-flight transcription -- the one moment
        a user is most likely to be clicking around in settings.

        Returns immediately, without waiting for the load; the client polls `/health`.
        The answer is deliberately not "block until ready": a 1.7B load is seconds of
        disk plus `warm_up()`, well past any sane request timeout. The body is a snapshot
        taken after the loader thread was started, so it reads `loading` in every real
        case -- but it is a snapshot, not a constant, and a loader fast enough to have
        finished already will honestly report `ready`.

        Reloading the model that is already loaded is allowed and is the documented way
        back from `error` -- rejecting it would leave a failed load with no recovery
        short of a restart.
        """
        try:
            target = validate_reload_model(req.model)
        except ConfigError as exc:
            # Not one of /transcribe's five codes: that taxonomy is closed and none of it
            # describes "unsupported model". /reload is unspecified by the contract beyond
            # its 202, so it carries its own code rather than borrowing a wrong one.
            raise ApiError("bad_model", 400, str(exc)) from exc
        log.info("reload requested: %s", target)
        manager.start_load(target)
        return health_body(manager.snapshot())

    @app.post("/reconfigure", status_code=202)
    async def reconfigure(req: ReconfigureRequest) -> dict[str, Any]:
        """Apply settings from MarmotIM: live where possible, by restart where not.

        One entry point for the settings page, because deciding *which* changes need a
        restart is server knowledge and does not belong in Swift. The client posts what
        the user changed and reads `restart_required` from the answer.

        `async def` for the same reason as /reload: it does no blocking work, and putting
        it in the threadpool would let it queue behind an in-flight transcription --
        exactly when someone is clicking around in settings.

        Order matters and is the whole safety story:

        1. validate the MERGED config first. A rejected payload writes nothing, so a bad
           port can never reach the overlay and brick the next start.
        2. write the overlay atomically (temp file + os.replace), so a crash mid-write
           cannot leave half a JSON object that the next boot refuses to parse.
        3. only then act: live changes now, restart scheduled after the response flushes.
        """
        current: Config = app.state.config
        requested = {k: v for k, v in req.model_dump().items() if v is not None}
        if not requested:
            return {"applied": [], "restart_required": False, **health_body(manager.snapshot())}

        try:
            merged = current.merged_with(requested)
        except ConfigError as exc:
            # Its own code: /transcribe's five-code taxonomy is closed and none of them
            # describes "these settings are unusable".
            raise ApiError("bad_config", 400, str(exc)) from exc

        # What actually differs, by the MERGED value -- not by what was sent. Posting the
        # port it already has must not trigger a restart.
        changed = [k for k in OVERLAY_KEYS
                   if getattr(merged, k) != getattr(current, k)]
        if not changed:
            return {"applied": [], "restart_required": False, **health_body(manager.snapshot())}

        _write_overlay(merged)
        app.state.config = merged

        needs_restart = bool(set(changed) & RESTART_KEYS)

        # Model changes stay live: start_load is seconds, a restart is ThrottleInterval
        # plus the same load. Only rebinding the socket or re-initialising logging needs
        # the process to come back.
        if "model" in changed and not needs_restart:
            log.info("reconfigure: switching model to %s", merged.model)
            manager.start_load(merged.model)

        if needs_restart:
            log.info("reconfigure: %s changed, restarting", ", ".join(sorted(set(changed) & RESTART_KEYS)))
            _schedule_restart()

        return {
            "applied": changed,
            "restart_required": needs_restart,
            **health_body(manager.snapshot()),
        }

    @app.post("/transcribe", response_model=TranscribeResponse)
    def transcribe(req: TranscribeRequest) -> TranscribeResponse:
        """Sync `def` on purpose: FastAPI runs it in the threadpool, so the blocking
        inference never occupies the event loop that `/health` answers on.

        Validation order is payload-first, readiness-second. A bad payload is permanent
        and a client that retries it will fail forever, whereas `model_not_ready` invites
        a retry -- so the permanent failure must win when both are true.
        """
        started = time.monotonic()
        samples = decode_pcm(req.audio_base64, req.sample_rate, cfg)
        duration = samples.size / float(req.sample_rate)
        if duration < cfg.min_audio_seconds:
            raise ApiError(
                "audio_too_short", 400,
                f"{duration:.3f}s of audio is below the {cfg.min_audio_seconds}s minimum",
            )
        if duration > cfg.max_audio_seconds:
            raise ApiError(
                "audio_too_long", 400,
                f"{duration:.1f}s of audio exceeds the {cfg.max_audio_seconds}s ceiling",
            )

        # "" and null both mean auto-detect (contract). MARMOT_ASR_LANGUAGE is only a
        # fallback for a request that says nothing -- and its own default is None, so the
        # out-of-the-box behaviour is the contract's auto-detect either way.
        language = (req.language or "").strip() or cfg.language
        context = (req.context or "").strip() or None

        try:
            result = manager.run_transcribe(
                samples, language=language, context=context, max_tokens=req.max_new_tokens
            )
        except ModelNotReady as exc:
            raise ApiError("model_not_ready", 503, str(exc)) from exc
        except Exception as exc:  # noqa: BLE001 -- the contract wants one code for "model raised"
            log.exception("inference failed")
            raise ApiError("inference_failed", 500, f"{type(exc).__name__}: {exc}") from exc

        # Verbatim: no strip(), no punctuation surgery. That is the client's job (decision 5).
        return TranscribeResponse(
            text=result.text,
            language=result.language,
            duration=round(duration, 3),
            elapsed=round(time.monotonic() - started, 3),
        )

    return app


app = create_app()


def main() -> None:
    import uvicorn

    cfg: Config = app.state.config
    logging.basicConfig(
        level=cfg.log_level.upper(),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    # `cfg.host` has already been through resolve_loopback_host(); there is no code path
    # that reaches uvicorn with a non-loopback bind.
    uvicorn.run(app, host=cfg.host, port=cfg.port, log_level=cfg.log_level, access_log=False)


if __name__ == "__main__":
    main()
