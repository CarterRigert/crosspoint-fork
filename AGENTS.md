# CrossPoint X4 Sync Fork: Agent Notes

This fork has moved past the original startup-sync proof of concept. Keep future
work aligned with the current shape of the project.

## Current Product Shape

- Firmware on the XTEINK X4 pulls finished files from a local HTTP sync server.
- The Mac helper app in `mac/X4SyncServer` generates and serves:
  - `/manifest.json`
  - `/sleep.bmp`, saved on the X4 as `/sleep.bmp`
  - `/HNLatest.epub`, saved on the X4 as `/HNLatest.epub`
- The X4 should stay dumb and battery-efficient. Do generation, API calls,
  calendar/todo/weather integrations, and Hacker News fetching on the Mac.
- Sync is best-effort. If Wi-Fi, server, download, or save fails, CrossPoint
  should continue normally.

## User Workflow To Preserve

For a non-developer Mac user:

1. Download or clone the repo.
2. Use `dist/X4SyncServer.app.zip` as the ready-built Mac app.
3. Open the app, turn on the server, and use the displayed server URL.
4. Plug in the X4 over USB when needed.
5. Use the app's Device controls:
   - `Refresh`
   - `Flash Firmware`
   - `Push Sync URL`

Do not require the user to install Python, PlatformIO, Swift, or esptool just to
run the packaged app. The release app bundle should contain:

- `Contents/Resources/firmware.bin`
- `Contents/Resources/x4-flasher`

## Important Paths

- Firmware sync implementation: `src/network/StartupSync.cpp`
- Firmware settings and serial command wiring: `src/main.cpp`
- Mac app: `mac/X4SyncServer`
- Mac app state/orchestration: `mac/X4SyncServer/Sources/X4SyncServer/AppModel.swift`
- Sleep BMP renderer: `mac/X4SyncServer/Sources/X4SyncServer/SleepRenderer.swift`
- HN EPUB generation: `mac/X4SyncServer/Sources/X4SyncServer/EpubBuilder.swift`
- HN API client: `mac/X4SyncServer/Sources/X4SyncServer/HNClient.swift`
- Static server/API routes: `mac/X4SyncServer/Sources/X4SyncServer/StaticHTTPServer.swift`
- Manifest generation: `mac/X4SyncServer/Sources/X4SyncServer/ManifestWriter.swift`
- App packaging script: `mac/X4SyncServer/Scripts/build-app.sh`
- Standalone flasher entrypoint: `mac/X4SyncServer/Scripts/x4_flash_helper.py`
- Ready-built artifacts: `dist/`

## Sleep Screen Customization

The normal extension point for a user-customized sleep screen is the app support
folder, not firmware:

```text
~/Library/Application Support/X4SyncServer/SleepInputs/
```

The app reads:

- `todos.txt`
- `calendar.txt`
- `weather.txt`
- `notes.txt`
- `hn.txt`

If `build_sleep_inputs.sh` exists there and is executable, the app runs it before
rendering `sleep.bmp`. Prefer this hook for personal integrations with calendar,
todo apps, weather commands, Shortcuts, local scripts, or Codex-generated
workflows.

The Mac app has per-section sleep-screen toggles for Weather, Calendar, Todo,
Notes, and HN. Preserve those toggles when changing layout behavior.

When HN polling is enabled, the Mac app refreshes `hn.txt` with up to ten HN
sleep stories. The user-selected count from 1 to 10 controls how many cached
stories render. Changing that count should not trigger a network fetch or
immediate `sleep.bmp` regeneration. Each story uses two lines: title, then
points/comment count. Preserve that format unless the user asks otherwise.

Only edit `SleepRenderer.swift` when the visual layout, typography, sections, or
BMP rendering behavior needs to change. The output must remain a 480 x 800 BMP
that the X4 can render as the root `/sleep.bmp`.

The app also exposes a manual regeneration endpoint:

```bash
curl http://YOUR_MAC_IP:8080/api/regenerate-sleep
```

## Hacker News EPUB Customization

Keep HN generation on the Mac. The X4 should only download the finished
`HNLatest.epub`.

- Change fetching/filtering in `HNClient.swift`.
- Change EPUB structure and formatting in `EpubBuilder.swift`.
- Preserve the first-page condensed list of top stories unless the user asks to
  change it.

## Firmware Constraints

- Do not add continuous polling on the X4.
- Do not run Codex, an LLM, calendar APIs, todo APIs, or HN APIs on the X4.
- Keep startup/wake sync bounded with short timeouts.
- Download to a temp file first, then promote to the final path.
- Avoid deleting user files unless the user explicitly asks for that behavior.
- Preserve version/size/hash checks so current files are skipped.
- Be very careful with sleep/boot paths; avoid blocking boot or sleep forever.

## Build And Verification Commands

Firmware:

```bash
pio run -e default
```

Mac app from source:

```bash
cd mac/X4SyncServer
swift run X4SyncServer
```

Packaged Mac app:

```bash
mac/X4SyncServer/Scripts/build-app.sh
ditto -c -k --sequesterRsrc --keepParent mac/X4SyncServer/.build/app/X4SyncServer.app dist/X4SyncServer.app.zip
env LC_ALL=C LANG=C shasum -a 256 dist/firmware.bin dist/X4SyncServer.app.zip > dist/SHA256SUMS
env LC_ALL=C LANG=C shasum -a 256 -c dist/SHA256SUMS
```

The standalone flasher requires PyInstaller when rebuilding the app bundle:

```bash
.pio/platformio-core/penv/bin/python -m pip install pyinstaller
```

Smoke-test bundled flasher:

```bash
mac/X4SyncServer/.build/app/X4SyncServer.app/Contents/Resources/x4-flasher version
```

## Artifact Policy

If source changes affect firmware or the packaged Mac app, refresh the matching
files in `dist/` so a non-developer can use the repo without rebuilding.

If only a personal `SleepInputs` script changes outside the repo, a rebuild is
not needed.
