# CrossPoint X4 Startup Sync Fork

This fork adds a minimal startup sync proof of concept to CrossPoint Reader for the XTEINK X4.

On startup or wake, CrossPoint now:

- skips sync when `startupSyncServerUrl` is blank
- connects to the last saved Wi-Fi network
- fetches `{startupSyncServerUrl}/manifest.json`
- downloads up to eight files listed in the manifest
- writes it to a temporary SD-card file first, then promotes it to the final path
- logs `Sync skipped`, `Sync OK`, or `Sync failed`

The X4 only pulls finished files from your local server. The native macOS helper in `mac/X4SyncServer` can generate and serve `/sleep.bmp` and `/HNLatest.epub`.

## Ready-Built Downloads

If you only want to install and run this fork, use the files in `dist/`:

- `dist/firmware.bin` - flash this to the X4 with the CrossPoint web flasher's `Custom .bin` option.
- `dist/X4SyncServer.app.zip` - unzip this on macOS and run `X4SyncServer.app`.
- `dist/SHA256SUMS` - optional checksums for confirming the downloaded files.

## Build and Flash This Fork

Clone with submodules, install the Python build tooling, and build the default X4 firmware:

```bash
git clone --recursive git@github.com:CarterRigert/crosspoint-fork.git
cd crosspoint-fork
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -U pip pioarduino "clang-format>=21,<22"
python -m pip install -r requirements.txt
pio run -e default
```

The firmware binary is written to:

```text
.pio/build/default/firmware.bin
```

Flash either way:

- Web flasher: open `https://crosspointreader.com/#flash-tools`, choose X4, choose `Custom .bin`, and upload `.pio/build/default/firmware.bin`.
- Command line:

```bash
pio run -e default -t upload --upload-port /dev/ttyACM0
```

Adjust `/dev/ttyACM0` for your computer. If the browser or upload tool cannot see the X4, read the upstream USB-locked device notes below.

## Configure Startup Sync

First save Wi-Fi credentials on the device:

1. Open CrossPoint settings.
2. Go to `System` -> `Wi-Fi Networks`.
3. Join the same network as your computer.

Then set the sync server URL using one of these options:

- Device settings: `System` -> `Startup Sync URL`, enter something like `http://192.168.1.50:8080`.
- Web settings API while CrossPoint web server mode is running:

```bash
curl -X POST "http://X4_IP_ADDRESS/api/settings" \
  -H "Content-Type: application/json" \
  -d '{"startupSyncServerUrl":"http://192.168.1.50:8080"}'
```

- SD-card edit: add this field to `/.crosspoint/settings.json`:

```json
{
  "startupSyncServerUrl": "http://192.168.1.50:8080"
}
```

Use your computer's LAN IP address. `localhost` will not work from the X4 because it points to the X4 itself.

## Mac Sync Server App

The native macOS helper app lives in:

```text
mac/X4SyncServer
```

Run it from source:

```bash
cd mac/X4SyncServer
swift run X4SyncServer
```

The app shows the server URL to enter on the X4, starts/stops the local HTTP server, generates `sleep.bmp`, and can poll Hacker News into `HNLatest.epub`.

The app serves a manifest shaped like:

```json
{
  "updated": "2026-06-28T00:00:00-07:00",
  "files": [
    {
      "path": "/sleep.bmp",
      "url": "http://192.168.1.50:8080/sleep.bmp",
      "sha256": ""
    },
    {
      "path": "/HNLatest.epub",
      "url": "http://192.168.1.50:8080/HNLatest.epub",
      "sha256": ""
    }
  ]
}
```

Sleep-screen inputs are plain text files under `~/Library/Application Support/X4SyncServer/SleepInputs/`. Add an executable `build_sleep_inputs.sh` there to let Shortcuts, shell scripts, or Codex generate todo/calendar/weather inputs before the app renders the 480 x 800 BMP.

## Test With a Local Server

On your computer:

