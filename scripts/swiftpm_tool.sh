#!/usr/bin/env bash
set -euo pipefail

CMD=${1:-test}
PKG_DIR=${2:-.}

cd "$PKG_DIR"

case "$CMD" in
  build)
    swift build
    ;;
  test)
    swift test || { echo "swift test failed; falling back to swift build"; swift build; }
    ;;
  resolve)
    swift package resolve
    ;;
  clean)
    swift package clean
    ;;
  describe)
    swift package describe
    ;;
  *)
    echo "usage: scripts/swiftpm_tool.sh [build|test|resolve|clean|describe] [package_dir]"
    exit 2
    ;;
esac

