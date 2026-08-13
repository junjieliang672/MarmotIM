#!/bin/bash
# Build and install MarmotIM - no logout required.
# Rebuilds the dictionary from vocab/, compiles the app, reinstalls it, and
# relaunches the input method. With --all it also provisions the local ASR
# server that dictation talks to.
#
# Renamed from scripts/quick_update.sh; that name survives as a thin shim which
# prints this name and delegates here.
#
# Usage:
#   bash scripts/build_and_install.sh                  # input method ONLY. Touches nothing
#                                                      #   under ~/Library/Application Support/
#                                                      #   MarmotIM/asr/, the HF cache, or
#                                                      #   ~/Library/LaunchAgents.
#   bash scripts/build_and_install.sh --all            # input method + the local ASR server:
#                                                      #   interpreter, venv, deps, ~4 GB of
#                                                      #   model weights, and a LaunchAgent
#                                                      #   that starts it at login.
#   bash scripts/build_and_install.sh --reinstall-asr  # implies --all, and forces the venv,
#                                                      #   deps and plist to be rebuilt and the
#                                                      #   agent restarted
#
# ASR provisioning is OPT-IN. It used to be the default, which meant a bare run could
# start a multi-gigabyte download nobody asked for. Dictation is an optional feature;
# installing the input method should not commit you to it.
#
# The ASR half is deliberately LAST and deliberately non-fatal: by the time it runs
# the input method is already installed and relaunched, so a failure there (offline,
# no disk, no Python) warns and leaves you with a working IME. Exit status therefore
# reports the input-method install, which is this script's actual product.
#
# What this script DOES modify:
#   - dict/dictionary.db       (rebuilt from vocab/ source)
#   - build/**                 (xcodebuild output)
#   - /Library/Input Methods/MarmotIM.app  (sudo cp + codesign)
#   - with --all ONLY, everything scripts/install_asr.sh modifies:
#     ~/Library/Application Support/MarmotIM/asr/, ~/.cache/huggingface/hub/,
#     ~/Library/LaunchAgents/com.marmotim.asr.plist, ~/Library/Logs/MarmotIM/.
#     See that script's header for the full list.
#
# What this script does NOT touch (safe across updates):
#   - ~/Library/Application Support/MarmotIM/dictionary.db  (user data)
#   - ~/Library/Application Support/MarmotIM/config.json    (user settings)
#   - ~/Library/Application Support/MarmotIM/.marmotim.sync-state.*  (sync markers, spec-004)
#   - ~/Library/Mobile Documents/iCloud~com~marmotim~.../  (iCloud state)
#
# Schema migrations (v6 → v7 from spec-001, v7 → v8 from spec-003) run automatically
# in VocabularyDatabase.performMigrations() at app launch — no script action needed.
#
# Note on the dictionary: the fuzzy pinyin (模糊拼音) index is deliberately NOT
# built here — see the comment above the build step. To restore it, drop the
# --no-build-fuzzy flag.

set -e
set -o pipefail   # so `xcodebuild | grep` propagates xcodebuild's exit code
cd "$(dirname "$0")/.."

WITH_ASR=0
ASR_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --all)           WITH_ASR=1 ;;
        # --reinstall-asr implies --all: asking to force-rebuild the ASR side while it is
        # not being provisioned at all has no coherent meaning, and erroring instead would
        # just be pedantry.
        --reinstall-asr) WITH_ASR=1; ASR_ARGS+=(--reinstall) ;;
        # Print the header comment, however long it grows: lines 2 through the first
        # non-comment line, with that terminator suppressed. A hardcoded line range
        # here rots silently every time the header is edited.
        -h|--help)       sed -n '2,/^[^#]/{/^[^#]/!p;}' "$0"; exit 0 ;;
        # Unknown flags abort BEFORE the build rather than being ignored: a typo'd
        # --alll that silently skipped provisioning is the worst of both worlds.
        *) echo "build_and_install.sh: unknown argument '$arg' (see --help)" >&2; exit 2 ;;
    esac
