#!/bin/bash
# Provision the local ASR server (marmot-asr-server) for MarmotIM's dictation.
#
# Idempotent by design: a warm run — venv present, deps current, weights cached,
# LaunchAgent loaded and answering — does no real work and costs ~2 seconds.
# scripts/build_and_install.sh calls this automatically; you can also run it alone.
#
# Usage:
#   bash scripts/install_asr.sh                 # provision / bring up to date
#   bash scripts/install_asr.sh --reinstall     # force: rebuild venv, reinstall deps,
#                                               #   rewrite the plist, DISCARD the settings
#                                               #   overlay, restart the agent.
#                                               #   Cached weights are REUSED — to re-fetch
#                                               #   them, delete the model's directory under
#                                               #   ~/.cache/huggingface/hub first.
#   bash scripts/install_asr.sh --uninstall     # unload + remove the LaunchAgent only
#                                               #   (venv and weights are left alone)
#
# What this script DOES modify:
#   - ~/Library/Application Support/MarmotIM/asr/config.json  (settings overlay written by
#                                                     MarmotIM's 转写 page via POST /reconfigure;
#                                                     --reinstall DELETES it, which is the way
#                                                     back from a setting that leaves the server
#                                                     unreachable)
#   - ~/Library/Application Support/MarmotIM/asr/    (the venv + a copy of server/ that the
#                                                     agent actually runs; deliberately NOT in
#                                                     the checkout, so moving or deleting the
#                                                     repo cannot break a loaded agent)
#   - ~/.cache/huggingface/hub/                      (model weights, ~4.1 GB for the default)
#   - ~/Library/LaunchAgents/com.marmotim.asr.plist  (rendered from scripts/com.marmotim.asr.plist)
#   - ~/Library/Logs/MarmotIM/asr-server.{out,err}.log
#   - Homebrew's python@3.12 formula, and only if no python3.12 exists yet
#
# What this script does NOT touch:
#   - system `python3` — the venv is entirely separate, so tools/build_dictionary.py
#     keeps running on whatever python3 you already have
#   - ~/Library/Application Support/MarmotIM/*   (user dictionary, settings, sync markers)
#   - ~/Library/Mobile Documents/iCloud~com~marmotim~.../  (iCloud state)
#   - server/  — that tree is source; this script only reads it
#
# The agent binds 127.0.0.1 only. The service is unauthenticated by design, and the
# server itself refuses any non-loopback bind (server/config.py resolve_loopback_host).

set -e
set -o pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

# The RUNTIME lives outside the checkout, and the LaunchAgent points only at it.
#
# It used to live at $REPO_ROOT/.venv-asr with the agent running $REPO_ROOT/server/app.py.
# That made the agent silently dependent on the checkout never moving: rename the folder,
# relocate it, or delete it after a release build, and launchd keeps the job loaded while
# every start fails. Nothing surfaces that except the log.
#
# So: server/ is the SOURCE (tracked, edited, read only by this script), and a copy of it
# plus the venv live under Application Support, which nothing but this script touches.
RUNTIME_DIR="$HOME/Library/Application Support/MarmotIM/asr"
VENV_DIR="$RUNTIME_DIR/venv"
VENV_PY="$VENV_DIR/bin/python"
SERVER_SRC="$REPO_ROOT/server"
SERVER_DIR="$RUNTIME_DIR/server"
REQS="$SERVER_SRC/requirements.txt"
PLIST_TEMPLATE="$REPO_ROOT/scripts/com.marmotim.asr.plist"

# The pre-relocation layout, kept only so this script can notice it and clean up after it.
LEGACY_VENV="$REPO_ROOT/.venv-asr"

LABEL="com.marmotim.asr"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/MarmotIM"
LOG_OUT="$LOG_DIR/asr-server.out.log"
LOG_ERR="$LOG_DIR/asr-server.err.log"

# Keep these two in sync with server/config.py's DEFAULT_MODEL / DEFAULT_PORT.
# Read from there rather than duplicated by hand: see resolve_defaults() below.
MODEL=""
PORT=""

FORCE=0
UNINSTALL=0
for arg in "$@"; do
    case "$arg" in
        --reinstall) FORCE=1 ;;
        --uninstall) UNINSTALL=1 ;;
        # Lines 2..first non-comment, terminator suppressed — the header just grew by
        # three lines and a hardcoded range would already have been truncating it.
        -h|--help)   sed -n '2,/^[^#]/{/^[^#]/!p;}' "$0"; exit 0 ;;
        *) echo "install_asr.sh: unknown argument '$arg'" >&2; exit 2 ;;
    esac
done

