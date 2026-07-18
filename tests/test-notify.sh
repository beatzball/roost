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
# %t/%s become $1/$2; double-quote them so the positional expansion happens.
T set-option -g @amux-notify-cmd "printf \"%t|%s\" > $cmdout"
"$NOTIFY" "TITLE" "MSG"
assert_eq "$(cat "$cmdout")" "TITLE|MSG" "@amux-notify-cmd runs with %t/%s substituted"

# always exits 0 even when a backend command fails
T set-option -g @amux-notify-cmd "false"
"$NOTIFY" a b; assert_eq "$?" "0" "amux-notify exits 0 even when backend fails"

# Injection: metacharacters in the MESSAGE must not execute. A template that
# double-quotes %s must treat a malicious payload as inert data.
rm -f /tmp/amux-pwned-$$
T set-option -g @amux-notify-cmd "true \"%s\""
"$NOTIFY" "t" "x\" ; touch /tmp/amux-pwned-$$ #"
[ -f /tmp/amux-pwned-$$ ] && { rm -f /tmp/amux-pwned-$$; assert_eq injected safe "message metacharacters do not execute"; } \
  || assert_eq safe safe "message metacharacters do not execute"