done

# Step 1: Rebuild dictionary from vocab sources.
# This regenerates dict/dictionary.db which gets bundled into the .app in step 4.
# User data at ~/Library/Application Support/MarmotIM/dictionary.db is NOT modified.
echo "Building dictionary..."
# --no-build-fuzzy: the fuzzy pinyin index is no longer built as part of the
# install pipeline. It cost ~6.7M rows / ~382MB of a 1.2GB database, and the
# 模糊拼音 filter mode is rarely used.
#
# This is REMOVAL, not deferral: build_dictionary.py deletes and recreates
# dict/dictionary.db on every run, so skipping the build leaves the
# fuzzy_pinyin table empty and 模糊拼音 mode returns no results. The table and
# its schema still exist, so nothing that queries it breaks.
#
# To restore: drop the flag below (the tool still builds the index by default).
python3 tools/build_dictionary.py --no-build-fuzzy
echo ""

# Hard-fail if the Python build didn't produce the expected artifact. On a fresh
# clone this is the difference between "new IME has a working dictionary" and
# "user has no words." (spec-004 install-script hardening)
if [ ! -f "dict/dictionary.db" ]; then
    echo "ERROR: dict/dictionary.db was not produced by tools/build_dictionary.py." >&2
    echo "       Check the Python output above for errors. Cannot proceed." >&2
    exit 1
fi

# Step 2: Build the app. We filter xcodebuild's output for readability, but
# pipefail + set -e ensure a real failure still aborts here (previously masked).
echo "Building app..."
# -allowProvisioningUpdates: the target is CODE_SIGN_STYLE=Automatic with iCloud
# entitlements, so signing needs a provisioning profile for
# com.marmotim.inputmethod.MarmotIM. When a valid one is already cached this flag
# changes nothing. When there is none — a fresh machine, an expired profile, a
# refreshed certificate — xcodebuild must ASK Apple for one, and without this flag it
# refuses non-interactively and fails with:
#
#   No profiles for 'com.marmotim.inputmethod.MarmotIM' were found ...
#   Automatic signing is disabled and unable to generate a profile.
#
# That is the first thing a new machine hits, which is exactly when this script is
# least able to explain itself. Note it needs an Xcode signed in to the Apple ID that
# owns DEVELOPMENT_TEAM; with no account at all, use scripts/build.sh --no-icloud,
# which drops the entitlements that require a profile in the first place.
xcodebuild -allowProvisioningUpdates -project MarmotIM.xcodeproj -scheme MarmotIM -configuration Release build CONFIGURATION_BUILD_DIR="$(pwd)/build" 2>&1 | grep -E "(error:|BUILD)" | tail -5

if [ ! -d "build/MarmotIM.app" ]; then
    echo "ERROR: xcodebuild did not produce build/MarmotIM.app. Check build output above." >&2
    exit 1
fi

# Step 3: Stop old process
echo "Stopping old process..."
# Graceful shutdown: send SIGTERM first to allow proper cleanup (WAL checkpoint, etc.)
if pgrep -f MarmotIM > /dev/null 2>&1; then
    killall -TERM MarmotIM 2>/dev/null || true
    # Wait for graceful shutdown (up to 3 seconds)
    for i in {1..6}; do
        if ! pgrep -f MarmotIM > /dev/null 2>&1; then
            break
        fi
        sleep 0.5
    done
    # Force kill if still running
    if pgrep -f MarmotIM > /dev/null 2>&1; then
        echo "  Force stopping..."
        killall -KILL MarmotIM 2>/dev/null || true
        sleep 0.5
    fi
fi