say()  { echo "  $*"; }
step() { echo "[asr] $*"; }
fail() { echo "[asr] ERROR: $*" >&2; exit 1; }

# Stamps let the warm path skip work without guessing. Each records the input that
# would make the corresponding step's output stale.
stamp_read()  { cat "$1" 2>/dev/null || echo ""; }
stamp_write() { printf '%s' "$2" > "$1"; }

# ---------------------------------------------------------------- uninstall path
if [ "$UNINSTALL" -eq 1 ]; then
    step "Removing the LaunchAgent (venv and cached weights are left in place)"
    launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
    rm -f "$PLIST_DEST"
    say "Removed $PLIST_DEST"
    say "To reclaim disk: rm -rf '$RUNTIME_DIR' and the model dirs under ~/.cache/huggingface/hub"
    exit 0
fi

# ---------------------------------------------------------------- 0. sanity
[ -f "$REQS" ] || fail "$REQS not found — is server/ checked out?"
[ -f "$SERVER_SRC/app.py" ] || fail "$SERVER_SRC/app.py not found."
[ -f "$PLIST_TEMPLATE" ] || fail "$PLIST_TEMPLATE not found."
mkdir -p "$RUNTIME_DIR"

# ------------------------------------------------------- 0b. migrate the old layout
# Before the relocation the venv lived at $REPO_ROOT/.venv-asr and the agent ran
# $REPO_ROOT/server/app.py. An agent still pointing in there must be stopped before we
# stand up the new one, or two servers race for the port.
#
# The venv is NOT deleted for you: it is several hundred MB inside your checkout and
# removing someone's files without asking is not this script's call. Cached weights are
# untouched either way — they live in ~/.cache/huggingface/hub, outside both layouts —
# so migrating costs a dependency reinstall, not a re-download.
LEGACY_AGENT=0
if [ -f "$PLIST_DEST" ] && grep -q "$REPO_ROOT/\(server\|.venv-asr\)" "$PLIST_DEST" 2>/dev/null; then
    LEGACY_AGENT=1
fi
if [ "$LEGACY_AGENT" -eq 1 ]; then
    step "Found an agent pointing into the checkout — migrating it out"
    launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
    say "stopped the old agent; it will be re-created against $RUNTIME_DIR"
fi
if [ -d "$LEGACY_VENV" ]; then
    say "note: the old venv is still at $LEGACY_VENV and is no longer used."
    say "      reclaim it with:  rm -rf '$LEGACY_VENV'"
fi

# ------------------------------------------------------- 0c. reset the settings overlay
# --reinstall is the documented way back from a configuration that cannot reach a working
# server: MarmotIM's 转写 page writes an overlay through POST /reconfigure, and the overlay
# outranks the plist at startup (server/config.py Config.load). If someone sets a port the
# server cannot bind, the page is then pointing at nothing and cannot undo it — so the
# escape hatch has to clear the overlay, not just rewrite the plist it already loses to.
#
# Only under --reinstall. A plain run must not silently discard settings someone chose.
OVERLAY="$RUNTIME_DIR/config.json"
if [ "$FORCE" -eq 1 ] && [ -f "$OVERLAY" ]; then
    step "Discarding the settings overlay (--reinstall)"
    rm -f "$OVERLAY"
    say "removed $OVERLAY; the LaunchAgent's values apply again"
fi

# ---------------------------------------------------------------- 1. interpreter
# Python 3.12 exactly: qwen3-asr-mlx supports 3.10–3.13, and this machine's system
# python3 is 3.14 (server/README.md §5). We never touch that python3 — the venv is
# built from a separate interpreter so tools/build_dictionary.py is unaffected.
step "Locating a Python 3.12 interpreter"
PY312=""
for candidate in python3.12 /opt/homebrew/bin/python3.12 /usr/local/bin/python3.12; do
    if command -v "$candidate" > /dev/null 2>&1; then
        PY312="$(command -v "$candidate")"
        break
    fi
done

if [ -z "$PY312" ]; then
    command -v brew > /dev/null 2>&1 || fail \
        "no python3.12 and no Homebrew to install one. Install Python 3.12 and re-run."
    step "No python3.12 found — installing Homebrew python@3.12 (this takes a few minutes)"
    brew install python@3.12 || fail "brew install python@3.12 failed."
    PY312="$(brew --prefix python@3.12)/bin/python3.12"
    [ -x "$PY312" ] || fail "brew installed python@3.12 but $PY312 is not executable."
fi
say "$PY312 ($("$PY312" -c 'import sys; print(sys.version.split()[0])'))"

