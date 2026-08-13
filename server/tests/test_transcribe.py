"""`POST /transcribe` -- the full error taxonomy and the argument mapping.

This is the table in README §7, executed. It was previously driven by an ad-hoc script
against a hand-started uvicorn; here it runs on every `pytest` invocation, with no weights.
"""

from __future__ import annotations

import base64
import math

import numpy as np
import pytest
from fastapi.testclient import TestClient

from conftest import RecordingLoader, base_config
from app import create_app

SR = 16000


def pcm(seconds: float, *, value: float = 0.1) -> str:
    n = int(round(seconds * SR))
    return base64.b64encode(np.full(n, value, dtype="<f4").tobytes()).decode()


@pytest.fixture
def client(loader):
    app = create_app(config=base_config(), loader=loader)
    with TestClient(app) as c:
        app.state.manager.join(timeout=10)
        c.loader = loader
        yield c


def test_happy_path_shape(client):
    r = client.post("/transcribe", json={"audio_base64": pcm(1.0), "sample_rate": SR})
    assert r.status_code == 200
    body = r.json()
    assert set(body) == {"text", "language", "duration", "elapsed"}
    assert body["text"] == "hello" and body["language"] == "English"
    assert body["duration"] == 1.0
    assert body["elapsed"] >= 0.0

    call = client.loader.models[0].calls[-1]
    assert call["n_samples"] == SR
    assert call["dtype"] == "float32", "the library requires float32; a cast would be silent"


def test_transcript_is_returned_verbatim(loader):
    """Decision 5: trailing-punctuation surgery is the client's job, not the server's."""
    loader.model_kwargs["text"] = "  你好，今天天气很好。  "
    app = create_app(config=base_config(), loader=loader)
    with TestClient(app) as client:
        app.state.manager.join(timeout=10)
        r = client.post("/transcribe", json={"audio_base64": pcm(1.0), "sample_rate": SR})
    assert r.json()["text"] == "  你好，今天天气很好。  "


# -- max_new_tokens -> max_tokens, the locked mapping in README §3 --------------------

@pytest.mark.parametrize("payload,expected", [
    ({}, None),                       # key absent -- what the Swift client actually sends
    ({"max_new_tokens": None}, None),  # explicit null -- must be indistinguishable
    ({"max_new_tokens": 7}, 7),        # verbatim: no clamp, no floor at 256
    ({"max_new_tokens": 900}, 900),
    ({"max_new_tokens": 0}, 0),        # nonsense, forwarded anyway (measured: returns fast)
    ({"max_new_tokens": -1}, -1),
])
def test_max_new_tokens_reaches_the_library_unclamped(client, payload, expected):
    r = client.post("/transcribe",
                    json={"audio_base64": pcm(1.0), "sample_rate": SR, **payload})
    assert r.status_code == 200
    assert client.loader.models[0].calls[-1]["max_tokens"] == expected


def test_absent_and_null_max_new_tokens_are_byte_identical(client):
    base = {"audio_base64": pcm(1.0), "sample_rate": SR}
    a = client.post("/transcribe", json=base).json()
    b = client.post("/transcribe", json={**base, "max_new_tokens": None}).json()
    a.pop("elapsed"), b.pop("elapsed")   # the only field that legitimately differs
    assert a == b


# -- language / context --------------------------------------------------------------

@pytest.mark.parametrize("sent,expect_language,expect_context", [
    ({"language": "zh", "context": " 土拨鼠 五笔 "}, "zh", "土拨鼠 五笔"),
    ({"language": "", "context": ""}, None, None),      # both mean auto / none
    ({"language": None, "context": None}, None, None),
    ({}, None, None),
])
def test_language_and_context_are_normalised(client, sent, expect_language, expect_context):
    r = client.post("/transcribe",
                    json={"audio_base64": pcm(1.0), "sample_rate": SR, **sent})
    assert r.status_code == 200
    call = client.loader.models[0].calls[-1]
    assert call["language"] == expect_language
    assert call["context"] == expect_context


def test_configured_language_is_only_a_fallback(loader):
    app = create_app(config=base_config(language="zh"), loader=loader)
    with TestClient(app) as client:
        app.state.manager.join(timeout=10)
        body = {"audio_base64": pcm(1.0), "sample_rate": SR}
        client.post("/transcribe", json=body)
        assert loader.models[0].calls[-1]["language"] == "zh"
        client.post("/transcribe", json={**body, "language": "en"})
        assert loader.models[0].calls[-1]["language"] == "en", "the request must win"


# -- the error taxonomy: five codes, nothing else -------------------------------------

