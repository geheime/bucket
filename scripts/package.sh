#!/bin/bash
# Packages a release: dist/Bucket-<version>.zip (+ .sha256) with an ad-hoc signed Bucket.app.
#
#   scripts/package.sh 0.2.0 [--allow-dirty]
#
# The binary is universal (arm64 + x86_64). Two single-architecture builds are merged with lipo, so it works with only
# the Command Line Tools (`swift build --arch arm64 --arch x86_64` needs a full Xcode). The zip also carries the
# Claude Code skill folder (integrations/). The script refuses to package a working tree with uncommitted changes
# unless --allow-dirty is given, so a release is always built from a commit.
#
# Ad-hoc on purpose: this is what anyone can reproduce. The "Bucket Local Signing" identity that scripts/build.sh
# prefers is the author's own machine only and is never used here. The app is NOT notarized; see README.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=""
ALLOW_DIRTY=0
for arg in "$@"; do
  case "$arg" in
    --allow-dirty) ALLOW_DIRTY=1 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) if [[ -z "$VERSION" ]]; then VERSION="$arg"; else echo "unexpected argument: $arg" >&2; exit 2; fi ;;
  esac
done
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]]; then
  echo "usage: scripts/package.sh <version> [--allow-dirty]   (e.g. 0.2.0)" >&2
  exit 2
fi

if [[ "$ALLOW_DIRTY" -ne 1 && -n "$(git status --porcelain)" ]]; then
  echo "package: the working tree has uncommitted changes. Commit or stash them, or pass --allow-dirty." >&2
  git status --short >&2
  exit 1
fi

# Universal binary: one release build per architecture, merged with lipo.
for triple in arm64-apple-macosx14.0 x86_64-apple-macosx14.0; do
  swift build -c release --triple "$triple"
done

STAGE="dist/stage"
APP="$STAGE/Bucket.app"
rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/Bucket" \
  .build/arm64-apple-macosx/release/Bucket .build/x86_64-apple-macosx/release/Bucket
lipo -info "$APP/Contents/MacOS/Bucket"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp brand/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Hardened runtime (no entitlements needed): library validation on, DYLD_* injection off.
codesign --force --options runtime --sign - --identifier studio.bast.bucket "$APP"

cp -R integrations "$STAGE/integrations"

cat > "$STAGE/First launch.txt" <<TXT
Bucket $VERSION

Repository and full instructions: https://github.com/geheime/bucket

1. Verify the download. Run, in the folder with the zip:
       shasum -a 256 Bucket-$VERSION.zip
   and compare the result with the SHA-256 printed in the text of this version's release page on GitHub.
   Do this BEFORE the next steps; if the values differ, do not open the app.
2. Drag Bucket.app to your Applications folder (/Applications, or ~/Applications).
3. Bucket is not notarized by Apple, so the first time macOS will refuse to open it.
   Open it once, then go to System Settings > Privacy & Security, scroll down to
   "Bucket was blocked" and click "Open Anyway". Or, only after the hash matched, in Terminal:
       xattr -dr com.apple.quarantine /Applications/Bucket.app
   (if you put it in your user Applications folder:
       xattr -dr com.apple.quarantine ~/Applications/Bucket.app )
4. Allow Screen Recording when asked (System Settings > Privacy & Security > Screen Recording).
5. To use Cmd+Shift+4, turn off the macOS shortcut first:
   System Settings > Keyboard > Keyboard Shortcuts > Screenshots.

The integrations folder holds the Claude Code skill; see the README for how to install it.
TXT

ZIP="dist/Bucket-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --sequesterRsrc "$STAGE" "$ZIP"
(cd dist && shasum -a 256 "Bucket-$VERSION.zip" > "Bucket-$VERSION.zip.sha256")

echo "Packaged $ZIP"
cat "$ZIP.sha256"
