#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -z "${CLANG_MODULE_CACHE_PATH:-}" ]]; then
  export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
fi
mkdir -p "$CLANG_MODULE_CACHE_PATH"

if [[ -z "${PYINSTALLER_CONFIG_DIR:-}" ]]; then
  export PYINSTALLER_CONFIG_DIR="$PWD/.build/pyinstaller-config"
fi
mkdir -p "$PYINSTALLER_CONFIG_DIR"

SWIFT_BUILD_ARGS=(-c release)
if [[ "${X4_SWIFT_DISABLE_SANDBOX:-0}" == "1" ]]; then
  SWIFT_BUILD_ARGS=(--disable-sandbox "${SWIFT_BUILD_ARGS[@]}")
fi

swift build "${SWIFT_BUILD_ARGS[@]}"

APP_DIR=".build/app/X4SyncServer.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
FLASHER_NAME="x4-flasher"
FLASHER_SCRIPT="Scripts/x4_flash_helper.py"
FLASHER_BUILD_DIR=".build/flasher"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

cp ".build/release/X4SyncServer" "$MACOS_DIR/X4SyncServer"

if [[ -f "../../dist/firmware.bin" ]]; then
  cp "../../dist/firmware.bin" "$RESOURCES_DIR/firmware.bin"
fi

PYTHON_RESOURCES="$RESOURCES_DIR/python"
ESPTOOL_PACKAGE="../../.pio/platformio-core/packages/tool-esptoolpy/esptool"
ESPTOOL_ROOT="../../.pio/platformio-core/packages/tool-esptoolpy"
SITE_PACKAGES="$(find ../../.venv/lib -path '*/site-packages' -type d 2>/dev/null | head -n 1 || true)"
PIO_PYINSTALLER="../../.pio/platformio-core/penv/bin/pyinstaller"
VENV_PYINSTALLER="../../.venv/bin/pyinstaller"
PATH_PYINSTALLER="$(command -v pyinstaller || true)"
PYINSTALLER=""

for candidate in "$PIO_PYINSTALLER" "$VENV_PYINSTALLER" "$PATH_PYINSTALLER"; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    PYINSTALLER="$candidate"
    break
  fi
done

if [[ -n "$PYINSTALLER" && -d "$ESPTOOL_PACKAGE" ]]; then
  rm -rf "$FLASHER_BUILD_DIR"
  "$PYINSTALLER" \
    --clean \
    --noconfirm \
    --onefile \
    --name "$FLASHER_NAME" \
    --distpath "$FLASHER_BUILD_DIR/dist" \
    --workpath "$FLASHER_BUILD_DIR/work" \
    --specpath "$FLASHER_BUILD_DIR/spec" \
    --paths "$ESPTOOL_ROOT" \
    --collect-all esptool \
    "$FLASHER_SCRIPT"
  cp "$FLASHER_BUILD_DIR/dist/$FLASHER_NAME" "$RESOURCES_DIR/$FLASHER_NAME"
  chmod 755 "$RESOURCES_DIR/$FLASHER_NAME"
fi

if [[ ! -x "$RESOURCES_DIR/$FLASHER_NAME" ]]; then
  echo "warning: standalone $FLASHER_NAME was not built; falling back to bundled Python esptool resources" >&2
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
