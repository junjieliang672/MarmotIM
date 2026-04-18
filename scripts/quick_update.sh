#!/bin/bash
# Quick update script - no logout required.
# Rebuilds the dictionary from vocab/, compiles the app, reinstalls it, and
# relaunches the input method. Usage: bash scripts/quick_update.sh
#
# What this script DOES modify:
#   - dict/dictionary.db       (rebuilt from vocab/ source)
#   - build/**                 (xcodebuild output)
#   - /Library/Input Methods/MarmotIM.app  (sudo cp + codesign)
#
# What this script does NOT touch (safe across updates):
#   - ~/Library/Application Support/MarmotIM/dictionary.db  (user data)
#   - ~/Library/Application Support/MarmotIM/config.json    (user settings)
#   - ~/Library/Application Support/MarmotIM/.marmotim.sync-state.*  (sync markers, spec-004)
#   - ~/Library/Mobile Documents/iCloud~com~marmotim~.../  (iCloud state)
#
# Schema migrations (v6 → v7 from spec-001, v7 → v8 from spec-003) run automatically
# in VocabularyDatabase.performMigrations() at app launch — no script action needed.

set -e
set -o pipefail   # so `xcodebuild | grep` propagates xcodebuild's exit code
cd "$(dirname "$0")/.."

# Step 1: Rebuild dictionary from vocab sources.
# This regenerates dict/dictionary.db which gets bundled into the .app in step 4.
# User data at ~/Library/Application Support/MarmotIM/dictionary.db is NOT modified.
echo "Building dictionary..."
python3 tools/build_dictionary.py
echo ""

# Hard-fail if the Python build didn't produce the expected artifact. On a fresh
# clone this is the difference between "new IME has a working dictionary" and
# "user has no words." (spec-004 quick_update.sh hardening)
if [ ! -f "dict/dictionary.db" ]; then
    echo "ERROR: dict/dictionary.db was not produced by tools/build_dictionary.py." >&2
    echo "       Check the Python output above for errors. Cannot proceed." >&2
    exit 1
fi

# Step 2: Build the app. We filter xcodebuild's output for readability, but
# pipefail + set -e ensure a real failure still aborts here (previously masked).
echo "Building app..."
xcodebuild -project MarmotIM.xcodeproj -scheme MarmotIM -configuration Release build CONFIGURATION_BUILD_DIR="$(pwd)/build" 2>&1 | grep -E "(error:|BUILD)" | tail -5

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
fi

echo "Done! Input method updated."
echo ""
echo "Schema migrations (v7 / v8) run automatically on first launch; no action needed."
echo "iCloud sync state markers auto-create on first sync after install."
echo ""
echo "To verify the new binary is live, type anywhere and then:"
echo "  log stream --predicate 'process == \"MarmotIM\"' --info | head -20"
