#!/usr/bin/env bash
# Encode the WHOLE flock recording for the two click-to-play blocks.
#
#   ./demo/record.sh flock        # a fresh take: demo/flock.mp4
#   ./demo/encode-full.sh         # write site/public/demo/flock-full.{webm,mp4} and the poster
#
# The sibling of cut-hero.sh, and the difference is the whole point: cut-hero.sh
# picks four moments and stitches them into a fifteen-second autoplaying hero,
# while this one keeps the take intact for the reader who wants to watch the
# run happen. Two blocks use these files -- the homepage, below the fold, and
# the Getting Started page -- and both point at the same three, so shipping
# both costs one download, not two, and only after a click.
#
# Written after the fact: the first copies of these files were encoded by hand
# in a scratch directory, which left the site carrying three binaries nobody
# could reproduce. Re-recording would have meant guessing at the settings.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

SRC=demo/flock.mp4
OUT=site/public/demo

[ -f "$SRC" ] || { echo "encode-full: no $SRC -- run ./demo/record.sh flock first" >&2; exit 1; }

mkdir -p "$OUT"

# The same 1440-wide, 15 fps, crf 40 / crf 28 recipe as the hero, deliberately:
# two videos on one page encoded differently would show it, and the reasoning
# has not changed -- the clip is mostly still text and is shown about 1070 wide.
# Measured on the 2026-09-16 take (52.2s): 867 KB as WebM and 705 KB as MP4,
# against 310 KB and 391 KB for the hero's fifteen seconds. No -filter_complex
# here; there is nothing to trim or concat, so a plain -vf is enough.
ffmpeg -y -loglevel error -i "$SRC" -vf "fps=15,scale=1440:-2" -an \
  -c:v libvpx-vp9 -crf 40 -b:v 0 -row-mt 1 "$OUT/flock-full.webm"
ffmpeg -y -loglevel error -i "$SRC" -vf "fps=15,scale=1440:-2" -an \
  -c:v libx264 -crf 28 -preset slow -pix_fmt yuv420p -movflags +faststart \
  "$OUT/flock-full.mp4"

# The poster is the LAST frame, matching the hero, and it is not a spoiler to
# regret: it is the reviewed plan, which is the thing worth clicking for. The
# first frame was tried and is an almost-empty terminal -- 6 KB of near-black,
# which reads as a broken image rather than an invitation.
ffmpeg -y -loglevel error -sseof -0.5 -i "$OUT/flock-full.mp4" -frames:v 1 -q:v 4 \
  "$OUT/flock-full-poster.jpg"

for f in "$OUT"/flock-full.webm "$OUT"/flock-full.mp4 "$OUT"/flock-full-poster.jpg; do
  # wc -c, not du: du counts disk blocks and overstated these by up to 16%.
  printf '%-40s %4d KB\n' "$f" "$(( $(wc -c < "$f") / 1024 ))"
done

# EXPECT `git status` TO SHOW THE WEBM CHANGED, AND ONLY THE WEBM. Re-running
# this against the same take reproduces flock-full.mp4 and the poster byte for
# byte -- identical sha256 -- while the WebM comes out the same 867392 bytes
# with different bytes inside. libvpx-vp9 with -row-mt is not deterministic
# across runs; the encode is the same, the file is not. So a dirty WebM after a
# re-run is the expected result and not a reason to go hunting, and `git
# checkout -- site/public/demo/` is the right response when the take has not
# actually changed.

