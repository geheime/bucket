# Changelog

All notable changes to Bucket are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed
- The release zip is a universal binary (arm64 and x86_64) and also contains the `integrations` folder.
- `scripts/package.sh` refuses to package a working tree with uncommitted changes unless `--allow-dirty` is given.
- `First launch.txt` links to the repository, asks to verify the SHA-256 before removing quarantine, and covers both
  `/Applications` and `~/Applications`.
- README and the Claude Code skill document `/Applications` first, with `~/Applications` as the alternative.
- Homebrew formula: loads on current Homebrew, signs with the hardened runtime, links with `ln -sfn`, notes that
  `brew upgrade` asks for Screen Recording again, and its test checks the output of `search --json`.
- CI: checkout without persisted credentials, job timeout, superseded runs are cancelled; Dependabot keeps the pinned
  actions up to date.

### Added
- `docs/media/gesture.gif`, the animation used in the README.
- `batches.jsonl` is documented in the storage layout.

## [0.2.0]

First public version.

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
