"""`GET /health` -- the three states, the transition, and the shape.

The state machine is the whole contract of this endpoint, so it is driven through the app
rather than by poking ModelManager: a test that only exercised the manager could not catch
`/health` forgetting a key or answering after the lifespan tore the model down.
"""

from __future__ import annotations

import httpx
import pytest
from fastapi.testclient import TestClient

from conftest import RecordingLoader, base_config, free_port, live_server, wait_until
from app import create_app
from config import API_VERSION, DEFAULT_MODEL

HEALTH_KEYS = {"status", "model", "model_loaded", "version", "detail"}


def test_health_reports_ready_after_the_model_loads(loader):
    app = create_app(config=base_config(), loader=loader)
    with TestClient(app) as client:
        app.state.manager.join(timeout=10)
        body = client.get("/health").json()

    assert set(body) == HEALTH_KEYS, "the contract's five keys, no more and no fewer"
    assert body == {"status": "ready", "model": DEFAULT_MODEL, "model_loaded": True,
                    "version": API_VERSION, "detail": None}
    assert loader.requested == [DEFAULT_MODEL], "the model loads exactly once"


def test_health_answers_loading_before_the_weights_are_up(loader):
    """The socket accepts before the model exists -- that is what `loading` is for."""
    loader.gate = __import__("threading").Event()
    app = create_app(config=base_config(), loader=loader)
    port = free_port()
    with live_server(app, port) as base:
        with httpx.Client(base_url=base, timeout=5.0) as client:
            assert wait_until(loader.started.is_set), "loader never ran"
            body = client.get("/health").json()
            assert body["status"] == "loading"
            assert body["model_loaded"] is False
            assert body["detail"] == f"loading {DEFAULT_MODEL}"

            loader.gate.set()
            assert wait_until(lambda: client.get("/health").json()["status"] == "ready")
            assert client.get("/health").json()["detail"] is None


def test_health_reports_error_with_a_reason_when_the_load_raises():
    loader = RecordingLoader(fail=True)
    app = create_app(config=base_config(), loader=loader)
    with TestClient(app) as client:
        app.state.manager.join(timeout=10)
        body = client.get("/health").json()

    assert body["status"] == "error"
    assert body["model_loaded"] is False
    # The client shows this string to a human; it must name the failure, not just its type.
    assert body["detail"] == f"RuntimeError: synthetic load failure for {DEFAULT_MODEL}"


def test_preload_false_leaves_the_model_unloaded(loader):
    """The debugging escape hatch documented in README §6: process up, no weights."""
    app = create_app(config=base_config(preload=False), loader=loader)
    with TestClient(app) as client:
        body = client.get("/health").json()

    assert body["status"] == "loading"
    assert body["detail"] == "startup"
    assert loader.requested == [], "preload=false must not touch the loader"


def test_shutdown_closes_the_model(loader):
    app = create_app(config=base_config(), loader=loader)
    with TestClient(app) as client:
        app.state.manager.join(timeout=10)
        client.get("/health")
    assert loader.models[0].closed.is_set(), "lifespan teardown must free the model"
