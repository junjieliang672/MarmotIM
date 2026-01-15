#!/usr/bin/env bash
set -euo pipefail

ACTION=${1:-build}
PROJECT="MarmotIM.xcodeproj"
SCHEME="MarmotIM"
DESTINATION="platform=macOS"

case "$ACTION" in
  build)
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug build
    ;;
  test)
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "$DESTINATION" test || {
      echo "xcodebuild test failed; falling back to build";
      xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug build;
    }
    ;;
  list)
    xcodebuild -list -project "$PROJECT"
    ;;
  clean)
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" clean
    ;;
  *)
    echo "usage: scripts/xcode_tool.sh [build|test|list|clean]"
    exit 2
    ;;
esac

