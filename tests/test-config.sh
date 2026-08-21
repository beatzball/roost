#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

roost_test_server; sock="$ROOST_TEST_SOCK"; trap roost_test_teardown EXIT
T source-file "$HERE/tmux/roost.conf"

# defaults exist for the appearance options
for o in @roost-glyph-error @roost-glyph-blocked @roost-glyph-idle @roost-sep-left @roost-color-bar-bg \
         @roost-color-active-bg @roost-notify-backend; do
  v="$(T show-options -gqv "$o")"
  [ -n "$v" ] && assert_eq ok ok "default set: $o" || assert_eq "" "non-empty" "default set: $o"
done

# notify-backend default is auto
assert_eq "$(T show-options -gqv @roost-notify-backend)" auto "notify-backend defaults to auto"

# no lingering underscore option name in tracked files
grep -rq '@roost_home' "$HERE/tmux" "$HERE/scripts" "$HERE/bin" \
  && assert_eq "found" "none" "no @roost_home (underscore) remains" \
  || assert_eq ok ok "no @roost_home (underscore) remains"

# user config is sourced AFTER the base and OVERRIDES it (the headline feature).
# This mirrors what bin/roost does: set @roost-user-conf, then source-file -qF it.
userconf="$(mktemp /tmp/amx.XXXX)"
printf 'set -g @roost-color-bar-bg "#010203"\n' > "$userconf"
T set-option -g @roost-user-conf "$userconf"
T source-file -qF "#{@roost-user-conf}"
assert_eq "$(T show-options -gqv @roost-color-bar-bg)" "#010203" "user config overrides the base default"
rm -f "$userconf"

# a missing user config is silent (-qF), not an error — this is why bind r / bin
# roost can reference it unconditionally.
T set-option -g @roost-user-conf "/nonexistent/roost/user.conf"
out="$(T source-file -qF "#{@roost-user-conf}" 2>&1)"; rc="$?"
assert_eq "$rc" "0" "missing user config sources silently (rc 0)"
assert_eq "$out" "" "missing user config produces no error output"
