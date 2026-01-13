#!/bin/bash
# Build and install MarmotIM
#
# Usage:
#   ./scripts/build.sh              # Build with iCloud (requires Apple Developer account)
#   ./scripts/build.sh --no-icloud  # Build without iCloud (no developer account needed)
#
set -e

# Get project directory (relative to script location)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
SCHEME="MarmotIM"
APP_NAME="MarmotIM"
INSTALL_DIR="/Library/Input Methods"

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

echo "========================================"
echo "MarmotIM Build & Install"
echo "========================================"
if [ "$NO_ICLOUD" = true ]; then
    echo "Mode: No iCloud (ad-hoc signing)"
else
    echo "Mode: With iCloud (requires Apple Developer account)"
fi
echo ""

# ========================================
# Step 1: Build
# ========================================
echo "[1/4] Building MarmotIM..."

# Clean build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Build with xcodebuild
if [ "$NO_ICLOUD" = true ]; then
    # Build without iCloud entitlements - works with ad-hoc signing
    xcodebuild \
        -project "$PROJECT_DIR/MarmotIM.xcodeproj" \
        -scheme "$SCHEME" \
        -configuration Release \
        -derivedDataPath "$BUILD_DIR/DerivedData" \
        CONFIGURATION_BUILD_DIR="$BUILD_DIR/Release" \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGN_ENTITLEMENTS="" \
        build 2>&1 | grep -E "(error:|warning:|BUILD)" | tail -20
else
    # Build with iCloud - requires Apple Developer certificate
    xcodebuild \
        -project "$PROJECT_DIR/MarmotIM.xcodeproj" \
        -scheme "$SCHEME" \
        -configuration Release \
        -derivedDataPath "$BUILD_DIR/DerivedData" \
        CONFIGURATION_BUILD_DIR="$BUILD_DIR/Release" \
        build 2>&1 | grep -E "(error:|warning:|BUILD)" | tail -20
fi

APP_PATH="$BUILD_DIR/Release/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
    echo ""
    echo "Error: Build failed - app not found"
    if [ "$NO_ICLOUD" = false ]; then
        echo ""
        echo "Hint: If you don't have an Apple Developer account, try:"
        echo "  ./scripts/build.sh --no-icloud"
    fi
    exit 1
fi

echo "Build completed."
echo ""

# ========================================
# Step 2: Stop old process
# ========================================
echo "[2/4] Stopping old process..."

# Graceful shutdown: send SIGTERM first to allow proper cleanup (WAL checkpoint, etc.)
if pgrep -f "$APP_NAME" > /dev/null 2>&1; then
    killall -TERM "$APP_NAME" 2>/dev/null || true
    # Wait for graceful shutdown (up to 3 seconds)
    for i in {1..6}; do
        if ! pgrep -f "$APP_NAME" > /dev/null 2>&1; then
            break
        fi
        sleep 0.5
    done
    # Force kill if still running
    if pgrep -f "$APP_NAME" > /dev/null 2>&1; then
        echo "  Force stopping..."
        killall -KILL "$APP_NAME" 2>/dev/null || true
        sleep 0.5
    fi
fi

echo "Done."
echo ""

# ========================================
# Step 3: Install
# ========================================
echo "[3/4] Installing to $INSTALL_DIR..."

# Remove old installation
sudo rm -rf "$INSTALL_DIR/$APP_NAME.app"

# Copy new app
sudo cp -R "$APP_PATH" "$INSTALL_DIR/$APP_NAME.app"

# Sign with ad-hoc signature for local use
sudo codesign --force --deep --sign - "$INSTALL_DIR/$APP_NAME.app"

echo "Installed."
echo ""

# ========================================
# Step 4: Register and launch
# ========================================
echo "[4/4] Registering input method..."

# Register with LaunchServices
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null || true

# Launch the input method
open "$INSTALL_DIR/$APP_NAME.app"

echo "Done."
echo ""

echo "========================================"
echo "Installation Complete!"
echo "========================================"
echo ""
if [ "$NO_ICLOUD" = true ]; then
    echo "Note: iCloud sync is DISABLED in this build."
    echo "      To enable iCloud sync, you need an Apple Developer account."
    echo ""
fi
echo "Next steps:"
echo "  1. Open System Settings > Keyboard > Input Sources"
echo "  2. Click '+' and add 'MarmotIM' (under Chinese)"
echo "  3. Select MarmotIM from the menu bar to use"
echo ""
echo "If MarmotIM doesn't appear in the list:"
echo "  - Log out and log back in, then try again"
echo ""
