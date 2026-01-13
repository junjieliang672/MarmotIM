#!/bin/bash
# MarmotIM Clean Installation Script
# This script completely removes old installations and installs fresh
#
# Usage:
#   ./scripts/clean_install.sh              # Build with iCloud (requires Apple Developer account)
#   ./scripts/clean_install.sh --no-icloud  # Build without iCloud (no developer account needed)

set -e

# Parse arguments
NO_ICLOUD=false
for arg in "$@"; do
    case $arg in
        --no-icloud)
            NO_ICLOUD=true
            shift
            ;;
    esac
done

echo "=== MarmotIM Clean Installation ==="
if [ "$NO_ICLOUD" = true ]; then
    echo "Mode: No iCloud (ad-hoc signing)"
else
    echo "Mode: With iCloud (requires Apple Developer account)"
fi
echo ""

# Step 1: Graceful shutdown
echo "Step 1: Stopping MarmotIM gracefully..."
# Send SIGTERM first to allow proper cleanup (WAL checkpoint, etc.)
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
        echo "   Force stopping..."
        killall -KILL MarmotIM 2>/dev/null || true
        sleep 0.5
    fi
fi

# Step 2: Remove all installations
echo "Step 2: Removing old installations..."
rm -rf ~/Library/Input\ Methods/MarmotIM.app 2>/dev/null || true
rm -rf ~/Library/Input\ Methods/MarmotIM.app 2>/dev/null || true
sudo rm -rf /Library/Input\ Methods/MarmotIM.app 2>/dev/null || true
sudo rm -rf /Library/Input\ Methods/MarmotIM.app 2>/dev/null || true

# Step 3: Clear all caches
echo "Step 3: Clearing caches..."
rm -rf ~/Library/Caches/com.apple.InputMethodKit* 2>/dev/null || true
rm -rf ~/Library/Caches/com.apple.HIToolbox* 2>/dev/null || true

# Step 4: Reset LaunchServices database (this clears ghost entries)
echo "Step 4: Resetting LaunchServices database..."
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -kill -r -domain local -domain system -domain user 2>/dev/null || true

# Step 5: Restart preference daemons
echo "Step 5: Restarting system daemons..."
killall -HUP cfprefsd 2>/dev/null || true
killall -HUP SystemUIServer 2>/dev/null || true
sleep 2

# Step 6: Build fresh (if source available)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [ -f "$PROJECT_DIR/MarmotIM.xcodeproj/project.pbxproj" ]; then
    echo "Step 6: Building fresh from source..."
    cd "$PROJECT_DIR"

    if [ "$NO_ICLOUD" = true ]; then
        # Build without iCloud entitlements
        xcodebuild -project MarmotIM.xcodeproj \
            -scheme MarmotIM \
            -configuration Release \
            build \
            CONFIGURATION_BUILD_DIR="$PROJECT_DIR/build" \
            CODE_SIGN_IDENTITY="-" \
            CODE_SIGN_ENTITLEMENTS="" \
            2>/dev/null | grep -E "(BUILD|error:)" || true
    else
        # Build with iCloud
        xcodebuild -project MarmotIM.xcodeproj \
            -scheme MarmotIM \
            -configuration Release \
            build \
            CONFIGURATION_BUILD_DIR="$PROJECT_DIR/build" \
            2>/dev/null | grep -E "(BUILD|error:)" || true
    fi
fi

# Step 7: Install
echo "Step 7: Installing MarmotIM..."
if [ -d "$PROJECT_DIR/build/MarmotIM.app" ]; then
    sudo cp -r "$PROJECT_DIR/build/MarmotIM.app" /Library/Input\ Methods/MarmotIM.app
    sudo codesign --force --deep --sign - /Library/Input\ Methods/MarmotIM.app
    echo "   Installed to /Library/Input Methods/MarmotIM.app"
else
    echo "   ERROR: Build not found at $PROJECT_DIR/build/MarmotIM.app"
    if [ "$NO_ICLOUD" = false ]; then
        echo ""
        echo "   Hint: If you don't have an Apple Developer account, try:"
        echo "   ./scripts/clean_install.sh --no-icloud"
    fi
    exit 1
fi

# Step 8: Register fresh
echo "Step 8: Registering with LaunchServices..."
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f /Library/Input\ Methods/MarmotIM.app

# Step 9: Setup dictionary
echo "Step 9: Setting up dictionary..."
mkdir -p ~/Library/Application\ Support/MarmotIM/dict
if [ -f "$PROJECT_DIR/dict/entries.json" ]; then
    cp "$PROJECT_DIR/dict/entries.json" ~/Library/Application\ Support/MarmotIM/dict/
    echo "   Dictionary copied"
fi

echo ""
echo "=== Installation Complete ==="
echo ""
if [ "$NO_ICLOUD" = true ]; then
    echo "Note: iCloud sync is DISABLED in this build."
    echo "      To enable iCloud sync, you need an Apple Developer account."
    echo ""
fi
echo "IMPORTANT: You MUST log out and log back in (or restart) for changes to take effect!"
echo "The ghost entries will disappear after re-login."
echo ""