```bash
mkdir -p /tmp/x4-sync-test
cd /tmp/x4-sync-test
printf 'hello from startup sync\n' > test.txt
cat > manifest.json <<'JSON'
{
  "updated": "2026-06-27T08:00:00-07:00",
  "files": [
    {
      "path": "/Sync/test.txt",
      "url": "http://192.168.1.50:8080/test.txt",
      "sha256": ""
    }
  ]
}
JSON
python3 -m http.server 8080 --bind 0.0.0.0
```

Replace `192.168.1.50` with your computer's LAN IP in both `manifest.json` and `startupSyncServerUrl`.

Restart or wake CrossPoint. After sync completes, the SD card should contain:

```text
/Sync/test.txt
```

For serial logs:

```bash
python3 -m pip install pyserial colorama matplotlib
python3 scripts/debugging_monitor.py
```

Expected log lines include `Sync skipped`, `Sync OK`, or `Sync failed`. If the server is offline or Wi-Fi cannot connect, startup continues normally and logs `Sync failed`.

## MVP Limits

- Up to eight manifest files are downloaded per startup/wake.
- `sha256` is logged as a TODO and not validated yet.
- Sync runs once at startup/wake; there is no polling loop.
- HTTP operations use short 5-second timeouts, and Wi-Fi connect waits up to 8 seconds in a background task.
- Existing target files are only replaced after the new download has completed into a temp file.

---

# CrossPoint Reader