# Step 4: Inject dictionary.db into the App Bundle.
# This is required because dictionary.db is not in the Xcode project Resources
# phase. VocabularyDatabase.installFromBundle() at first launch copies this
# into ~/Library/Application Support/ only if no user DB exists yet — for
# existing users, their data is preserved and the bundled DB is unused at runtime.
echo "Injecting dictionary.db into App Bundle..."
# step 1 already hard-failed if dict/dictionary.db was missing, so this exists.
mkdir -p "build/MarmotIM.app/Contents/Resources"
cp -f "dict/dictionary.db" "build/MarmotIM.app/Contents/Resources/"

# Step 5: Install app to /Library/Input Methods
echo "Installing..."
sudo rm -rf /Library/Input\ Methods/MarmotIM.app
sudo cp -r build/MarmotIM.app /Library/Input\ Methods/MarmotIM.app
# REVERTED 2026-08-12: do NOT pass --entitlements on this ad-hoc re-sign.
#
# The attempt was reasonable — a bare `--sign -` replaces Xcode's signature and
# drops its entitlements, so the dev install had been running iCloud sync while
# declaring no iCloud entitlements. But restoring them here BREAKS THE APP:
# `com.apple.developer.icloud-container-identifiers` and `…ubiquity-container-…`
# are RESTRICTED entitlements that require a real provisioning profile. An
# ad-hoc signature (`flags=0x2(adhoc)`, `TeamIdentifier=not set`) cannot carry
# them, so launchd refuses to spawn the process:
#
#   Launch failed. NSPOSIXErrorDomain Code=163 "Launchd job spawn failed"
#
# Observed on the real install, which is why it was not caught earlier: the
# checklist step that launches the app (§A2/§A4) had been deferred, so nothing
# ever started the re-signed bundle.
#
# The missing-entitlements issue is real but is NOT fixable on the ad-hoc dev
# path — it needs a Developer ID identity, which belongs with a notarized build.
# Sync works today by other means; leave that alone here.
#
# Also deliberately NOT passing `-o runtime`: hardened runtime is stripped on
# this path, and enabling it would start enforcing entitlement-gated
# capabilities on a bundle that declares none (e.g. the microphone).
sudo codesign --force --deep --sign - /Library/Input\ Methods/MarmotIM.app

# Step 6: Start
echo "Starting..."
open /Library/Input\ Methods/MarmotIM.app

# Step 7: Post-install sanity check. Confirms the installed binary is the one
# we just built (catches stale install / codesign-overwrite / wrong-path bugs
# that would otherwise silently ship an old version).
INSTALLED_MTIME=$(stat -f %m "/Library/Input Methods/MarmotIM.app/Contents/MacOS/MarmotIM" 2>/dev/null || echo 0)
BUILT_MTIME=$(stat -f %m "build/MarmotIM.app/Contents/MacOS/MarmotIM" 2>/dev/null || echo 0)
if [ "$INSTALLED_MTIME" -lt "$BUILT_MTIME" ]; then
    echo "WARNING: installed binary appears older than the build output — install may not have taken effect." >&2
else
    # Print the PASS too, not just the FAIL. This line is what an operator reads to
    # decide whether the install worked, so silence-means-success is the wrong shape.
    echo "OK: installed binary is the one just built (mtime check passed)."
fi

