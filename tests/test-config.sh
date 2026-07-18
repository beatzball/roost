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

# user config is sourced AFTER the base and OVERRIDES it (the headline feature).
# This mirrors what bin/amux does: set @amux-user-conf, then source-file -qF it.
userconf="$(mktemp /tmp/amx.XXXX)"
printf 'set -g @amux-color-bar-bg "#010203"\n' > "$userconf"
T set-option -g @amux-user-conf "$userconf"
T source-file -qF "#{@amux-user-conf}"
assert_eq "$(T show-options -gqv @amux-color-bar-bg)" "#010203" "user config overrides the base default"
rm -f "$userconf"

# a missing user config is silent (-qF), not an error — this is why bind r / bin
# amux can reference it unconditionally.
T set-option -g @amux-user-conf "/nonexistent/amux/user.conf"
out="$(T source-file -qF "#{@amux-user-conf}" 2>&1)"; rc="$?"
assert_eq "$rc" "0" "missing user config sources silently (rc 0)"
assert_eq "$out" "" "missing user config produces no error output"
