"""Shared fixtures. The whole suite runs with **no weights and no mlx installed**.

Two things make that possible and both are load-bearing:

- `create_app(loader=...)` takes an injectable loader, and `model.default_loader` is the
  only place `qwen3_asr_mlx` is imported (lazily, inside the function). Nothing in this
  suite calls it, so the import never happens. `test_no_weights.py` asserts that.
- The fakes below stand in for `Qwen3ASR`, matching only the surface the server touches:
  `transcribe(samples, language=, context=, max_tokens=) -> result`, and `close()`.

Where a test needs a real socket (bind checks, concurrency, `/health` under load) it gets
a real uvicorn in a background thread rather than an ASGI transport -- ported from the
ad-hoc harness that produced the milestone-4 numbers, which measured over loopback for
exactly this reason: an in-process transport cannot show you a request queueing behind a
blocked worker.
"""

from __future__ import annotations

import contextlib
import socket
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

import pytest

# app.py / config.py / model.py import each other flatly (`from config import ...`),
# which is how they run as `python app.py`. Put that directory on the path rather than
# restructuring the service into a package for the tests' convenience.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from config import Config  # noqa: E402
from model import ModelManager  # noqa: E402


@dataclass
class FakeResult:
    text: str = "hello"
    language: Optional[str] = "English"
    duration: float = 0.0


@dataclass
class FakeModel:
    """Records what it was handed and how it was torn down."""

    name: str = "fake"
    text: str = "hello"
    language: Optional[str] = "English"
    # Seconds each transcribe blocks -- stands in for a real decode.
    delay: float = 0.0
    raises: Optional[BaseException] = None
    calls: list[dict[str, Any]] = field(default_factory=list)
    closed: threading.Event = field(default_factory=threading.Event)
    # Set while a transcribe is running, so a test can prove close() did not land inside one.
    in_flight: threading.Event = field(default_factory=threading.Event)
    close_hit_in_flight: bool = False
    entered: threading.Event = field(default_factory=threading.Event)
    release: Optional[threading.Event] = None
    # Highest number of transcribes ever inside this model at once. The done-criterion is
    # "one transcription at a time", so this must never exceed 1.
    max_concurrent: int = 0
    _active: int = 0
    _counter_lock: threading.Lock = field(default_factory=threading.Lock)

    def transcribe(self, samples, *, language=None, context=None, max_tokens=None):
        with self._counter_lock:
            self._active += 1
            self.max_concurrent = max(self.max_concurrent, self._active)
        self.calls.append({
            "n_samples": int(getattr(samples, "size", len(samples))),
            "dtype": str(getattr(samples, "dtype", "")),
            "language": language,
            "context": context,
            "max_tokens": max_tokens,
        })
        self.in_flight.set()
        self.entered.set()
        try:
            if self.release is not None:
                assert self.release.wait(timeout=10.0), "release event never set"
            if self.delay:
                time.sleep(self.delay)
            if self.raises is not None:
                raise self.raises
            return FakeResult(text=self.text, language=self.language)
        finally:
            with self._counter_lock:
                self._active -= 1
            self.in_flight.clear()

    def close(self):
        # The whole point of ModelManager's inference lock: this must never be true.
        if self.in_flight.is_set():
            self.close_hit_in_flight = True
        self.closed.set()


class RecordingLoader:
    """A loader for `create_app(loader=...)`. Hands out one FakeModel per model id."""

    # `load_delay` is the loader's own; anything else goes to the FakeModel it builds.
    # These were both called `delay` once, and the loader silently ate the model's --
    # every "concurrent" transcribe then finished instantly and the tests still passed
    # their status-code assertions. Hence the two names.
    def __init__(self, *, load_delay: float = 0.0, fail: bool = False, **model_kwargs):
        self.load_delay = load_delay
        self.fail = fail
        self.model_kwargs = model_kwargs
        self.requested: list[str] = []
        self.models: list[FakeModel] = []
        self.started = threading.Event()
        self.gate: Optional[threading.Event] = None

    def __call__(self, model_id: str) -> FakeModel:
        self.requested.append(model_id)
        self.started.set()
        if self.gate is not None:
            assert self.gate.wait(timeout=10.0), "loader gate never opened"
        if self.load_delay:
            time.sleep(self.load_delay)
        if self.fail:
            raise RuntimeError(f"synthetic load failure for {model_id}")
        model = FakeModel(name=model_id, **self.model_kwargs)
        self.models.append(model)
        return model

    def model_for(self, model_id: str) -> FakeModel:
        return next(m for m in self.models if m.name == model_id)


def base_config(**overrides) -> Config:
    """A Config that never touches the environment, so tests cannot be perturbed by it."""
    return Config(**overrides)


@pytest.fixture
def loader() -> RecordingLoader:
    return RecordingLoader()


def wait_until(predicate, timeout: float = 10.0, interval: float = 0.005) -> bool:
    """Poll a condition. Used instead of sleeps so a slow machine does not flake the suite."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return predicate()


def free_port() -> int:
    """Ask the OS for an unused loopback port, then release it.

    Racy in principle; in practice the kernel does not hand the same ephemeral port out
    twice in the microseconds before uvicorn binds it, and the alternative (a fixed port)
    collides with the debug servers a human may have running.
    """
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@contextlib.contextmanager
def live_server(app, port: int, startup_timeout: float = 10.0):
    """Run `app` under a real uvicorn on 127.0.0.1:port in a background thread.

    Yields the base URL once the socket is accepting. Note it deliberately does NOT wait
    for the model: the contract requires `/health` to answer `loading` from the first
    instant the socket is up, and several tests check exactly that.
    """
    import uvicorn

    config = uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning",
                            access_log=False)
    server = uvicorn.Server(config)
    thread = threading.Thread(target=server.run, name=f"uvicorn-{port}", daemon=True)
    thread.start()
    try:
        if not wait_until(lambda: server.started, timeout=startup_timeout):
            raise RuntimeError("uvicorn did not start")
        yield f"http://127.0.0.1:{port}"
    finally:
        server.should_exit = True
        thread.join(timeout=10.0)


def lan_address() -> Optional[str]:
    """This machine's non-loopback IPv4, or None. No packet is sent -- connecting a UDP
    socket only picks a route, which is enough to learn the source address."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        try:
            s.connect(("192.0.2.1", 9))  # TEST-NET-1, deliberately unroutable
            addr = s.getsockname()[0]
        except OSError:
            return None
    return None if addr.startswith("127.") else addr


__all__ = [
    "FakeModel", "FakeResult", "RecordingLoader", "ModelManager", "base_config",
    "wait_until", "free_port", "live_server", "lan_address",
]
