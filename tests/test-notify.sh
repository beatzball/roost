#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
NOTIFY="$HERE/scripts/amux-notify"

amux_test_server; sock="$AMUX_TEST_SOCK"; trap amux_test_teardown EXIT
export AMUX_NOTIFY_SOCK="$AMUX_TEST_SOCK"

# backend=none → nothing invoked, exit 0
T set-option -g @amux-notify-backend none
marker="$(mktemp)"
with_path_shim osascript "$marker" -- with_path_shim notify-send "$marker" -- \
  "$NOTIFY" "title" "msg"
assert_eq "$(cat "$marker")" "" "backend=none invokes no OS notifier"

# backend=tmux → falls straight to display-message, no OS notifier
T set-option -g @amux-notify-backend tmux
marker="$(mktemp)"
with_path_shim osascript "$marker" -- "$NOTIFY" "t" "m"
assert_eq "$(cat "$marker")" "" "backend=tmux skips the OS chain"

# @amux-notify-cmd wins over everything, with %t/%s substitution
T set-option -g @amux-notify-backend auto
cmdout="$(mktemp)"
# %t and %s each appear once, as a printf format string printf prints literally.
# (A cmd like `printf '%s|%s' '%t' '%s'` cannot work: the substitution is a global
#  %s→msg replace, which would also clobber printf's own %s format specifiers.)
T set-option -g @amux-notify-cmd "printf '%t|%s' > $cmdout"
"$NOTIFY" "TITLE" "MSG"
assert_eq "$(cat "$cmdout")" "TITLE|MSG" "@amux-notify-cmd runs with %t/%s substituted"

# always exits 0 even when a backend command fails
T set-option -g @amux-notify-cmd "false"
"$NOTIFY" a b; assert_eq "$?" "0" "amux-notify exits 0 even when backend fails"
