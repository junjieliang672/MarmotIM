"""`/health` under load, and one-transcription-at-a-time.

The structural half of the milestone-4 measurement, ported from the ad-hoc harness that
produced README §4's numbers. What it cannot do without weights is measure MLX's real GIL
behaviour -- a `time.sleep` fake *releases* the GIL, where a real encoder pass holds it for
tens of milliseconds. So the threshold here is deliberately not a performance claim: it
asserts the *architecture* (`/health` on the event loop, `/transcribe` in the threadpool,
serialised on the inference lock), which is the part that can silently regress in an edit.
The real numbers live in README §4 and were taken against real weights.
"""

from __future__ import annotations

import base64
import statistics
import threading
import time

import httpx
import numpy as np

from conftest import RecordingLoader, base_config, free_port, live_server, wait_until
from app import create_app

AUDIO = base64.b64encode(np.full(16000, 0.1, dtype="<f4").tobytes()).decode()
PAYLOAD = {"audio_base64": AUDIO, "sample_rate": 16000}


def poll_health(client, stop: threading.Event, gap: float = 0.005) -> list[float]:
    """One keep-alive connection, so TCP setup is not inside the measured number."""
    latencies = []
    while not stop.is_set():
        t0 = time.perf_counter()
        r = client.get("/health")
        latencies.append((time.perf_counter() - t0) * 1000)
        assert r.status_code == 200
        time.sleep(gap)
    return latencies


def test_health_is_not_queued_behind_an_in_flight_transcribe():
    loader = RecordingLoader(delay=1.5)
    port = free_port()
    app = create_app(config=base_config(port=port), loader=loader)

    with live_server(app, port) as base:
        assert wait_until(lambda: len(loader.models) == 1)
        model = loader.models[0]
        with httpx.Client(base_url=base, timeout=30.0) as health_client:
            assert health_client.get("/health").json()["status"] == "ready"
            idle = poll_health(health_client, _stop_after(0.3))

            done = threading.Event()

            def run():
                try:
                    with httpx.Client(base_url=base, timeout=30.0) as c:
                        c.post("/transcribe", json=PAYLOAD)
                finally:
                    done.set()

            worker = threading.Thread(target=run, daemon=True)
            worker.start()
            assert model.entered.wait(timeout=10.0)
            inflight = poll_health(health_client, done)
            worker.join(timeout=10.0)

    # The criterion first, so a regression reports the latency that broke it rather than
    # a sample count. A pinned event loop shows up here as one enormous sample.
    assert inflight, "no /health response at all while a transcribe was running"
    worst = max(inflight)
    p99 = sorted(inflight)[min(len(inflight) - 1, int(0.99 * len(inflight)))]
    assert worst < 50.0, (
        f"/health took {worst:.1f} ms with a transcribe in flight "
        f"(n={len(inflight)}, p99 {p99:.2f} ms, idle median "
        f"{statistics.median(idle):.2f} ms) -- the < 50 ms criterion is broken; "
        f"check /transcribe is still a sync `def`"
    )
    assert len(inflight) > 20, (
        f"only {len(inflight)} samples across a 1.5 s decode -- the poll loop was "
        f"starved, so the latencies above are not a measurement"
    )


def _stop_after(seconds: float) -> threading.Event:
    stop = threading.Event()
    threading.Timer(seconds, stop.set).start()
    return stop


def test_transcribes_serialise_and_none_are_rejected():
    """Three at once: all 200, none concurrent inside the model, wall ~= 3 x solo.

    The contract has no `busy` code, so the correct behaviour is to queue, not to reject.
    """
    delay = 0.4
    loader = RecordingLoader(delay=delay)
    port = free_port()
    app = create_app(config=base_config(port=port), loader=loader)
    results = []
    lock = threading.Lock()

    with live_server(app, port) as base:
        assert wait_until(lambda: len(loader.models) == 1)
        model = loader.models[0]

        def run():
            with httpx.Client(base_url=base, timeout=30.0) as c:
                r = c.post("/transcribe", json=PAYLOAD)
            with lock:
                results.append((r.status_code, r.json()))

        started = time.perf_counter()
        threads = [threading.Thread(target=run, daemon=True) for _ in range(3)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=30.0)
        wall = time.perf_counter() - started

    assert [s for s, _ in results] == [200, 200, 200], results
    assert model.max_concurrent == 1, "two transcriptions were inside the model at once"
    assert len(model.calls) == 3, "every request was served, none dropped"
    assert wall >= 3 * delay, f"wall {wall:.2f}s is too short for three serialised decodes"
    # `elapsed` is measured from endpoint entry, so it includes the queue wait -- which is
    # what the client's 15 s timeout is budgeting against.
    elapsed = sorted(body["elapsed"] for _, body in results)
    assert elapsed[-1] >= 2 * delay, f"the last request did not report its wait: {elapsed}"
