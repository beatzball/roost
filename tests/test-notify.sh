#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
NOTIFY="$HERE/scripts/roost-notify"

roost_test_server; sock="$ROOST_TEST_SOCK"; trap roost_test_teardown EXIT
export ROOST_NOTIFY_SOCK="$ROOST_TEST_SOCK"

# backend=none → nothing invoked, exit 0
T set-option -g @roost-notify-backend none
marker="$(mktemp)"
with_path_shim osascript "$marker" -- with_path_shim notify-send "$marker" -- \
  "$NOTIFY" "title" "msg"
assert_eq "$(cat "$marker")" "" "backend=none invokes no OS notifier"

# backend=tmux → falls straight to display-message, no OS notifier
T set-option -g @roost-notify-backend tmux
marker="$(mktemp)"
with_path_shim osascript "$marker" -- "$NOTIFY" "t" "m"
assert_eq "$(cat "$marker")" "" "backend=tmux skips the OS chain"

# @roost-notify-cmd wins over everything, with %t/%s substitution
T set-option -g @roost-notify-backend auto
cmdout="$(mktemp)"
# %t/%s become $1/$2; double-quote them so the positional expansion happens.
T set-option -g @roost-notify-cmd "printf \"%t|%s\" > $cmdout"
"$NOTIFY" "TITLE" "MSG"
assert_eq "$(cat "$cmdout")" "TITLE|MSG" "@roost-notify-cmd runs with %t/%s substituted"

# always exits 0 even when a backend command fails
T set-option -g @roost-notify-cmd "false"
"$NOTIFY" a b; assert_eq "$?" "0" "roost-notify exits 0 even when backend fails"

# Injection: metacharacters in the MESSAGE must not execute. A template that
# double-quotes %s must treat a malicious payload as inert data.
rm -f /tmp/roost-pwned-$$
T set-option -g @roost-notify-cmd "true \"%s\""
"$NOTIFY" "t" "x\" ; touch /tmp/roost-pwned-$$ #"
[ -f /tmp/roost-pwned-$$ ] && { rm -f /tmp/roost-pwned-$$; assert_eq injected safe "message metacharacters do not execute"; } \
  || assert_eq safe safe "message metacharacters do not execute"

# --which reports the resolved backend without delivering a notification
T set-option -g @roost-notify-backend tmux
assert_eq "$("$NOTIFY" --which)" "tmux" "--which reports the resolved backend"
