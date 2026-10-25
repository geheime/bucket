# Releasing Bucket

Steps for the maintainer. Nothing here runs by itself. Replace `0.2.0` with the version being released (the first public one is `0.3.0`).

## 0. Before anything

```sh
cd path/to/bucket
git status                      # clean, on the branch that goes to main
git tag -l                      # must be empty before the first release (tags are created in step 3, on the final HEAD)
swift build && swift run BucketChecks
```

Everything that ships must be committed before the tag. In particular:

- `CHANGELOG.md`: move the entries under a `## [x.y.z]` heading.
- `docs/media/cover.gif` (the README points at it). It is rendered from `tools/cover/cover.html`: serve the repository
  root over HTTP, run `python3 tools/cover/render.py http://127.0.0.1:<port>/tools/cover/cover.html <frames-dir> 20 9500`
  (needs Python Playwright), then build the GIF from the frames with `ffmpeg` (palettegen + paletteuse). Keep it under
  about 1.5 MB. `tools/make-media.sh` still exports the real pill animation from the app.
- `packaging/homebrew/bucket.rb` in its final form (the tarball sha256 can only be known after the tag; see step 5).

```sh
git add -A && git commit -m "Prepare release 0.2.0"
```

`scripts/package.sh` refuses to run on a tree with uncommitted changes, so a dirty tree cannot be packaged by accident.

## 1. Create the public repository (once)

```sh
gh repo create geheime/bucket --public --description "Menu bar app for macOS that hands your screenshots to Claude Code: capture with Cmd+Shift+4, paste with Cmd+V. Just buckit." --source . --remote origin
gh repo edit geheime/bucket --add-topic macos --add-topic menu-bar --add-topic screenshot --add-topic claude-code --add-topic swift --add-topic ocr
```

`--source .` only sets the remote. It does not push.

## 2. First push

```sh
git push -u origin main
```

Check that the CI run (Actions tab) is green before tagging.

## 3. Tag and package

Nothing is added to the repository after the tag: the tag points at the final commit, and the package is built from it.

```sh
git tag -a v0.2.0 -m "Bucket 0.2.0"
git push origin v0.2.0
bash scripts/package.sh 0.2.0
```

`scripts/package.sh` builds arm64 and x86_64 separately, merges them with `lipo` (this works with only the Command Line
Tools; `swift build --arch arm64 --arch x86_64` needs a full Xcode), and writes `dist/Bucket-0.2.0.zip` and
`dist/Bucket-0.2.0.zip.sha256`. The zip holds `Bucket.app`, `First launch.txt` and the `integrations` folder.
Sanity check before publishing:

```sh
D=$(mktemp -d) && unzip -q dist/Bucket-0.2.0.zip -d "$D"
codesign -dv "$D/Bucket.app" 2>&1 | grep -E "Signature|flags"   # Signature=adhoc, flags include runtime
lipo -info "$D/Bucket.app/Contents/MacOS/Bucket"                  # x86_64 arm64
ls "$D"                                                           # Bucket.app, First launch.txt, integrations
```

## 4. GitHub Release

```sh
gh release create v0.2.0 dist/Bucket-0.2.0.zip dist/Bucket-0.2.0.zip.sha256 \
  --title "Bucket 0.2.0" \
  --notes "$(printf 'First public version. Not notarized: on first launch use System Settings > Privacy & Security > Open Anyway. Tested with Claude Code only. See CHANGELOG.md.\n\nSHA-256:\n%s\n' "$(cat dist/Bucket-0.2.0.zip.sha256)")"
```

The SHA-256 goes in the release text on purpose: a `.sha256` that travels next to the zip does not protect against both being replaced.

## 5. Homebrew tap

Compute the sha256 of the tag's source tarball (this is not the zip's):

```sh
curl -sL https://github.com/geheime/bucket/archive/refs/tags/v0.2.0.tar.gz | shasum -a 256
```

Create the tap once and add the formula:

```sh
gh repo create geheime/homebrew-tap --public --description "Homebrew tap for geheime tools" --clone
cd homebrew-tap
mkdir -p Formula
cp path/to/bucket/packaging/homebrew/bucket.rb Formula/bucket.rb
# edit Formula/bucket.rb: replace the sha256 placeholder (and the TODO line) with the value above
git add Formula/bucket.rb && git commit -m "bucket 0.2.0" && git push -u origin main
```

Verify on a Mac (needs the network):

```sh
brew tap geheime/tap
brew install --build-from-source geheime/tap/bucket
brew test geheime/tap/bucket
brew audit --strict --new geheime/tap/bucket
```

## 6. Sync the formula back

Keep `packaging/homebrew/bucket.rb` in this repo equal to the tap's copy (the real sha256 included). This is the one
commit that lands after the tag, on `main` only: the tag's tarball cannot contain its own hash. The release assets
and the tag do not change.

## Next releases

Bump the version in `CHANGELOG.md`, tag `vX.Y.Z`, run `scripts/package.sh X.Y.Z`, `gh release create`, then update `url`
and `sha256` in the tap's formula. There is no auto-update in the app.