echo "Done! Input method updated."
echo ""
# This step used to tell the operator to re-grant the microphone after every
# install, on the theory that the ad-hoc re-sign changes the cdhash and TCC keys
# permissions to the code signature. That was measured and it is FALSE for this
# capability: spike Q4 reinstalled a granted bundle, got a fresh cdhash, and
# AVCaptureDevice.authorizationStatus still read `.authorized` before any request
# (docs/transcribe-spike-findings.md §5). Sending an operator to toggle a
# permission that provably did not change is worse than saying nothing.
#
# What IS worth stating is the one-way door §5 does document: a *denied* grant
# never re-prompts, so it can only be undone by hand.
echo "Microphone: an existing grant survives this reinstall (measured — spike Q4)."
echo "  Only if it was previously DENIED will no prompt ever appear again; that"
echo "  case is fixed in 系统设置 → 隐私与安全性 → 麦克风, not by reinstalling."
echo ""
echo "Schema migrations (v7 / v8) run automatically on first launch; no action needed."
echo "iCloud sync state markers auto-create on first sync after install."
echo ""
echo "To verify what actually landed in /Library/Input Methods:"
echo "  codesign -dv --entitlements - '/Library/Input Methods/MarmotIM.app'"
echo "  # expect: flags=0x2(adhoc), and both com.apple.developer.icloud-* keys listed."
echo ""
echo "Deliberately NOT suggesting 'log stream' here: on this machine bare 'log' is"
echo "shadowed by a zsh function that errors out, and MarmotIM's NSLog payloads render"
echo "as <private> in the unified log regardless — an empty result would look like a"
echo "failed install when nothing is wrong. If you want the log anyway, use the"
echo "absolute path: /usr/bin/log stream --predicate 'process == \"MarmotIM\"' --info"

# Step 8: Provision the ASR server that dictation talks to.
#
# Everything above this line is done and cannot be undone by what follows — that
# ordering is the mechanism by which an ASR failure "does not fail the install",
# not merely the `if !` below.
echo ""
echo "======================================================================"
ASR_STATUS="skipped"
if [ "$WITH_ASR" -eq 0 ]; then
    echo "Input method only. Dictation needs a local ASR server, which was NOT installed."
    echo "To add it:  bash scripts/build_and_install.sh --all"
    echo "        or: bash scripts/install_asr.sh"
elif [ ! -f "scripts/install_asr.sh" ]; then
    # Not fatal for the same reason as any other ASR failure: the IME is installed.
    echo "WARNING: scripts/install_asr.sh is missing — skipping ASR provisioning." >&2
    ASR_STATUS="failed"
elif [ "$(id -u)" -eq 0 ]; then
    # `sudo bash scripts/build_and_install.sh` would otherwise install the LaunchAgent
    # into root's home and bootstrap it into root's GUI domain, where MarmotIM (running
    # as you) can never reach it — a failure that looks like a working install.
    echo "WARNING: running as root, so ASR provisioning was skipped." >&2
    echo "         Re-run without sudo: bash scripts/build_and_install.sh" >&2
    echo "         (this script sudo's only the three steps that need it)" >&2
    ASR_STATUS="failed"
else
    echo "Provisioning the ASR server (scripts/install_asr.sh)."
    echo "A first run downloads ~4 GB of model weights and can take 15-100 minutes;"
    echo "a warm run only re-checks the venv, the deps and the model and exits without"
    echo "doing any of that work. The input method above is already live either way."
    echo ""
    # `if !` rather than a bare call: under `set -e` a non-zero exit here would abort
    # the script and the operator would never see the summary telling them the IME is fine.
    if bash scripts/install_asr.sh "${ASR_ARGS[@]+"${ASR_ARGS[@]}"}"; then
        ASR_STATUS="ok"
    else
        ASR_STATUS="failed"
    fi
fi
echo "======================================================================"

# Final summary. Both halves reported in one place so the operator does not have to
# scroll back through a model download to find out whether the IME landed.
echo ""
echo "Input method: INSTALLED (/Library/Input Methods/MarmotIM.app)"
case "$ASR_STATUS" in
    ok)      echo "ASR server:   RUNNING  (loopback, launchctl gui/$UID/com.marmotim.asr)" ;;
    skipped) echo "ASR server:   NOT INSTALLED  (pass --all to provision it)" ;;
    failed)
        echo "ASR server:   FAILED — see the output above." >&2
        echo ""
        echo "  This did NOT affect the input method: typing, the dictionary and iCloud" >&2
        echo "  sync are all installed and working. Only dictation is unavailable." >&2
        echo "  Retry on its own once the cause is fixed: bash scripts/install_asr.sh" >&2
        ;;
esac