@pytest.mark.parametrize("name,payload,status,code", [
    ("0.1s of audio",        {"audio_base64": pcm(0.1)},              400, "audio_too_short"),
    ("empty payload",        {"audio_base64": ""},                    400, "audio_too_short"),
    ("301s of audio",        {"audio_base64": pcm(301)},              400, "audio_too_long"),
    ("wrong sample rate",    {"audio_base64": pcm(1.0), "sample_rate": 44100},
                                                                      400, "bad_audio"),
    ("not base64",           {"audio_base64": "!!!not base64!!!"},    400, "bad_audio"),
    ("misaligned length",    {"audio_base64": base64.b64encode(b"12345").decode()},
                                                                      400, "bad_audio"),
])
def test_error_taxonomy(client, name, payload, status, code):
    r = client.post("/transcribe", json={"sample_rate": SR, **payload})
    assert r.status_code == status, f"{name}: {r.text}"
    body = r.json()
    assert set(body) == {"error", "detail"}
    assert body["error"] == code
    assert body["detail"], "every error must carry a human-readable reason"


@pytest.mark.parametrize("bad", [math.nan, math.inf, -math.inf])
def test_non_finite_pcm_is_bad_audio(client, bad):
    samples = np.full(SR, 0.1, dtype="<f4")
    samples[SR // 2] = bad
    r = client.post("/transcribe", json={
        "audio_base64": base64.b64encode(samples.tobytes()).decode(), "sample_rate": SR})
    assert r.status_code == 400 and r.json()["error"] == "bad_audio"


def test_model_not_ready_is_503(loader):
    app = create_app(config=base_config(preload=False), loader=loader)
    with TestClient(app) as client:
        r = client.post("/transcribe", json={"audio_base64": pcm(1.0), "sample_rate": SR})
    assert r.status_code == 503
    assert r.json() == {"error": "model_not_ready", "detail": "model is loading: startup"}


def test_bad_payload_beats_model_not_ready(loader):
    """Payload-first ordering: the permanent failure must win over the retryable one."""
    app = create_app(config=base_config(preload=False), loader=loader)
    with TestClient(app) as client:
        r = client.post("/transcribe",
                        json={"audio_base64": "!!!", "sample_rate": SR})
    assert r.status_code == 400 and r.json()["error"] == "bad_audio"


def test_model_raising_is_inference_failed(loader):
    loader.model_kwargs["raises"] = RuntimeError("synthetic decoder failure")
    app = create_app(config=base_config(), loader=loader)
    with TestClient(app) as client:
        app.state.manager.join(timeout=10)
        r = client.post("/transcribe", json={"audio_base64": pcm(1.0), "sample_rate": SR})
    assert r.status_code == 500
    assert r.json() == {"error": "inference_failed",
                        "detail": "RuntimeError: synthetic decoder failure"}


# -- schema violations collapse into bad_audio, never a 422 ---------------------------

@pytest.mark.parametrize("body,where", [
    ({"sample_rate": SR}, "audio_base64: Field required"),
    ({"audio_base64": pcm(1.0), "sample_rate": "not-an-int"}, "sample_rate:"),
    ({"audio_base64": 12345}, "audio_base64:"),
])
def test_schema_violations_are_bad_audio_400(client, body, where):
    r = client.post("/transcribe", json=body)
    assert r.status_code == 400, "a 422 would be a status the contract never lists"
    assert r.json()["error"] == "bad_audio"
    assert where.split(":")[0] in r.json()["detail"]


def test_non_json_body_is_bad_audio_400(client):
    r = client.post("/transcribe", content=b"{not json",
                    headers={"content-type": "application/json"})
    assert r.status_code == 400
    assert r.json()["error"] == "bad_audio"
    assert "JSON decode error" in r.json()["detail"]


def test_unknown_fields_are_ignored(client):
    r = client.post("/transcribe", json={"audio_base64": pcm(1.0), "sample_rate": SR,
                                         "future_knob": {"nested": True}})
    assert r.status_code == 200, "an older server must not break a newer client"


# -- "no temp files anywhere on the request path" (done-criterion) --------------------

def test_the_request_path_writes_no_files(client, tmp_path, monkeypatch):
    """Guards the criterion two ways: nothing appears in TMPDIR, and the module-level
    temp-file constructors are booby-trapped for the duration of the request."""
    import tempfile

    monkeypatch.setenv("TMPDIR", str(tmp_path))
    for fn in ("NamedTemporaryFile", "TemporaryFile", "mkstemp", "mkdtemp"):
        monkeypatch.setattr(tempfile, fn,
                            lambda *a, **k: pytest.fail("the request path made a temp file"))

    before = set(tmp_path.iterdir())
    r = client.post("/transcribe", json={"audio_base64": pcm(2.0), "sample_rate": SR})
    assert r.status_code == 200
    assert set(tmp_path.iterdir()) == before
