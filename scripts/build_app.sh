#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/NetworkMonitorApp.xcodeproj"
SCHEME="NetworkMonitor"
DERIVED_DATA_PATH="$ROOT_DIR/.build/xcode"
CONFIGURATION="Debug"
SHOULD_OPEN=0
PRINT_APP_PATH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--configuration)
      CONFIGURATION="${2:-}"
      shift 2
      ;;
    --open)
      SHOULD_OPEN=1
      shift
      ;;
    --print-app-path)
      PRINT_APP_PATH=1
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/NetworkMonitor.app"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ $PRINT_APP_PATH -eq 1 ]]; then
  printf '%s\n' "$APP_PATH"
fi

if [[ $SHOULD_OPEN -eq 1 ]]; then
  open "$APP_PATH"
fi
