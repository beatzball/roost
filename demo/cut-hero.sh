#!/usr/bin/env bash
# Cut the landing-page hero from a flock recording.
#
#   ./demo/record.sh flock          # a fresh take: demo/flock.mp4
#   ./demo/cut-hero.sh --sheet      # a one-frame-per-second contact sheet, to pick the cuts
#   ./demo/cut-hero.sh              # write site/public/demo/flock-hero.{webm,mp4} and the poster
#
# The hero is four cuts of one take, fifteen seconds in all: the switcher with
# every agent working, codex researching, opencode reviewing, and the reviewed
# plan opening in preen. Live agents never take the same time twice, so the
# SEGMENTS below belong to the take they were picked from. After re-recording,
# make a contact sheet, find the same four moments, and update them.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

SRC=demo/flock.mp4
OUT=site/public/demo

# start:end, in seconds of $SRC. Picked from the 2026-09-16 take (52s).
SEGMENTS=(
  "23:28" # lead working with four tabs, then the switcher: all four working
  "30:33" # codex on gpt-5.6-terra researching the kitty protocol
  "35:37" # opencode on nemotron with the review in hand
  "41:46" # every tab done; the summary credits each reviewer; the plan in preen
)

[ -f "$SRC" ] || { echo "cut-hero: no $SRC -- run ./demo/record.sh flock first" >&2; exit 1; }

if [ "${1:-}" = --sheet ]; then
  # Row-major, one frame per second, the first tile at 0s: tile N is second N.
  sheet=/tmp/roost-demo-contact-sheet.png
  ffmpeg -y -loglevel error -i "$SRC" -vf "fps=1,scale=360:-1,tile=6x10" -frames:v 1 "$sheet"
  echo "cut-hero: contact sheet at $sheet (row-major, tile N = second N)"
  exit 0
fi

# Build the trim/concat graph from SEGMENTS.
graph="" labels=""
i=0
for seg in "${SEGMENTS[@]}"; do
  start="${seg%%:*}" end="${seg##*:}"
  graph+="[0:v]trim=${start}:${end},setpts=PTS-STARTPTS[s${i}];"
  labels+="[s${i}]"
  i=$((i + 1))
done
graph+="${labels}concat=n=${i}:v=1:a=0,fps=15,scale=1440:-2[v]"

mkdir -p "$OUT"
# 1440 wide and 15 fps: the clip is mostly still text and is shown about 1070
# wide, so this roughly halves the size with no visible loss. Measured on the
# 2026-09-16 take: 648 KB at 1800/25fps, 303 KB as WebM and 382 KB as MP4 here.
# gzip is no help -- video is already compressed (3-4% on these files).
ffmpeg -y -loglevel error -i "$SRC" -filter_complex "$graph" -map "[v]" -an \
  -c:v libvpx-vp9 -crf 40 -b:v 0 -row-mt 1 "$OUT/flock-hero.webm"
ffmpeg -y -loglevel error -i "$SRC" -filter_complex "$graph" -map "[v]" -an \
  -c:v libx264 -crf 28 -preset slow -pix_fmt yuv420p -movflags +faststart "$OUT/flock-hero.mp4"
# The poster is the last frame: the reviewed plan. It is what a visitor with
# reduced motion, or without JavaScript, sees instead of the video.
ffmpeg -y -loglevel error -sseof -0.5 -i "$OUT/flock-hero.mp4" -frames:v 1 -q:v 4 "$OUT/flock-hero-poster.jpg"

for f in "$OUT"/flock-hero.webm "$OUT"/flock-hero.mp4 "$OUT"/flock-hero-poster.jpg; do
  # wc -c, not du: du counts disk blocks and overstated these by up to 16%.
  printf '%-40s %4d KB\n' "$f" "$(( $(wc -c < "$f") / 1024 ))"
done
