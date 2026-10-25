# Changelog

All notable changes to Bucket are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
