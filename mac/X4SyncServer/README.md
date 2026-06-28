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

## HN EPUB

When enabled, the app fetches the Hacker News front page using the public Firebase API, captures a bounded set of top comments, and writes `HNLatest.epub`.

The polling interval is adjustable in the app. The X4 only pulls the latest finished EPUB when it wakes or starts; it does not poll Hacker News directly.
