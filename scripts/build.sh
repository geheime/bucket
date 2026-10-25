#!/bin/bash
# Builds Bucket.app into ~/Applications for the author (signs with the local "Bucket Local Signing" identity if it exists, ad-hoc otherwise).
# To distribute, use scripts/package.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="$HOME/Applications/Bucket.app"
pkill -x Bucket 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Bucket "$APP/Contents/MacOS/Bucket"
cp scripts/Info.plist "$APP/Contents/Info.plist"
# Provisional icon (v0.2 exploration); the final one comes out of the UI kit.
cp brand/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# A stable identity keeps the Screen Recording grant across rebuilds; ad-hoc changes the cdhash every time.
# Create it once with scripts/make-signing-cert.sh. Falls back to ad-hoc.
IDENTITY=$(security find-identity -p codesigning | awk -F'"' '/Bucket Local Signing/ {print $2; exit}')
codesign --force --options runtime --sign "${IDENTITY:--}" --identifier studio.bast.bucket "$APP"

echo "Built $APP"
[ "${1:-}" = "--open" ] && open "$APP"
exit 0
