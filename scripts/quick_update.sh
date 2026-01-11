#!/bin/bash
# Quick update script - no logout required
# Usage: bash scripts/quick_update.sh

set -e
cd "$(dirname "$0")/.."

echo "Building..."
xcodebuild -project MarmotIM.xcodeproj -scheme MarmotIM -configuration Release build CONFIGURATION_BUILD_DIR="$(pwd)/build" 2>&1 | grep -E "(error:|BUILD)" | tail -5

if [ ! -d "build/MarmotIM.app" ]; then
    echo "Build failed!"
    exit 1
fi

echo "Stopping old process..."
pkill -f MarmotIM 2>/dev/null || true
sleep 1

echo "Installing..."
sudo rm -rf /Library/Input\ Methods/MarmotIM.app
sudo cp -r build/MarmotIM.app /Library/Input\ Methods/MarmotIM.app
sudo codesign --force --deep --sign - /Library/Input\ Methods/MarmotIM.app

echo "Starting..."
open /Library/Input\ Methods/MarmotIM.app

echo "Done! Input method updated."
