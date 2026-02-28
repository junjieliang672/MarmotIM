#!/bin/bash
# Quick update script - no logout required
# Rebuilds dictionary, compiles app, and restarts the input method.
# Usage: bash scripts/quick_update.sh

set -e
cd "$(dirname "$0")/.."

# Step 1: Rebuild dictionary from vocab sources
# This ensures the database schema always matches the code.
# --install copies to ~/Library/Application Support/MarmotIM/ (preserves user data)
echo "Building dictionary..."
python3 tools/build_dictionary.py
echo ""

# Step 2: Build the app
echo "Building app..."
xcodebuild -project MarmotIM.xcodeproj -scheme MarmotIM -configuration Release build CONFIGURATION_BUILD_DIR="$(pwd)/build" 2>&1 | grep -E "(error:|BUILD)" | tail -5

if [ ! -d "build/MarmotIM.app" ]; then
    echo "Build failed!"
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

# Step 4: Inject dictionary.db into the App Bundle
# This is required because dictionary.db is not in the Xcode project Resources phase
echo "Injecting dictionary.db into App Bundle..."
if [ -f "dict/dictionary.db" ]; then
    mkdir -p "build/MarmotIM.app/Contents/Resources"
    cp -f "dict/dictionary.db" "build/MarmotIM.app/Contents/Resources/"
else
    echo "WARNING: dict/dictionary.db not found! App will run with empty/stale dictionary."
fi

# Step 5: Install app to /Library/Input Methods
echo "Installing..."
sudo rm -rf /Library/Input\ Methods/MarmotIM.app
sudo cp -r build/MarmotIM.app /Library/Input\ Methods/MarmotIM.app
sudo codesign --force --deep --sign - /Library/Input\ Methods/MarmotIM.app

# Step 6: Start
echo "Starting..."
open /Library/Input\ Methods/MarmotIM.app

echo "Done! Input method updated."
