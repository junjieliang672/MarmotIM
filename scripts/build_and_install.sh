#!/bin/bash
# Build and install MarmotIM - no logout required.
# Rebuilds the dictionary from vocab/, compiles the app, reinstalls it, and
# relaunches the input method. With --all it also provisions the local ASR
# server that dictation talks to.
#
# Renamed from scripts/quick_update.sh. That name survived for a while as a thin
# forwarding shim; it was deleted on 2026-08-13 once the new name had settled.
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
#   - /Library/Input Methods/MarmotIM.app  (sudo cp; the bundle keeps Xcode's signature)
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

# Step 2b: Locate the entitlements XCODE generated for this build.
#
# `MarmotIM/MarmotIM.entitlements` is the SOURCE. `MarmotIM.app.xcent` is the PRODUCT:
# Xcode merges the source file with the provisioning profile and the base entitlements
# (CODE_SIGN_INJECT_BASE_ENTITLEMENTS) and signs with the RESULT, which additionally
# carries com.apple.application-identifier, com.apple.developer.team-identifier and
# com.apple.security.get-task-allow. Step 4b re-signs, so it must use the same product —
# see the long note there for what signing from the source file cost us.
#
# Resolved from build settings rather than hardcoded: the DerivedData directory name is a
# hash, and `-derivedDataPath` can move the whole tree. TARGET_TEMP_DIR + FULL_PRODUCT_NAME
# is where ProcessProductPackaging always writes it.
echo "Locating Xcode's generated entitlements..."
BUILD_SETTINGS=$(xcodebuild -project MarmotIM.xcodeproj -scheme MarmotIM \
    -configuration Release -showBuildSettings 2>/dev/null)