# ---------------------------------------------------------------- 2. venv
VENV_OK=0
if [ "$FORCE" -eq 0 ] && [ -x "$VENV_PY" ]; then
    # An existing venv whose interpreter moved or changed minor version is worse than
    # no venv: pip succeeds and imports fail later. Check before trusting it.
    if "$VENV_PY" -c 'import sys; sys.exit(0 if sys.version_info[:2] == (3, 12) else 1)' 2>/dev/null; then
        VENV_OK=1
    else
        say "existing venv is not Python 3.12 — rebuilding it"
    fi
fi

if [ "$VENV_OK" -eq 0 ]; then
    step "Creating the venv at $VENV_DIR"
    rm -rf "$VENV_DIR"
    "$PY312" -m venv "$VENV_DIR" || fail "venv creation failed."
    "$VENV_PY" -m pip install --quiet --upgrade pip > /dev/null 2>&1 || true
    rm -f "$VENV_DIR/.marmot-reqs" "$VENV_DIR/.marmot-server"
else
    step "venv is present and is Python 3.12"
fi

# ---------------------------------------------------------------- 3. dependencies
# The stamp is the hash of requirements.txt. `pip install -r` on an already-satisfied
# set still costs several seconds of resolution, and the warm path has a 2 s budget.
REQS_HASH="$(shasum -a 256 "$REQS" | cut -d' ' -f1)"
if [ "$FORCE" -eq 1 ] || [ "$(stamp_read "$VENV_DIR/.marmot-reqs")" != "$REQS_HASH" ]; then
    step "Installing server dependencies (first run downloads mlx + friends)"
    "$VENV_PY" -m pip install --disable-pip-version-check -r "$REQS" \
        || fail "pip install failed — see the output above. If it is a network error, retry when online."
    stamp_write "$VENV_DIR/.marmot-reqs" "$REQS_HASH"
else
    step "Dependencies match $REQS — nothing to install"
fi

# ---------------------------------------------------------------- 4. model weights
# Defaults come from server/config.py so they cannot drift from what the server will
# actually load if MARMOT_ASR_MODEL is unset.
resolve_defaults() {
    "$VENV_PY" - "$SERVER_SRC" <<'PY'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("marmot_asr_config", sys.argv[1] + "/config.py")
mod = importlib.util.module_from_spec(spec)
# Register before exec: config.py defines a @dataclass, and dataclasses resolves the
# class's module out of sys.modules. Without this line it dies with an AttributeError
# on None — verified, not theoretical.
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)
print(mod.DEFAULT_MODEL)
print(mod.DEFAULT_PORT)
PY
}
DEFAULTS="$(resolve_defaults)" || fail "could not read defaults from server/config.py."
MODEL="${MARMOT_ASR_MODEL:-$(printf '%s' "$DEFAULTS" | sed -n 1p)}"
PORT="${MARMOT_ASR_PORT:-$(printf '%s' "$DEFAULTS" | sed -n 2p)}"

# Is the repo already fully in the HF cache? snapshot_download(local_files_only=True)
# answers this exactly — it succeeds only when every file of the revision is present.
# Deliberately NOT `du` on the snapshot directory: a snapshot holds only symlinks into
# blobs/, so `du -sh` there reports 0B and any size check built on it is worthless.
#
# The probe runs even under --reinstall. Weights are inputs, not build output: forcing a
# re-download of 4 GB that is already on disk is never what --reinstall means, and on a
# tight disk the free-space check below would fail a reinstall that needed no download at
# all. To genuinely re-fetch weights, delete the repo's directory under the HF cache.
export HF_HUB_DISABLE_XET=1
MODEL_CACHED=0
if "$VENV_PY" - "$MODEL" > /dev/null 2>&1 <<'PY'
import sys
from huggingface_hub import snapshot_download
snapshot_download(sys.argv[1], local_files_only=True)
PY
then
    MODEL_CACHED=1
fi

if [ "$MODEL_CACHED" -eq 1 ]; then
    step "Model $MODEL is already in the Hugging Face cache"
else
    step "Model $MODEL is not cached — checking free disk before downloading"
    # Ask the Hub how big the repo actually is; fall back to sizes measured on this
    # machine only if the API is unreachable. A hardcoded number goes stale the moment
    # the default model changes, which it already has once.
    NEED_BYTES="$("$VENV_PY" - "$MODEL" <<'PY'
import sys
FALLBACK = {
    # measured with `du -shL` on a complete cache: 3.8 GiB and 1.5 GiB
    "mlx-community/Qwen3-ASR-1.7B-bf16": 4_100_000_000,
    "mlx-community/Qwen3-ASR-0.6B-bf16": 1_650_000_000,
}
repo = sys.argv[1]
try:
    from huggingface_hub import model_info
    info = model_info(repo, files_metadata=True)
    total = sum(s.size or 0 for s in (info.siblings or []))
    if total > 0:
        print(total)
        sys.exit(0)
