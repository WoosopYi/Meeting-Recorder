#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP_NAME="${MEETING_RECORDER_APP_NAME:-MeetingRecorder}"
BUNDLE_ID="${MEETING_RECORDER_BUNDLE_ID:-com.woosopyi.MeetingRecorder}"
VERSION="${MEETING_RECORDER_VERSION:-0.1.0}"

DIST_DIR="$REPO_ROOT/dist"
APP_DIR="$DIST_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "Building release binary..."
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
SRC_BIN="$BIN_DIR/meeting-vault-app"

if [[ ! -f "$SRC_BIN" ]]; then
  echo "Missing built binary: $SRC_BIN" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$SRC_BIN" "$MACOS_DIR/meeting-vault-app"
chmod +x "$MACOS_DIR/meeting-vault-app"

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>meeting-vault-app</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>

  <!-- Menu bar only (no Dock icon) -->
  <key>LSUIElement</key>
  <true/>

  <!-- Required for mic permission prompt -->
  <key>NSMicrophoneUsageDescription</key>
  <string>MeetingRecorder needs microphone access to record meetings.</string>

  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null || true
fi

if command -v codesign >/dev/null 2>&1; then
  # Ad-hoc sign for local running convenience.
  codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "Built .app: $APP_DIR"
echo "Tip: move it to /Applications and run by double-click." 

open "$APP_DIR" >/dev/null 2>&1 || true
