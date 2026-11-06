# Changelog

All notable changes to Bucket are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.5.0] - 2026-11-06

### Added
- **Screen recording.** Cmd+Shift+6 records a region of the screen. You drag the region on Bucket's own overlay (a click
  without a drag takes the whole screen, and Esc or a right click cancels), the screen outside it stays dimmed while it records, a
  small pill under it shows the time and has a stop button and a cross to discard, and Cmd+Shift+6 again stops it.
  The menu has **Record a region** / **Stop recording**.
- A recording is **one item** in the bucket. Bucket picks the frames where the screen changes (at most 12, 640 px
  wide), reads the text in each one locally (on the full-size frame, with the same secret masking as screenshots, and
  only if **Read text in screenshots** is on) and saves the video in the archive next to your screenshots. Cmd+V in a
  terminal pastes the frames in order and then a `.json` (video path, duration, region, and for each frame its time,
  its text and what text appeared). In browsers and apps the frames are pasted as images.
- **Recording limit** in the menu: 1, 2 (default), 5 or 10 minutes, or no limit. The last 10 seconds count down, the
  recording stops by itself at the limit and Bucket says "Stopped at 2:00". What was recorded is kept.
- In the panel, a recording shows its first frame with its duration.
- No Screen Recording permission: a recording that ends without a file shows the same permission pill as a screenshot.

### Fixed
- The bucket no longer empties by itself. Some apps read the clipboard for their own reasons (Safari does it when you
  type an accent with Option+E), and Bucket took that as a paste. Now a read only counts as a paste if Cmd is held
  down (Cmd+V) or you clicked a moment ago (Edit > Paste, the context menu) without Option. Any other read still gets
  its data, and Bucket puts the clipboard back the way it was, so the real paste still empties the bucket.
- The menu now warns when the macOS Cmd+Shift+4 is on. The warning never showed: Bucket looked at the wrong system
  setting (macOS keeps this shortcut as entry 30, and it is on until you turn it off). With that shortcut on, macOS
  starts its own crosshair too; turn it off in System Settings > Keyboard > Keyboard Shortcuts > Screenshots.
- Cmd+Shift+4 with Bucket's menu open now closes the menu and captures right away. Before, the key waited until the
  menu closed, and the macOS crosshair (when that shortcut was on) was what you saw in the meantime.
- After an update, System Settings can still show Screen Recording "on" for Bucket: that switch belongs to the
  previous copy. The pill now says what to do (remove Bucket with −, reopen it, and give the permission again), and a
  capture that fails for lack of permission no longer passes as a cancel.

## [0.4.3] - 2026-10-27

### Changed
- The panel shows Opt+Shift+X next to **Clear bucket**, as it shows Opt+Shift+V next to **Re-copy**.

## [0.4.2] - 2026-10-27

### Added
- Opt+Shift+X clears the bucket. Some apps read the clipboard before the paste, so the bucket did not empty
  itself; now you can empty it from anywhere. The archive keeps every screenshot. The menu shows the shortcut next to
  **Clear bucket**.
- Landing and agent prompt: a note on Opt+Shift+X for apps where the bucket does not empty itself.

### Known issues
- Capturing while Bucket's settings menu is open can still hang the crosshair. Close the menu first.

## [0.4.1] - 2026-10-27

### Fixed
- The pill and the bucket could disappear until Bucket was restarted, after entering and leaving a full-screen app:
  the companion window stayed on other Spaces. It is now rebuilt when it is found off the active Space.
- `bucket --version` printed "dev" when run through the Homebrew `bucket` command. It now prints the real version.

### Changed
- The menu toggle "Keep in menu bar" is now **Follow the cursor**, shown the other way round (on = the companion follows the cursor). Your setting is kept.
- README: how to update with `brew upgrade --cask bucket`.

### Known issues
- Capturing while Bucket's settings menu is open can still hang the crosshair. Close the menu first.

## [0.4.0] - 2026-10-25

Privacy pass: the stored text is less valuable to anything that reads your files.

### Added
- Secrets in the OCR text are masked as `[redacted]` before the sidecar is written: API keys and tokens with known
  prefixes (OpenAI, Anthropic, GitHub, Slack, AWS, Google, Stripe), JWTs, private key blocks, card numbers that pass
  Luhn, and the value after `password`, `secret`, `token` or `api_key`. Best effort: OCR splits and misreads text, and
  the PNG is not touched.
- Screenshots already in the archive get the same masking once, on first launch of 0.4 (and in `ocr --backfill`).
- No text is read from a screenshot taken while a password manager is the app in front (1Password, Bitwarden, Keychain
  Access, Passwords and others). Best effort: one only visible in the background is not detected.