except Exception as exc:  # offline, rate-limited, private repo, API shape change
    print(f"could not query the Hub for {repo}: {exc}", file=sys.stderr)
print(FALLBACK.get(repo, 5_000_000_000))
PY
)" || fail "could not determine the size of $MODEL."

    # Headroom on top of the download: HF writes a .incomplete file and then links it
    # into place, and a disk that ends up at zero free is its own kind of outage.
    HEADROOM=2000000000
    CACHE_ROOT="${HF_HOME:-$HOME/.cache/huggingface}"
    mkdir -p "$CACHE_ROOT"
    FREE_BYTES=$(( $(df -k "$CACHE_ROOT" | awk 'NR==2 {print $4}') * 1024 ))
    say "need $(( (NEED_BYTES + HEADROOM) / 1000000 )) MB (weights $(( NEED_BYTES / 1000000 )) MB + headroom), free $(( FREE_BYTES / 1000000 )) MB"
    if [ "$FREE_BYTES" -lt $(( NEED_BYTES + HEADROOM )) ]; then
        fail "not enough free disk on $CACHE_ROOT to download $MODEL. Free some space and re-run."
    fi

    step "Downloading $MODEL — expect 15–100 minutes on an unauthenticated connection"
    say "progress is per-file; it resumes if interrupted, so a re-run is cheap"
    if ! "$VENV_PY" -u - "$MODEL" <<'PY'
import sys
from huggingface_hub import snapshot_download
# max_workers=2 measured fastest here; the Xet backend (disabled above) stalls at 0 bytes.
snapshot_download(sys.argv[1], max_workers=2)
PY
    then
        echo "" >&2
        fail "download of $MODEL failed. If you are offline, reconnect and re-run — \
partial files are kept and the transfer resumes. Nothing else on this machine was changed."
    fi
fi