[![Fund contributors](https://img.shields.io/badge/%F0%9F%91%91_Fund_contributors-royalty.dev-BB953A?style=for-the-badge&labelColor=1a1a1a)](https://app.royalty.dev/crosspoint-reader/crosspoint-reader)

CrossPoint is open-source e-reader firmware - community-built, fully hackable, free forever. It's maintained by a growing community of developers and readers who believe your device should do what you want - not what a manufacturer decided for you.

**Now running on:** ESP32C3-based Xteink [X4](https://www.xteink.com/products/xteink-x4) and [X3](https://www.xteink.com/products/xteink-x3).

![CrossPoint Reader running on Xteink device](./docs/images/cover.jpg)

## What can CrossPoint do?

- **Reader engine**: EPUB 2/3 rendering with embedded-style option, image handling, hyphenation, kerning, chapter navigation, footnotes, bookmarks, go-to-percent, auto page turn, orientation control, focus reading, KOReader progress sync and more. 

- **Various formats**: native handling for `.epub`, `.xtc/.xtch`, `.txt`, and `.bmp`.

- **Screenshots.**

- **Custom fonts**: install your favorite fonts on the SD card.

- **Tilt page turn (X3 only)**.

- **Library workflow**: folder browser, hidden-file toggle, long-press delete, recent books, SD-cache management.

- **Wireless workflows**:
  
  - File transfer web UI
  - EPUB Optimizer
  - Web settings UI/API (edit many device settings from browser)
  - WebSocket fast uploads
  - WebDAV handler
  - AP mode (hotspot) and STA mode (join existing Wi-Fi), both with QR helpers
  - Calibre wireless connect flow
  - OPDS browser with saved servers (up to 8), search, pagination, and direct download
  - OTA update checks and installs from GitHub releases

- **Customization**: multiple themes (Classic, Lyra, Lyra Extended, RoundedRaff), sleep screen modes, front/side button remapping, status bar controls, power-button behavior, refresh cadence, and more.

- **Localization**: 24 UI languages and counting. RTL support.

### Coming soon:

- Dictionary lookup — inline word lookup without leaving the reader.

- More themes.

- Much more! stay tuned.

---

## USB-locked devices (Xteink Unlocker)

Some Xteink units purchased from third-party stores (e.g. AliExpress) ship with USB flashing locked from the factory.
If your device is locked, you will need to use the **Xteink Unlocker** tool available at
https://crosspointreader.com/#unlock-tool before you can flash CrossPoint.

**You do not need this tool if you bought your device directly from xteink.com.** Those units are not locked.

**Not sure if your device is locked?** Power it on, connect the USB-C cable, and try flashing via the web flasher first (see
[Install firmware](#install-firmware) below). If the browser's serial device picker does not show your device, try a different
USB port or browser before assuming the device is locked. Only reach for the unlocker if the device still doesn't appear.

> ### ⚠️ WARNING: READ THIS BEFORE USING THE UNLOCKER ⚠️
> 
> **The only officially supported firmwares in the unlock tool are CrossPoint and CrossInk.**
> 
> Flashing any other firmware on a USB-locked device may **permanently brick the device** or leave it **permanently
> stuck on that firmware with no recovery path**. Once USB flashing is re-locked, your only way back is via OTA, and if
> the firmware you flashed doesn't support OTA, **there is no way out**.
> 
> **The Papyrix fork has removed OTA update support from its code.** If you flash Papyrix onto a
> USB-locked unit, you will have **zero update or recovery path** and will be stuck on it forever. **Do not flash
> Papyrix (or any other unsupported firmware) on a locked device.**

## Install firmware

### Web installer (recommended)

1. Connect your device to your computer via USB-C and wake/unlock the device
2. Go to https://crosspointreader.com/#flash-tools, select device (X3 or X4), and choose an official CrossPoint release.

### Web installer (specific version)

1. Connect your device to your computer via USB-C and wake/unlock the device
2. Download a `firmware.bin` from [Releases](https://github.com/crosspoint-reader/crosspoint-reader/releases), local build, or continuous integration artifact.
3. Go to https://crosspointreader.com/#flash-tools, select device (X3 or X4), click "Custom .bin" and upload a `firmware.bin`.

### Revert to Official Firmware

To revert to the official firmware, you can also flash the latest official firmware using https://crosspointreader.com/#flash-tools.

### Command line

1. Install [`esptool`](https://github.com/espressif/esptool):

```bash
pip install esptool
```

2. Download `firmware.bin` from the [releases page](https://github.com/crosspoint-reader/crosspoint-reader/releases).
3. Connect your device via USB-C.
4. Find the device port. On Linux, run `dmesg` after connecting. On macOS:

```bash
log stream --predicate 'subsystem == "com.apple.iokit"' --info
```

5. Flash:

```bash
esptool.py --chip esp32c3 --port /dev/ttyACM0 --baud 921600 write_flash 0x10000 /path/to/firmware.bin
```

Adjust `/dev/ttyACM0` to match your system.

### Manual

See [Development quick start](#development-quick-start) below.

---

## Custom SD-card fonts

Convert your own TTF/OTF files into `.cpfont` files that load from the SD card. No firmware reflash is needed.

1. Go to https://crosspointreader.com/fonts and open the "SD-card font builder" form.
2. Upload up to four styles (regular, bold, italic, bold-italic), set the family name, point sizes, and Unicode range.
3. Download the generated `.cpfont` files.
4. Copy them to your SD card under `/fonts/YourFont/` (or `/.fonts/YourFont/` to hide the folder).
5. Select the font on the device from the font settings.

Conversion runs the firmware repo's `lib/EpdFont/scripts/fontconvert_sdcard.py` script unmodified, so output matches a local host build.

---

## Documentation

- [User Guide](./USER_GUIDE.md)
- [Web server usage](./docs/webserver.md)
- [Web server endpoints](./docs/webserver-endpoints.md)
- [Project scope](./SCOPE.md)
- [Contributing docs](./docs/contributing/README.md)

---

## Development quick start

### Prerequisites

- [pioarduino](https://github.com/pioarduino/pioarduino) or VS Code + pioarduino plugin
- Python 3.8+
- `clang-format` 21
- USB-C cable supporting data transfer

### Setup

```bash
git clone --recursive https://github.com/crosspoint-reader/crosspoint-reader
cd crosspoint-reader

# if cloned without --recursive:
git submodule update --init --recursive
```

### Build / flash / monitor

```bash
pio run --target upload
```

### Contributor pre-PR checks

```bash
./bin/clang-format-fix
pio check -e default
pio run -e default
```

### Debugging

After flashing the new features, it’s recommended to capture detailed logs from the serial port.

First, make sure all required Python packages are installed:

```python
python3 -m pip install pyserial colorama matplotlib
```

After that run the script:

```sh
# For Linux
# This was tested on Debian and should work on most Linux systems.
python3 scripts/debugging_monitor.py

# For macOS
python3 scripts/debugging_monitor.py /dev/cu.usbmodem2101
```

Minor adjustments may be required for Windows.

---

## Internals

CrossPoint Reader is pretty aggressive about caching data down to the SD card to minimise RAM usage. The ESP32-C3 only has ~380KB of usable RAM, so we have to be careful. A lot of the decisions made in the design of the firmware were based on this constraint.

### Data caching

The first time chapters of a book are loaded, they are cached to the SD card. Subsequent loads are served from the
cache. This cache directory exists at `.crosspoint` on the SD card. The structure is as follows:

```text
.crosspoint/
├── epub_<hash>/         # one directory per book, named by content hash
│   ├── progress.bin     # reading position (chapter, page, etc.)
│   ├── cover.bmp        # generated cover image
│   ├── book.bin         # metadata: title, author, spine, TOC
│   ├── css_rules.cache  # parsed CSS rule cache
│   ├── img_*            # rendered image cache files
│   └── sections/        # per-chapter layout cache
│       ├── 0.bin
│       ├── 1.bin
│       └── ...
├── settings.json        # device settings
├── state.json           # resume/runtime state
└── recent.json          # recent books list
```

Removing `/.crosspoint` clears all cached metadata and forces a full regeneration on next open. Book deletes, overwrites, and moves done through the firmware or web UI clear or re-key matching caches; manual SD-card edits may leave stale cache directories behind.

For more details on the internal file structures, see the [file formats document](./docs/file-formats.md).

---

## Contributing

Contributions are welcome. If you're new to the codebase, start with the [contributing docs](./docs/contributing/README.md). For things to work on, check the [ideas discussion board](https://github.com/crosspoint-reader/crosspoint-reader/discussions/categories/ideas) — leave a comment before starting so we don't duplicate effort.

Everyone here is a volunteer, so please be respectful and patient. For governance and community expectations, see [GOVERNANCE.md](./GOVERNANCE.md).

---

## Community forks

One of the best things about open source is that anyone can take the code in a different direction. If you need something outside CrossPoint's [scope](./SCOPE.md), check out the community forks:

- [CrossInk](https://github.com/uxjulia/CrossInk) — Typography and reading tracking: Bionic Reading (bolds word stems to create fixation points), guide dots between words, improved paragraph indents, and replaces the default fonts with ChareInk/Lexend/Bitter.

- [papyrix-reader](https://github.com/bigbag/papyrix-reader) — Adds FB2 and MD format support. Actively maintained with Arabic script support. Custom themes via SD card.

- [crosspet](https://github.com/trilwu/crosspet) — A Vietnamese fork that adds a Tamagotchi-style virtual chicken that grows based on your reading milestones (pages read, streaks, care). Also: Flashcards, Weather, Pomodoro timer, and mini-games.

- [crosspoint-reader-cjk](https://github.com/aBER0724/crosspoint-reader-cjk) — Purpose-built for Chinese, Japanese, and Korean reading.

- [inx](https://github.com/obijuankenobiii/inx) — Completely reimagines the user interface with tabbed navigation.

- ~~[PlusPoint](https://github.com/ngxson/pluspoint-reader) — custom JS apps support.~~ (Unmaintained)

- [crosspoint-reader-papers3](https://github.com/juicecultus/crosspoint-reader-papers3) — Crosspoint port for M5Stack Paper S3. 

- [t5s3-reader](https://github.com/ShallowGreen123/t5s3-reader) — Crosspoint port for LilyGo T5 ePaper S3 / T5S3 4.7-inch e-paper device.

**Note:** Many of these features will make their way into CrossPoint over time. We maintain a slower pace to ensure rock-solid stability and squash bugs before they reach your device.

Want to build your own device? Be sure to check out the [de-link](https://github.com/iandchasse/de-link) project.

---

CrossPoint Reader is **not affiliated with Xteink or any device manufacturer**.

Huge shoutout to [diy-esp32-epub-reader](https://github.com/atomic14/diy-esp32-epub-reader), which inspired this project.
