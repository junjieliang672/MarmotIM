"""`POST /reload` -- the variant switch, and the one place this server can use-after-free.

`ModelManager` frees the displaced model, and `Qwen3ASR.close()` takes no lock of the
library's own (README §1). So the interesting test here is not "does the model id change";
it is "can a reload arriving mid-transcription free the encoder underneath it".
"""

from __future__ import annotations

import threading

import httpx
import pytest
from fastapi.testclient import TestClient

from conftest import RecordingLoader, base_config, free_port, live_server, wait_until
from app import create_app
from config import DEFAULT_MODEL, KNOWN_MODELS

OTHER_MODEL = "mlx-community/Qwen3-ASR-0.6B-bf16"
assert OTHER_MODEL != DEFAULT_MODEL and OTHER_MODEL in KNOWN_MODELS


def test_reload_switches_variant_and_frees_the_old_model(loader):
    app = create_app(config=base_config(), loader=loader)
    with TestClient(app) as client:
        app.state.manager.join(timeout=10)
        first = loader.models[0]

        r = client.post("/reload", json={"model": OTHER_MODEL})
        assert r.status_code == 202, "the contract pins 202, not 200"
        assert set(r.json()) == {"status", "model", "model_loaded", "version", "detail"}, \
            "/reload answers in the /health shape so the client reuses one decoder"
        assert r.json()["model"] == OTHER_MODEL

        app.state.manager.join(timeout=10)
        health = client.get("/health").json()

    assert health == {"status": "ready", "model": OTHER_MODEL, "model_loaded": True,
                      "version": "1", "detail": None}
    assert loader.requested == [DEFAULT_MODEL, OTHER_MODEL]
    assert first.closed.is_set(), "the displaced model must be freed, not leaked"


def test_reload_body_is_loading_while_the_new_model_comes_up(loader):
    """The 202 is a promise the client polls on, not a completed switch."""
    loader.gate = threading.Event()
    loader.gate.set()                       # let the startup load through
    app = create_app(config=base_config(), loader=loader)
    with TestClient(app) as client:
        app.state.manager.join(timeout=10)
        loader.gate.clear()                 # ...and stall the reload

        body = client.post("/reload", json={"model": OTHER_MODEL}).json()
        assert body["status"] == "loading"
        assert body["model_loaded"] is False
        assert body["detail"] == f"loading {OTHER_MODEL}"
        # /health agrees with the 202 body -- a client that polls sees the same thing.
        assert client.get("/health").json()["status"] == "loading"

        loader.gate.set()
        app.state.manager.join(timeout=10)
        assert client.get("/health").json()["status"] == "ready"


def test_reloading_the_same_model_is_allowed(loader):
    """The documented way back from `error`; rejecting it would strand a failed load."""
    app = create_app(config=base_config(), loader=loader)
    with TestClient(app) as client:
        app.state.manager.join(timeout=10)
        assert client.post("/reload", json={"model": DEFAULT_MODEL}).status_code == 202
        app.state.manager.join(timeout=10)
        assert client.get("/health").json()["status"] == "ready"
    assert loader.requested == [DEFAULT_MODEL, DEFAULT_MODEL]


@pytest.mark.parametrize("model", [
    "mlx-community/Qwen3-ASR-1.7B-8bit",   # the trap: named by the plan, cannot load (§2)
    "Qwen/Qwen3-ASR-0.6B",                 # thinker.-prefixed, matches zero tensors
    "not-a-repo",
    "",
    "   ",
])
def test_unsupported_model_is_rejected_without_touching_the_live_one(loader, model):
    app = create_app(config=base_config(), loader=loader)
    with TestClient(app) as client:
        app.state.manager.join(timeout=10)
        r = client.post("/reload", json={"model": model})
        assert r.status_code == 400
        assert r.json()["error"] == "bad_model", \
            "not one of /transcribe's five codes -- none of them describes this"
        # The working model must survive a bad request.
        assert client.get("/health").json() == {
            "status": "ready", "model": DEFAULT_MODEL, "model_loaded": True,
            "version": "1", "detail": None}
    assert loader.requested == [DEFAULT_MODEL], "a rejected reload must not reload"


@pytest.mark.parametrize("body", [{}, {"model": 5}, {"mdoel": OTHER_MODEL}])
def test_malformed_reload_body_is_bad_model_not_bad_audio(loader, body):
    """A schema error on /reload has nothing to do with audio; saying `bad_audio` would
    send the client looking at the microphone."""
    app = create_app(config=base_config(), loader=loader)
    with TestClient(app) as client:
        app.state.manager.join(timeout=10)
        r = client.post("/reload", json=body)
    assert r.status_code == 400
    assert r.json()["error"] == "bad_model"


