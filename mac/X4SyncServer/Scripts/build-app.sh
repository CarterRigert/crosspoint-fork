#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

APP_DIR=".build/app/X4SyncServer.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"

cp ".build/release/X4SyncServer" "$MACOS_DIR/X4SyncServer"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>X4SyncServer</string>
  <key>CFBundleIdentifier</key>
  <string>com.crosspoint.x4syncserver</string>
  <key>CFBundleName</key>
  <string>X4 Sync Server</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "Built $APP_DIR"
