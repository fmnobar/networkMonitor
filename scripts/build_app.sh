#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/NetworkMonitorApp.xcodeproj"
SCHEME="NetworkMonitor"
DERIVED_DATA_PATH="$ROOT_DIR/.build/xcode"
CONFIGURATION="Debug"
SHOULD_OPEN=0
PRINT_APP_PATH=0
SMOKE_UI=0

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
    --smoke-ui)
      SMOKE_UI=1
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

if [[ $SMOKE_UI -eq 1 ]]; then
  pkill -x NetworkMonitor 2>/dev/null || true
  sleep 0.5
  open -n "$APP_PATH" --args --debug-open-dashboard --debug-show-preview
elif [[ $SHOULD_OPEN -eq 1 ]]; then
  open "$APP_PATH"
fi
