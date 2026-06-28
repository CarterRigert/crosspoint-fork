# X4 Sync Server

Native macOS helper app for CrossPoint startup sync.

It serves:

- `/manifest.json`
- `/sleep.bmp` -> copied by the X4 to `/sleep.bmp`
- `/HNLatest.epub` -> copied by the X4 to `/HNLatest.epub`

The app shows the exact URL to enter on the X4:

```text
Settings -> System -> Startup Sync URL
```

Keep the Server toggle on while the X4 starts or wakes. If you want this to survive a Mac reboot, enable `Launch at login` too; otherwise macOS will not open the app automatically after login.

Enable `Serve with display off` if the Mac should keep serving while the screen goes dark. This blocks idle system sleep only; it does not keep the display awake and it does not override normal lid-close sleep.

The Output section includes `Last Request`. When the X4 syncs, it should show requests such as:

```text
GET /manifest.json -> 200 OK
GET /sleep.bmp -> 200 OK
GET /HNLatest.epub -> 200 OK
```

If `Last Request` does not change after restarting or waking the X4, the device is not reaching the Mac server URL.

## Run From Source

```bash
cd mac/X4SyncServer
swift run X4SyncServer
```

## Build a Local App Bundle

```bash
cd mac/X4SyncServer
./Scripts/build-app.sh
open .build/app/X4SyncServer.app
```

The app bundle includes `firmware.bin` and, when PyInstaller is available in the
local PlatformIO or project Python environment, a standalone `x4-flasher` helper.
That lets the Flash Firmware button work on another Mac without installing
Python, PlatformIO, or esptool.

To recreate a standalone release bundle locally, install PyInstaller once:

```bash
.pio/platformio-core/penv/bin/python -m pip install pyinstaller
```

## Sleep Screen Inputs

The app creates:

```text
~/Library/Application Support/X4SyncServer/SleepInputs/
```

Edit these files to change the generated sleep screen:

- `todos.txt`
- `calendar.txt`
- `weather.txt`
- `notes.txt`

For automation, add an executable script named:

```text
build_sleep_inputs.sh
```

The app runs it before rendering `sleep.bmp`. This gives Shortcuts, cron, shell scripts, or Codex a stable integration point: update the text files, then the app turns them into a 480 x 800 uncompressed BMP.

The Sleep refresh timer can regenerate `sleep.bmp` on a schedule, so changes made by calendar, todo, notes, or weather automation are picked up without touching the app.

Other tools can also trigger regeneration through the server:

```bash
curl http://YOUR_MAC_IP:8080/api/regenerate-sleep
```

The app shows the exact Sleep API URL in the Output section. The endpoint accepts `GET` or `POST`, queues the work, and returns immediately.

The manifest includes each served file's `sha256` and `size`. The X4 uses those values to skip `sleep.bmp` or `HNLatest.epub` when the SD-card copy is already current.

When the X4 is about to enter a custom sleep-screen mode, it shows `Syncing before sleeping`, checks `/sleep.bmp`, downloads it only if the manifest version changed, then renders the sleep screen and sleeps. If the server cannot be reached, it continues sleeping with the existing image.

## HN EPUB

When enabled, the app fetches the top 30 Hacker News front-page stories using the public Firebase API, captures a bounded set of top comments, and writes `HNLatest.epub`. The first EPUB page is a condensed list with title, points, and comment count.

The polling interval is adjustable in the app. The X4 only pulls the latest finished EPUB when it wakes or starts; it does not poll Hacker News directly.
