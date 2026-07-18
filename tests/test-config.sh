#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

amux_test_server; sock="$AMUX_TEST_SOCK"; trap amux_test_teardown EXIT
T source-file "$HERE/tmux/amux.conf"

# defaults exist for the appearance options
for o in @amux-glyph-blocked @amux-glyph-idle @amux-sep-left @amux-color-bar-bg \
         @amux-color-active-bg @amux-notify-backend; do
  v="$(T show-options -gqv "$o")"
  [ -n "$v" ] && assert_eq ok ok "default set: $o" || assert_eq "" "non-empty" "default set: $o"
done

# notify-backend default is auto
assert_eq "$(T show-options -gqv @amux-notify-backend)" auto "notify-backend defaults to auto"

# no lingering underscore option name in tracked files
grep -rq '@amux_home' "$HERE/tmux" "$HERE/scripts" "$HERE/bin" \
  && assert_eq "found" "none" "no @amux_home (underscore) remains" \
  || assert_eq ok ok "no @amux_home (underscore) remains"
