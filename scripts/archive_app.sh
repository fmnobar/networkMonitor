#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/NetworkMonitorApp.xcodeproj"
SCHEME="NetworkMonitor"
DERIVED_DATA_PATH="$ROOT_DIR/.build/xcode"
ARCHIVE_PATH="$ROOT_DIR/.build/archives/NetworkMonitor.xcarchive"

mkdir -p "$(dirname "$ARCHIVE_PATH")"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  archive

printf 'Archive created at %s\n' "$ARCHIVE_PATH"