- **Read text in screenshots** in the menu turns OCR off and on. While off, new screenshots are kept without text and
  `search` says so; turning it back on reads what piled up.
- A gear in the panel footer opens the settings menu.

### Changed
- On/off menu items show a checkbox in both states.
- Screen Recording is requested again whenever a capture finds it missing, so Bucket reappears in System Settings
  after the permission is removed or after switching between the zip and the Homebrew copy.
- If a capture is asked while Bucket's own menu is open, the menu is closed first.
- README: the Spotlight and Time Machine notes say what was measured on macOS 26.2.

### Known issues
- Capturing while Bucket's settings menu is open can still hang the crosshair. Close the menu first.

## [0.3.0] - 2026-10-25

First public version.

### Added
- The clipboard follows the app in front: terminals get the paths, browsers get one image per screenshot, other apps
  (such as the Claude and ChatGPT desktop apps) get each screenshot as a file and as an image. The last batch keeps
  following the app you switch to.
- Screen Recording is requested on the first capture; until it is granted, the menu bar icon is struck through and a
  capture shows a pill that opens the setting.
- Bucket says when it cannot take its capture shortcut, at launch and in the menu.
- A landing page (`site/`, https://bucket-app.pages.dev) with install instructions a coding agent can follow
  (`site/agent.md`).
- `docs/media/cover.gif`, the README cover, rendered from `tools/cover/`.
- `batches.jsonl` is documented in the storage layout.

### Changed
- Pasted paths are quoted: a path with spaces goes in double quotes, shell-special characters get a backslash, and a
  path with a control character is not pasted.
- The archive is created for your user only (`0700` folders, `0600` files).
- The release zip is a universal binary (arm64 and x86_64) and also contains the `integrations` folder.
- `scripts/package.sh` refuses to package a working tree with uncommitted changes unless `--allow-dirty` is given.
- `First launch.txt` links to the repository, asks to verify the SHA-256 before removing quarantine, and covers both
  `/Applications` and `~/Applications`.
- README and the Claude Code skill document `/Applications` first, with `~/Applications` as the alternative.
- Homebrew formula: loads on current Homebrew, signs with the hardened runtime, links with `ln -sfn`, notes that
  `brew upgrade` asks for Screen Recording again, and its test checks the output of `search --json`.
- CI: checkout without persisted credentials, job timeout, superseded runs are cancelled; Dependabot keeps the pinned
  actions up to date.

## [0.2.0]

First version, not published.

### Added
- Menu bar app for macOS 14+. The capture shortcut (default Cmd+Shift+4) runs the native macOS area selection
  and drops each screenshot into the bucket.
- Paste once: Cmd+V in the terminal pastes the paths of every screenshot in the bucket. The bucket empties itself
  when the paste happens (clipboard promise).
- Opt+Shift+V re-copies the last batch.
- Panel from the menu bar icon; the menu (right click or Control-click) has Capture, Copy batch, Re-copy last batch,
  Send last to Desktop, paste format, capture shortcut presets, Keep in menu bar and Open archive.
- Paste formats: bare paths (default, one line separated by spaces), numbered with prompt, @paths, one path per line.
- Capture shortcut presets: Cmd+Shift+4, Cmd+Shift+2, Opt+Shift+2. If a shortcut is held by another app, the menu says so.
- Archive in `~/Bucket/yyyy-MM-dd/`: an optimized PNG (long edge up to 1568 px) and a JSON sidecar per screenshot;
  the untouched original lives in `~/Bucket/originals/`. Nothing is deleted automatically.
- Local OCR with Apple Vision, run in the background. Never blocks a capture.
- `Bucket search "<words>" [--limit N] [--json]` over the OCR text and the front app name.
- Claude Code skill `bucket-search` in `integrations/claude-code/bucket-search/`.
- Headless modes: `search` and `ocr --backfill` are public. `ingest`, `render`, `render-motion`, `migrate` and the other development
  subcommands need `BUCKET_DEV=1`. `--root <dir>` points any of them at an isolated archive.
- `BucketChecks`, an assert-based check suite (no XCTest needed).
- `scripts/package.sh` for an ad-hoc signed `Bucket.app` zip; GitHub Actions CI.

### Security
- The archive is owner-only (umask 077, `~/Bucket` forced to 0700).
- Pasted paths are quoted for the shell (backslash-escaped when they contain special characters; control characters are never pasted).
- `search` derives each result path from the sidecar's location and cleans the text it returns; sidecars and `bucket.json` are validated against the archive.
- `ingest` refuses to write through symlinks; development subcommands need `BUCKET_DEV=1`; the release is signed with the hardened runtime.

### Known limitations
- Not notarized; the first launch needs "Open Anyway".
- Only tested with Claude Code.
