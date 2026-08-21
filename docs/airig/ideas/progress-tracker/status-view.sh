#!/usr/bin/env bash
# Render a markdown file, redrawing only when its content changes.
#
# Two separate causes of flicker, both fixed here:
#   1. `clear` blanks the screen before the new frame is drawn, so every update
#      flashes. Home the cursor instead and erase-to-end AFTER drawing, so the
#      old frame is only overwritten, never blanked.
#   2. Redrawing when nothing changed. The writer suppresses no-op updates, and
#      this loop checksums the file as a second guard.
F="$1"; last=""
printf '\033[?25l'                       # hide cursor — it jitters during redraw
trap 'printf "\033[?25h\033[?7h"; exit' INT TERM EXIT
printf '\033[?7l'                        # no line-wrap: a wrapped line scrolls the frame
while :; do
  [ -f "$F" ] && now="$(cksum "$F")" || now=""
  if [ "$now" != "$last" ]; then
    last="$now"
    printf '\033[H'                      # home, do NOT clear
    if command -v glow >/dev/null; then glow -w "$(tput cols)" "$F"; else cat "$F"; fi
    printf '\033[J'                      # erase leftovers below the new frame
  fi
  sleep 2
done
