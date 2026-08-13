"""The service must bind 127.0.0.1 and nothing else (done-criterion, and the contract's
reason for having no auth token).

Three layers, because any one of them alone is weak:

1. Config rejects every non-loopback spelling -- the process cannot even be *configured*
   to bind wide.
2. `main()` really does hand `cfg.host` to uvicorn, so layer 1 is on the live path rather
   than a validator nothing calls.
3. A running server is genuinely unreachable on this machine's LAN address.
"""

from __future__ import annotations

import ipaddress
import socket

import pytest

from conftest import free_port, lan_address, live_server
from config import Config, ConfigError, resolve_loopback_host

NON_LOOPBACK = [
    "0.0.0.0",          # the classic mistake: every interface
    "::",               # its IPv6 twin
    "10.149.48.27",     # this machine's own LAN address at the time of writing
    "192.168.1.10",
    "8.8.8.8",
    "example.com",      # a name, which could resolve anywhere and could change under us
    "127.0.0.1:58471",  # host:port smuggled into the host field
]

# An unset-or-blank env var is NOT an error: `_env_str` falls back to the default, which
# is 127.0.0.1. The failure direction is what matters -- blank must never widen the bind.
BLANK = ["", "   "]

LOOPBACK = {
    "127.0.0.1": "127.0.0.1",
    "127.0.0.2": "127.0.0.2",   # the whole 127/8 block is loopback
    "::1": "::1",
    "localhost": "127.0.0.1",   # accepted, but pinned to the literal
    "  127.0.0.1  ": "127.0.0.1",
}


@pytest.mark.parametrize("host", NON_LOOPBACK)
def test_non_loopback_host_is_a_hard_startup_failure(host, monkeypatch):
    with pytest.raises(ConfigError):
        resolve_loopback_host(host)
    # And by the same route the process actually uses.
    monkeypatch.setenv("MARMOT_ASR_HOST", host)
    with pytest.raises(ConfigError):
        Config.from_env()


@pytest.mark.parametrize("host", BLANK)
def test_blank_host_falls_back_to_loopback_rather_than_widening(host, monkeypatch):
    with pytest.raises(ConfigError):
        resolve_loopback_host(host)          # the literal is rejected outright...
    monkeypatch.setenv("MARMOT_ASR_HOST", host)
    assert Config.from_env().host == "127.0.0.1"   # ...and an unset env var means default


@pytest.mark.parametrize("given,expected", LOOPBACK.items())
def test_loopback_hosts_are_accepted(given, expected):
    assert resolve_loopback_host(given) == expected


def test_main_passes_a_loopback_host_to_uvicorn(monkeypatch):
    """Layer 2: the validated host reaches uvicorn, and no literal sneaks past it."""
    import uvicorn

    import app as app_module

    captured = {}
    monkeypatch.setattr(uvicorn, "run", lambda a, **kw: captured.update(kw))
    app_module.main()

    assert captured, "main() never called uvicorn.run"
    assert ipaddress.ip_address(captured["host"]).is_loopback
    assert captured["host"] == app_module.app.state.config.host


def test_running_server_is_not_reachable_off_loopback(loader):
    """Layer 3: the real socket. Reaching it from the LAN address must be refused."""
    from app import create_app

    lan = lan_address()
    if lan is None:
        pytest.skip("no non-loopback IPv4 on this machine")

    port = free_port()
    app = create_app(config=Config(port=port), loader=loader)
    with live_server(app, port):
        with socket.socket() as s:
            s.settimeout(2.0)
            assert s.connect_ex(("127.0.0.1", port)) == 0, "loopback should be reachable"
        with socket.socket() as s:
            s.settimeout(2.0)
            err = s.connect_ex((lan, port))
        assert err != 0, f"server answered on {lan}:{port} -- it is bound off loopback"
