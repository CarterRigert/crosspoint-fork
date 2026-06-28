I want to modify CrossPoint Reader for the XTEINK X4 to add a minimal “startup sync” proof of concept.

Shipyard note:
This project is being worked on inside a Shipyard VPS/Docker workspace. The repo lives at
/shipyard/projects/cross-point-fork/workspace, and pushes should use the configured GitHub deploy key.

Project goal:
Eventually I want the X4 to automatically pull fresh generated content from a local server when it starts/wakes up. The server will later generate things like:
- a sleep.bmp todo/dashboard image
- an e-reader-ready Hacker News digest EPUB
- other synced files

But for this first implementation, do NOT build the todo list or Hacker News pipeline. I want to tackle the hard part first: proving that the X4 can automatically pull a file from an HTTP server after startup and save it to the SD card.

Target behavior for MVP:
When CrossPoint starts up:
1. If a Sync Server URL setting is blank, do nothing.
2. If a Sync Server URL is configured, connect to saved Wi-Fi if needed.
3. Fetch:
   {Sync Server URL}/manifest.json
4. Parse the manifest.
5. Download one small test file listed in the manifest.
6. Save it to the SD card, for example:
   /Sync/test.txt
7. Show a small status message or log:
   - “Sync skipped” if no URL is configured
   - “Sync OK” if the file downloaded and saved
   - “Sync failed” if Wi-Fi/server/download/save failed
8. Never block the normal reader startup for very long.
9. Use short timeouts.
10. Do not delete existing files.
11. Do not overwrite the final destination unless the new file download completed successfully.
12. Prefer writing to a temp file first, then renaming it to the final path.

Suggested manifest shape:
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

For the first version:
- It is okay to ignore sha256 or leave validation as TODO.
- It is okay to only download the first file in the manifest.
- It is okay to use a hardcoded default path if path handling is risky.
- It is okay to expose the Sync Server URL as a simple setting, config value, or compile-time constant if adding UI settings is too much at first.
- Please look for existing CrossPoint code that already does Wi-Fi, HTTP downloads, OPDS downloads, OTA checks, WebDAV/file transfer, or SD card writes, and reuse those patterns instead of inventing a totally separate networking stack.

Important constraints:
- This is for an embedded e-ink device, so keep it lightweight.
- Do not make the device continuously poll.
- Do not try to run Codex or an LLM on the X4.
- The X4 should stay dumb and battery-efficient.
- The server/computer will handle generating content later.
- The X4 only needs to pull finished files.
- Sync should be best-effort. If it fails, the reader should continue normally.
- Avoid draining battery or making startup frustrating.

Acceptance criteria:
1. I can run a simple test server on my computer, e.g.:
   python3 -m http.server 8080
2. The server folder contains:
   manifest.json
   test.txt
3. I configure the X4/CrossPoint with the server URL.
4. I restart/open CrossPoint.
5. The X4 fetches manifest.json.
6. The X4 downloads test.txt.
7. The file appears on the SD card at /Sync/test.txt.
8. If the server is offline, CrossPoint still starts normally and shows/logs a sync failure.

After this works, the next milestones will be:
- download /sleep.bmp and save it as the custom sleep image
- download /HN/hn-latest.epub and save it in a readable folder
- later build a server-side generator for todo dashboard + Hacker News digest
- possibly add sync on wake/before sleep in addition to startup

Please inspect the existing CrossPoint project structure and propose the smallest safe code change to implement this proof of concept. Explain which files you would modify, why, and then implement the MVP.
