#!/usr/bin/env bash
# Author's tool, not part of the app: renders every Bucket motion with `Bucket render-motion` (the real companion, frame by
# frame) and encodes it with ffmpeg.
#
#   tools/make-media.sh <out-dir>
#
# Writes, for every motion in light and dark:
#   <out-dir>/gif/<anim>-<theme>.gif          README-sized, optimized palette, at most 3 MB, loops
#   <out-dir>/mp4/<anim>-<theme>-1x1.mp4      1080×1080, H.264, yuv420p, 60 fps (the pill centered at a readable scale)
#   <out-dir>/mp4/<anim>-<theme>-16x9.mp4     1920×1080, same
# `render-motion` is a development subcommand: this script sets BUCKET_DEV=1 for it.
# Needs ffmpeg on the PATH (`brew install ffmpeg`). KEEP_FRAMES=1 keeps the PNG sequences in <out-dir>/frames.
# Clean loops: `sequence`, `release-3` and the keycaps start and end on an empty canvas; `absorb-*` and `compact` end on the pill.
set -euo pipefail

ANIMS=(absorb-1 absorb-3 compact release-3 keycaps-capture keycaps-paste sequence)
THEMES=(light dark)
GIF_LIMIT=$((3 * 1024 * 1024))

if [[ $# -ne 1 ]]; then
  echo "usage: tools/make-media.sh <out-dir>" >&2
  exit 2
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "make-media: ffmpeg not found. It is the author's tool for the README and social clips (not an app dependency): brew install ffmpeg" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$1"
mkdir -p "$OUT/gif" "$OUT/mp4" "$OUT/frames"
OUT="$(cd "$OUT" && pwd)"

echo "make-media: building Bucket (release)…"
(cd "$ROOT" && swift build -c release --product Bucket >/dev/null)
BUCKET="$(cd "$ROOT" && swift build -c release --product Bucket --show-bin-path)/Bucket"

render() { # anim theme dir [render-motion options…]
  local anim="$1" theme="$2" dir="$3"; shift 3
  local flags=()
  [[ "$theme" == "dark" ]] && flags+=(--dark)
  BUCKET_DEV=1 "$BUCKET" render-motion "$anim" "$dir" ${flags[@]+"${flags[@]}"} "$@" >/dev/null
}

encode_gif() { # frames-dir out.gif — shrinks (width, then fps) until it fits the limit
  local frames="$1" gif="$2" size=0
  for fps in 30 25 20; do
    for width in 660 560 480 400 320; do
      # Every (60 / fps)-th frame of the 60 fps sequence; the render itself is 3 px per point.
      ffmpeg -loglevel error -y -framerate 60 -i "$frames/frame-%05d.png" \
        -vf "fps=$fps,scale=$width:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
        -loop 0 "$gif"
      size=$(stat -f%z "$gif" 2>/dev/null || stat -c%s "$gif")
      if (( size <= GIF_LIMIT )); then return 0; fi
    done
  done
  echo "make-media: $gif is still $size bytes after the smallest settings (limit $GIF_LIMIT)" >&2
  return 1
}

encode_mp4() { # frames-dir out.mp4 [crop-filter]
  local frames="$1" mp4="$2" crop="${3:-}"
  local vf="scale=out_color_matrix=bt709:out_range=tv,format=yuv420p"
  [[ -n "$crop" ]] && vf="$crop,$vf"
  ffmpeg -loglevel error -y -framerate 60 -i "$frames/frame-%05d.png" -vf "$vf" \
    -c:v libx264 -preset slow -crf 14 -profile:v high -r 60 \
    -colorspace bt709 -color_primaries bt709 -color_trc bt709 -movflags +faststart "$mp4"
}

for theme in "${THEMES[@]}"; do
  for anim in "${ANIMS[@]}"; do
    name="$anim-$theme"
    echo "make-media: $name"
    # README GIF: default canvas, 3 px per point, 60 fps (the GIF takes every other frame or fewer).
    render "$anim" "$theme" "$OUT/frames/$name-small" --scale 3
    encode_gif "$OUT/frames/$name-small" "$OUT/gif/$name.gif"
    # Social MP4: a 16:9 canvas of 320×180 pt at 6 px per point = 1920×1080; the 1:1 is its centered 1080×1080 crop.
    render "$anim" "$theme" "$OUT/frames/$name-wide" --canvas 320x180 --scale 6
    encode_mp4 "$OUT/frames/$name-wide" "$OUT/mp4/$name-16x9.mp4"
    encode_mp4 "$OUT/frames/$name-wide" "$OUT/mp4/$name-1x1.mp4" "crop=1080:1080"
    [[ "${KEEP_FRAMES:-0}" == "1" ]] || rm -rf "$OUT/frames/$name-small" "$OUT/frames/$name-wide"
  done
done
[[ "${KEEP_FRAMES:-0}" == "1" ]] || rmdir "$OUT/frames" 2>/dev/null || true

echo
echo "make-media: done → $OUT"
for f in "$OUT"/gif/*.gif "$OUT"/mp4/*.mp4; do
  bytes=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f")
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null || echo "?")
  printf '  %-40s %8d bytes  %ss\n' "${f#$OUT/}" "$bytes" "$dur"
done