# --------------------------------------------------- 4b. sync source into the runtime
# The agent runs $SERVER_DIR, never $SERVER_SRC. Copy on every run: it is a handful of
# small .py files, and comparing them costs more than writing them. The restart decision
# is made separately (SERVER_HASH, below) — this step only guarantees that whatever the
# agent is about to start is the code currently checked out.
step "Syncing server code into $RUNTIME_DIR"
mkdir -p "$SERVER_DIR"
# Explicitly *.py + requirements.txt rather than `cp -R "$SERVER_SRC"/.`: the source tree
# also carries tests/ and __pycache__/, and the runtime has no use for either.
cp "$SERVER_SRC"/*.py "$SERVER_DIR/" || fail "could not copy server sources into $SERVER_DIR."
cp "$REQS" "$SERVER_DIR/requirements.txt"
say "$(ls -1 "$SERVER_DIR"/*.py | wc -l | tr -d ' ') modules"

# ---------------------------------------------------------------- 5. LaunchAgent
step "Rendering the LaunchAgent"
mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents"
RENDERED="$(mktemp -t marmot-asr-plist)"
# `|` as the sed delimiter: every substitution here is a path or a repo id with slashes.
sed -e "s|@VENV_PYTHON@|$VENV_PY|g" \
    -e "s|@SERVER_DIR@|$SERVER_DIR|g" \
    -e "s|@MODEL@|$MODEL|g" \
    -e "s|@PORT@|$PORT|g" \
    -e "s|@LOG_OUT@|$LOG_OUT|g" \
    -e "s|@LOG_ERR@|$LOG_ERR|g" \
    -e "s|@PATH@|$VENV_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin|g" \
    "$PLIST_TEMPLATE" > "$RENDERED"
plutil -lint "$RENDERED" > /dev/null || { rm -f "$RENDERED"; fail "rendered plist is malformed."; }
# A placeholder added to the template but not to the sed list above would install an
# agent whose ProgramArguments is the literal string "@VENV_PYTHON@" — a plist that
# lints fine and can never start. Catch it here instead.
if grep -q '@[A-Z_]\{2,\}@' "$RENDERED"; then
    grep -n '@[A-Z_]\{2,\}@' "$RENDERED" >&2
    rm -f "$RENDERED"
    fail "unsubstituted placeholder(s) in the rendered plist (see above) — add them to the sed list in this script."
fi

PLIST_CHANGED=0
if ! cmp -s "$RENDERED" "$PLIST_DEST"; then
    PLIST_CHANGED=1
    cp "$RENDERED" "$PLIST_DEST"
    say "wrote $PLIST_DEST"
else
    say "$PLIST_DEST is already current"
fi
rm -f "$RENDERED"

# Restart when — and only when — something the running process has already read has
# changed. Restarting unconditionally would re-read ~4 GB of weights on every warm run
# and blow the 2 s budget for no benefit.
SERVER_HASH="$( (shasum -a 256 "$SERVER_SRC"/*.py; printf '%s' "$REQS_HASH") | shasum -a 256 | cut -d' ' -f1)"
# `if` rather than `[ … ] && VAR=1`: under `set -e` a trailing false test would abort
# the script instead of just leaving the flag at 0.
NEEDS_RESTART=0
if [ "$FORCE" -eq 1 ]; then NEEDS_RESTART=1; fi
if [ "$PLIST_CHANGED" -eq 1 ]; then NEEDS_RESTART=1; fi
if [ "$(stamp_read "$VENV_DIR/.marmot-server")" != "$SERVER_HASH" ]; then NEEDS_RESTART=1; fi

LOADED=0
if launchctl print "gui/$UID/$LABEL" > /dev/null 2>&1; then LOADED=1; fi

# `launchctl bootout` returns before the job is actually gone. A bootstrap issued inside
# that window fails with `Bootstrap failed: 5: Input/output error` and the script aborts
# having just torn the agent down — the worst possible outcome, and it only ever happens
# on the restart path, which is why it survived until a server change forced one.
wait_until_unloaded() {
    for _ in $(seq 1 50); do
        launchctl print "gui/$UID/$LABEL" > /dev/null 2>&1 || return 0
        sleep 0.1
    done
    return 1   # still there after 5 s; let the caller report it
}

bootstrap_agent() {
    launchctl bootstrap "gui/$UID" "$PLIST_DEST" && return 0
    # Losing the race is recoverable; a genuinely broken plist is not. Distinguish them
    # by looking at what actually happened rather than by trusting the exit code.
    if launchctl print "gui/$UID/$LABEL" > /dev/null 2>&1; then
        say "bootstrap reported an error but the agent is loaded — continuing"
        return 0
    fi
    fail "launchctl bootstrap failed and the agent is not loaded. Try: launchctl print gui/$UID/$LABEL"
}

if [ "$LOADED" -eq 0 ]; then
    step "Loading the agent"
    bootstrap_agent
elif [ "$NEEDS_RESTART" -eq 1 ]; then
    step "Server code or configuration changed — restarting the agent"
    # bootout+bootstrap rather than kickstart: the plist itself may have changed, and
    # kickstart re-runs the *loaded* job definition, not the file on disk.
    launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
    wait_until_unloaded || say "the old job is taking its time to exit; bootstrapping anyway"
    bootstrap_agent
else
    step "Agent is loaded and current — leaving it running"
fi

# ---------------------------------------------------------------- 6. verify
# A 200 from /health is the success bar, not `status == "ready"`: after a cold start the
# server answers immediately and reports "loading" while it reads the weights, which is
# correct behaviour and can take a while. Reaching `ready` is the client's problem
# (ASRHealthMonitor polls for it), not the installer's.
step "Waiting for GET http://127.0.0.1:$PORT/health"
HEALTH=""
for _ in $(seq 1 30); do
    if HEALTH="$(curl -fsS --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null)"; then
        break
    fi
    HEALTH=""
    sleep 1
done

if [ -z "$HEALTH" ]; then
    echo "[asr] ERROR: the agent is loaded but /health did not answer within 30s." >&2
    echo "       Logs: $LOG_ERR" >&2
    echo "       Try:  tail -20 '$LOG_ERR'; launchctl print gui/$UID/$LABEL | head -20" >&2
    exit 1
fi

# Stamped HERE, below the health gate, and not up beside the launchctl block where it
# visually belongs: the stamp must mean "this server hash started and answered", never
# "we tried to start it". Stamped early, a start that loads but never answers is recorded
# as current — and the operator's obvious remedy, re-running this script, then computes
# NEEDS_RESTART=0 and finds the job present (KeepAlive respawns a job that crashes on
# start), so it prints "Agent is loaded and current" and restarts nothing. Leave it here.
stamp_write "$VENV_DIR/.marmot-server" "$SERVER_HASH"

step "ASR server is up: $HEALTH"
say "model:  $MODEL"
say "url:    http://127.0.0.1:$PORT  (loopback only)"
say "logs:   $LOG_ERR"
say "manage: launchctl kickstart -k gui/$UID/$LABEL   # restart"
say "        bash scripts/install_asr.sh --uninstall  # remove the agent"
