#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

APP_DIR=".build/app/X4SyncServer.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

cp ".build/release/X4SyncServer" "$MACOS_DIR/X4SyncServer"

if [[ -f "../../dist/firmware.bin" ]]; then
  cp "../../dist/firmware.bin" "$RESOURCES_DIR/firmware.bin"
fi

PYTHON_RESOURCES="$RESOURCES_DIR/python"
ESPTOOL_PACKAGE="../../.pio/platformio-core/packages/tool-esptoolpy/esptool"
SITE_PACKAGES="$(find ../../.venv/lib -path '*/site-packages' -type d 2>/dev/null | head -n 1 || true)"

if [[ -d "$ESPTOOL_PACKAGE" ]]; then
  mkdir -p "$PYTHON_RESOURCES"
  cp -R "$ESPTOOL_PACKAGE" "$PYTHON_RESOURCES/"
fi

if [[ -n "$SITE_PACKAGES" && -d "$PYTHON_RESOURCES" ]]; then
  for package in serial click rich_click rich markdown_it mdurl pygments yaml bitstring bitarray intelhex ecdsa reedsolo; do
    if [[ -e "$SITE_PACKAGES/$package" ]]; then
      cp -R "$SITE_PACKAGES/$package" "$PYTHON_RESOURCES/"
    fi
  done
  if [[ -f "$SITE_PACKAGES/typing_extensions.py" ]]; then
    cp "$SITE_PACKAGES/typing_extensions.py" "$PYTHON_RESOURCES/"
  fi
fi

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