def test_a_failed_reload_leaves_error_and_no_model(loader):
    """The cost of closing the displaced model first, asserted rather than assumed.

    A failed swap is *not* harmless: the process ends up with nothing loaded. That is the
    documented trade in `ModelManager.start_load` (memory over swap-atomicity), and the
    recovery is another /reload -- so this test also proves the way back out.
    """
    app = create_app(config=base_config(), loader=loader)
    with TestClient(app) as client:
        app.state.manager.join(timeout=10)
        loader.fail = True
        client.post("/reload", json={"model": OTHER_MODEL})
        app.state.manager.join(timeout=10)

        health = client.get("/health").json()
        assert health["status"] == "error"
        assert health["model_loaded"] is False
        assert health["model"] == OTHER_MODEL
        assert "synthetic load failure" in health["detail"]
        assert loader.models[0].closed.is_set(), "the old model was freed before the attempt"

        # A well-formed request now has nothing to run against.
        import base64

        import numpy as np
        good = base64.b64encode(np.full(16000, 0.1, dtype="<f4").tobytes()).decode()
        r = client.post("/transcribe", json={"audio_base64": good, "sample_rate": 16000})
        assert r.status_code == 503
        assert r.json()["error"] == "model_not_ready"
        assert "model is error" in r.json()["detail"]

        # ...and the way back.
        loader.fail = False
        client.post("/reload", json={"model": DEFAULT_MODEL})
        app.state.manager.join(timeout=10)
        assert client.get("/health").json()["status"] == "ready"


def test_a_superseded_reload_does_not_publish_its_model(loader):
    """Two reloads in flight: the loser must close its result, not overwrite the winner."""
    loader.gate = threading.Event()
    loader.gate.set()
    app = create_app(config=base_config(), loader=loader)
    with TestClient(app) as client:
        app.state.manager.join(timeout=10)
        loader.gate.clear()

        client.post("/reload", json={"model": OTHER_MODEL})
        assert wait_until(lambda: loader.requested == [DEFAULT_MODEL, OTHER_MODEL])
        client.post("/reload", json={"model": DEFAULT_MODEL})
        assert wait_until(lambda: len(loader.requested) == 3)

        loader.gate.set()
        assert wait_until(lambda: client.get("/health").json()["status"] == "ready")
        health = client.get("/health").json()

    assert health["model"] == DEFAULT_MODEL, "the last reload wins"
    superseded = loader.model_for(OTHER_MODEL)
    assert superseded.closed.is_set(), "the stale model must be closed, not leaked"


def test_reload_never_closes_a_model_that_is_mid_transcription():
    """The use-after-free guard, over a real socket.

    Needs genuine concurrency -- a transcribe occupying a threadpool worker while /reload
    runs on the event loop -- so this one uses uvicorn rather than an ASGI transport.
    """
    import base64

    import numpy as np

    release = threading.Event()
    loader = RecordingLoader(release=release)
    port = free_port()
    app = create_app(config=base_config(port=port), loader=loader)
    audio = base64.b64encode(np.full(16000, 0.1, dtype="<f4").tobytes()).decode()
    result = {}

    with live_server(app, port) as base:
        assert wait_until(lambda: len(loader.models) == 1)
        original = loader.models[0]

        def run():
            with httpx.Client(base_url=base, timeout=30.0) as c:
                r = c.post("/transcribe", json={"audio_base64": audio, "sample_rate": 16000})
                result["status"] = r.status_code
                result["body"] = r.json()

        worker = threading.Thread(target=run, daemon=True)
        worker.start()
        assert original.entered.wait(timeout=10.0), "transcribe never reached the model"

        with httpx.Client(base_url=base, timeout=10.0) as c:
            r = c.post("/reload", json={"model": OTHER_MODEL})
            assert r.status_code == 202

            # The load thread is now blocked in _close_when_idle waiting on the inference
            # lock. Give it every chance to get it wrong.
            assert not wait_until(original.closed.is_set, timeout=0.75), \
                "the displaced model was closed while a transcription was still inside it"
            assert original.in_flight.is_set()
            # And /health must still answer while all of that is pending.
            assert c.get("/health").json()["status"] == "loading"

            release.set()
            worker.join(timeout=10.0)
            assert wait_until(original.closed.is_set), "the model was never freed"
            assert wait_until(lambda: c.get("/health").json()["status"] == "ready")

    assert result["status"] == 200, result
    assert result["body"]["text"] == "hello", "the in-flight request still completed"
    assert original.close_hit_in_flight is False
    assert original.max_concurrent == 1