_setting() { printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' -v k="$1" '$1 ~ "^ *"k"$" {print $2; exit}'; }
XCENT="$(_setting TARGET_TEMP_DIR)/$(_setting FULL_PRODUCT_NAME).xcent"

# Both checks run BEFORE the first sudo, so a broken signing configuration cannot get as
# far as touching /Library/Input Methods.
if [ ! -f "$XCENT" ]; then
    echo "ERROR: Xcode's generated entitlements (.xcent) were not found at:" >&2
    echo "       $XCENT" >&2
    echo "       A signed Release build always produces it, so signing was probably" >&2
    echo "       disabled for this build. With no entitlements there is no iCloud sync;" >&2
    echo "       if that is what you want, use scripts/build.sh --no-icloud instead." >&2
    exit 1
fi
# NOTE: `plutil -extract` reads the key as a KEY PATH, so the dots must be escaped or it
# reports a present key as missing. An unescaped probe here would be a false alarm that
# aborts every install.
if ! plutil -extract 'com\.apple\.application-identifier' raw -o - "$XCENT" > /dev/null 2>&1; then
    echo "ERROR: $XCENT has no com.apple.application-identifier." >&2
    echo "       iCloud Drive is refused at runtime without it, so installing this would" >&2
    echo "       ship broken sync. The signing configuration changed — fix that rather" >&2
    echo "       than relaxing this check." >&2
    exit 1
fi
echo "  $XCENT"

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

# Step 4b: Re-seal the bundle, AS YOU, BEFORE it is installed.
#
# Two separate reasons this sits here and not after the install:
#
# 1. The injection above modified a signed bundle, so its seal is now broken:
#      a sealed resource is missing or invalid
#      file modified: .../Contents/Resources/dictionary.db
#    Xcode signs at the end of its build; the dictionary lands afterwards. The old
#    ad-hoc `--sign -` was silently re-sealing this too — that, not habit alone, is
#    why a re-sign existed here at all. (Observed 2026-08-13 by removing it: the
#    installed bundle failed verification.)
#
# 2. Signing MUST NOT run under sudo. The identity's private key lives in YOUR login
#    keychain, which root cannot read, so `sudo codesign` fails with:
#      Warning: unable to build chain to self-signed root for signer "Apple Development: …"
#      errSecInternalComponent
#    (Also observed 2026-08-13, one round after the seal problem.) Signing before the
#    install sidesteps it entirely: `sudo cp -r` preserves the signature, so root only
#    ever copies an already-valid bundle instead of trying to produce one.
#
# Everything Xcode put on the signature has to be restated, because `--force --sign`
# replaces it wholesale:
#   --entitlements  entitlements are DROPPED otherwise. This is what the 2026-08-12
#                   note found impossible on the ad-hoc path: the restricted iCloud keys
#                   need a provisioning profile, and a real identity has one. The profile
#                   itself (Contents/embedded.provisionprofile) survives untouched.
#   -o runtime      hardened runtime is NOT inherited. Dropping it would silently undo
#                   the microphone entitlement's reason for existing.
# `--deep` is deliberately absent: Apple discourages it for signing, and there are no
# nested binaries here — the failure it would paper over is one worth seeing.
#
# THE ENTITLEMENTS COME FROM $XCENT, NOT FROM MarmotIM/MarmotIM.entitlements. (2026-08-13)
#
# Signing from the source file is what the first version of this step did, and it KILLED
# iCLOUD SYNC. The source file lists 3 keys; Xcode's product lists 6, and the three it adds
# — com.apple.application-identifier, com.apple.developer.team-identifier,
# com.apple.security.get-task-allow — were silently dropped on every install. Measured
# consequence, straight out of the unified log:
#
#   (CloudDocs) [ERROR] **** bundle <pid> is lacking the 'com.apple.application-identifier'
#   entitlement which is required to use iCloud Drive ****
#
# The app kept writing its five JSON files into the container directory and looked healthy,
# because writing into ~/Library/Mobile Documents is just file I/O for a non-sandboxed
# process — but the daemon refuses to sync for a process without that entitlement. Every
# check this script had still passed: `codesign --verify --strict` was happy, and the
# team-identifier check was happy too (the SIGNATURE has a team; the ENTITLEMENTS did not).
# That is why the post-install check below now compares the whole entitlement set.
#
# Rejected alternatives, each of which looks simpler and is worse:
#   · `--preserve-metadata=entitlements`, or dumping the set out of build/MarmotIM.app.
#     Both re-use whatever is already ON the bundle, which after one bad run is our own
#     degraded set. When Xcode's CodeSign task is up-to-date it does not re-run, so nothing
#     would ever correct it: this would have FROZEN the bug while appearing to fix it.
#   · Hand-adding the two keys to MarmotIM.entitlements. That hardcodes team 6R7CZ58K47
#     into a checked-in file and fixes only the keys we happen to know about today — the
#     same failure again, one generation later.
#
# get-task-allow rides along deliberately: development identity, development profile,
# development install, and it is what lets lldb attach under hardened runtime. It must
# never reach a notarized build — that is scripts/release.sh's path, not this one.
#
# Note the .xcent lives in DerivedData, OUTSIDE the bundle, so step 4's dictionary
# injection cannot contaminate it. That is precisely what keeps inject-then-sign safe.
SIGN_IDENTITY="${MARMOT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)}"
if [ -z "$SIGN_IDENTITY" ]; then
    echo "ERROR: no Apple Development codesigning identity found." >&2
    echo "       Sign in to Xcode with the Apple ID that owns team 6R7CZ58K47, or set" >&2
    echo "       MARMOT_SIGN_IDENTITY to the identity to use. Without a real identity," >&2
    echo "       use scripts/build.sh --no-icloud instead of this script." >&2
    exit 1
fi
echo "Re-sealing the bundle as: $SIGN_IDENTITY"
codesign --force --sign "$SIGN_IDENTITY" \
    --entitlements "$XCENT" \
    -o runtime \
    build/MarmotIM.app || {
    echo "ERROR: re-signing build/MarmotIM.app failed — see the output above." >&2
    echo "       If this is 'errSecInternalComponent', something re-introduced sudo on" >&2
    echo "       this call: the signing key is in your login keychain, not root's." >&2
    exit 1
}

# Step 5: Install app to /Library/Input Methods
echo "Installing..."
sudo rm -rf /Library/Input\ Methods/MarmotIM.app
sudo cp -r build/MarmotIM.app /Library/Input\ Methods/MarmotIM.app

# WHY THE SIGNATURE ABOVE IS A REAL IDENTITY AND NOT AD-HOC. (2026-08-13)
#
# This step used to run `sudo codesign --force --deep --sign -`, replacing Xcode's
# Team-ID signature with an ad-hoc one. That single line made the ACCESSIBILITY
# PERMISSION IMPOSSIBLE TO KEEP, which is what finally forced the change:
#
#   An ad-hoc signature has no team identifier (`flags=0x2(adhoc)`,
#   `TeamIdentifier=not set`), so TCC can only pin the grant to that build's
#   cdhash — and `--force --sign -` mints a NEW cdhash on every install. The
#   grant you gave yesterday no longer matches the binary installed today.
#   The symptom is maximally confusing: System Settings still shows MarmotIM
#   ticked under 辅助功能, while `AXIsProcessTrusted()` returns false in the
#   running process, so 听写 silently does nothing outside the IME path.
#   Measured 2026-08-13: grant recorded 21:27:54, reinstall at 21:33:14, and the
#   settings page went back to 未授权 with the tick still showing in System Settings.
#
# Signed with a real identity the grant is pinned to `6R7CZ58K47` + the bundle id, both
# stable across rebuilds, so it survives every reinstall. Same for the microphone.
#
# On the two warnings the old comment left here, both of which were correct about
# the ad-hoc path and neither of which applies now:
#
#  · Restricted iCloud entitlements. `…icloud-container-identifiers` and
#    `…ubiquity-container-…` DO need a real provisioning profile — which is exactly
#    what the Xcode build produces (`Contents/embedded.provisionprofile`). It was the
#    ad-hoc re-sign that could not carry them, not this bundle.
#  · Hardened runtime. Xcode's signature has `flags=0x10000(runtime)`, which the
#    ad-hoc re-sign stripped, and it does start enforcing entitlement-gated
#    capabilities. The one this app actually uses is the microphone, so
#    `com.apple.security.device.audio-input` was added to MarmotIM.entitlements
#    in the same change. That entitlement is unrestricted and the app is not
#    sandboxed, so it needs nothing from the developer account.
#
# If you ever DO need the ad-hoc path back (no Apple account on the machine), use
# scripts/build.sh --no-icloud, which drops the entitlements that require a profile
# in the first place — and accept that Accessibility will not stick across installs.
#
# Verify rather than assume: an unsigned or broken bundle here fails to launch with
# `Launchd job spawn failed`, and a missing team identifier silently reintroduces the
# permission bug above. Both are cheap to check and expensive to discover by hand.
#
# Verification needs no sudo — /Library/Input Methods is world-readable, and unlike
# signing it does not touch a keychain. Checking the INSTALLED copy rather than the
# one we just signed is the point: it is the only thing that proves `sudo cp -r`
# preserved the signature.
if ! codesign --verify --strict /Library/Input\ Methods/MarmotIM.app 2>/dev/null; then
    echo "ERROR: the installed bundle failed signature verification." >&2
    echo "       The copy did not preserve the signature, or something modified the" >&2
    echo "       bundle after step 4b re-sealed it." >&2
    exit 1
fi
INSTALLED_TEAM=$(codesign -dv /Library/Input\ Methods/MarmotIM.app 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [ -z "$INSTALLED_TEAM" ] || [ "$INSTALLED_TEAM" = "not set" ]; then
    echo "WARNING: the installed bundle has no team identifier." >&2
    echo "         Accessibility and microphone grants will NOT survive the next install:" >&2
    echo "         TCC can only pin them to this build's cdhash. See the comment above." >&2
else
    echo "OK: signed by team $INSTALLED_TEAM (permissions survive reinstalls)."
fi

# ENTITLEMENTS: two checks, on purpose.
#
# The team-identifier check above is about the SIGNATURE and says nothing about the
# entitlements — it passed happily throughout the window where iCloud sync was dead.
# So: one named check that can explain itself, and one wholesale check that catches
# whatever we have not thought of.
INSTALLED_ENTS=$(codesign -d --entitlements - --xml /Library/Input\ Methods/MarmotIM.app 2>/dev/null)

# 1. The specific key iCloud Drive refuses to work without. Dots escaped — see the note
#    in step 2b; an unescaped key path reports a present key as missing.
INSTALLED_APPID=$(printf '%s' "$INSTALLED_ENTS" \
    | plutil -extract 'com\.apple\.application-identifier' raw -o - - 2>/dev/null || true)
if [ -z "$INSTALLED_APPID" ]; then
    echo "ERROR: the installed bundle has NO com.apple.application-identifier entitlement." >&2
    echo "       iCloud Drive is refused without it, and the failure is SILENT: the app" >&2
    echo "       keeps writing its JSON files into the container and looks healthy while" >&2
    echo "       nothing ever reaches the cloud. The unified log is where it shows up:" >&2
    echo "         (CloudDocs) [ERROR] **** bundle <pid> is lacking the" >&2
    echo "         'com.apple.application-identifier' entitlement ... ****" >&2
    echo "       Cause has always been the same: step 4b signed with the hand-maintained" >&2
    echo "       MarmotIM/MarmotIM.entitlements instead of Xcode's generated .xcent." >&2
    exit 1
fi

# 2. The whole set must match what Xcode produced — not merely contain the one key that
#    burned us. This is the check that makes a FUTURE key going missing impossible.
#    `plutil -convert xml1` normalises ordering and formatting, so comparing the two
#    canonical forms as strings is meaningful.
XCENT_CANON=$(plutil -convert xml1 -o - "$XCENT" 2>/dev/null)
INSTALLED_CANON=$(printf '%s' "$INSTALLED_ENTS" | plutil -convert xml1 -o - - 2>/dev/null)
if [ "$XCENT_CANON" != "$INSTALLED_CANON" ]; then
    echo "ERROR: the installed entitlements differ from the ones Xcode generated." >&2
    echo "       Left = Xcode's .xcent, right = what actually got installed:" >&2
    diff <(printf '%s\n' "$XCENT_CANON") <(printf '%s\n' "$INSTALLED_CANON") >&2 || true
    exit 1
fi
echo "OK: entitlements match Xcode's .xcent exactly (application-identifier = $INSTALLED_APPID)."

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
echo "  # expect: TeamIdentifier=6R7CZ58K47, flags=0x10000(runtime), and SIX entitlements:"
echo "  #   com.apple.application-identifier        <- no iCloud Drive without it"
echo "  #   com.apple.developer.team-identifier"
echo "  #   com.apple.developer.icloud-container-identifiers"
echo "  #   com.apple.developer.ubiquity-container-identifiers"
echo "  #   com.apple.security.device.audio-input   <- microphone under hardened runtime"
echo "  #   com.apple.security.get-task-allow       <- dev build only; never notarize this"
echo "  # A 'not set' team identifier means the ad-hoc re-sign came back and"
echo "  # Accessibility / microphone grants will break on the next install."
echo "  # Only three entitlements means sync is dead — that exact set is what the"
echo "  # hand-maintained MarmotIM.entitlements produces. See step 4b."
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
    # Report what IS, not what this run did.
    #
    # This branch used to print "Dictation needs a local ASR server, which was NOT
    # installed" and then tell you to run --all — to everyone, including people whose
    # server was installed, loaded and answering. Telling someone to install what they
    # already have is worse than saying nothing: it reads as a regression the script
    # just caused, and the suggested remedy re-runs a 4 GB provisioning path for no
    # reason. "This run did not touch it" and "it is not there" are different claims,
    # and only the second one warrants that advice.
    #
    # Cheap enough to always check: a plist read and one loopback request with a short
    # timeout. Neither can start anything, so this stays a pure observation — the
    # opt-in property of ASR provisioning is unaffected.
    ASR_PLIST="$HOME/Library/LaunchAgents/com.marmotim.asr.plist"
    if [ -f "$ASR_PLIST" ]; then
        ASR_PORT="$(plutil -extract EnvironmentVariables.MARMOT_ASR_PORT raw -o - "$ASR_PLIST" 2>/dev/null || echo "")"
        if [ -n "$ASR_PORT" ] && curl -fsS --max-time 2 "http://127.0.0.1:$ASR_PORT/health" > /dev/null 2>&1; then
            echo "Input method only — the ASR server was left alone (it is installed and answering"
            echo "on 127.0.0.1:$ASR_PORT). Dictation keeps working; nothing to do."
            ASR_STATUS="untouched"
        else
            echo "Input method only — the ASR server was left alone. It is installed, but it is"
            echo "NOT answering right now, so dictation will fail until it is back."
            echo "To bring it up:  bash scripts/install_asr.sh"
            ASR_STATUS="untouched-down"
        fi
    else
        echo "Input method only. Dictation needs a local ASR server, which is NOT installed."
        echo "To add it:  bash scripts/build_and_install.sh --all"
        echo "        or: bash scripts/install_asr.sh"
    fi
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
    # Three outcomes, not one: this run provisioned nothing in all three, but the state
    # it declined to touch is different in each, and so is what the operator should do.
    untouched)      echo "ASR server:   RUNNING  (untouched by this run)" ;;
    untouched-down) echo "ASR server:   INSTALLED BUT NOT ANSWERING  (bash scripts/install_asr.sh)" ;;
    skipped)        echo "ASR server:   NOT INSTALLED  (pass --all to provision it)" ;;
    failed)
        echo "ASR server:   FAILED — see the output above." >&2
        echo ""
        echo "  This did NOT affect the input method: typing, the dictionary and iCloud" >&2
        echo "  sync are all installed and working. Only dictation is unavailable." >&2
        echo "  Retry on its own once the cause is fixed: bash scripts/install_asr.sh" >&2
        ;;
esac

