#!/usr/bin/env bash
# `roost reply` takes its text on STDIN (#86).
#
# Why this file exists, measured rather than assumed:
#
#   Linux caps a SINGLE argument at 131072 bytes (MAX_ARG_STRLEN), independently
#   of the much larger ARG_MAX total. Measured in ubuntu:24.04 (kernel
#   6.11.11, getconf ARG_MAX 2097152): `roost reply <131071 bytes>` exits 0,
#   `roost reply <131072 bytes>` dies with "Argument list too long" at exit 126
#   — the exec fails, so roost never runs, nothing is recorded, and `roost read`
#   falls back to scraping the screen.
#
#   macOS has no per-argument cap: the limit is the ARG_MAX TOTAL, measured on
#   Darwin 25.3.0 arm64 (getconf ARG_MAX 1048576) by binary search at 1041390
#   bytes accepted and 1041391 refused, the difference being this shell's
#   environment. So the one-argument form is fine here at 200 KB and dies at
#   1 MB, and a macOS-only test would never see the bug CI hits.
#
# The transport is the fix, the same way it was for `send`: the text travels
# over stdin, where neither limit applies. The 12 KB pane-option cap is
# unchanged — the kept-turn file (#42) is what serves a long reply back whole.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"

# Everything under one throwaway directory, tests/test-reply-record.sh's shape.
# HOME and XDG_STATE_HOME point at canaries nothing may write to: the last block
# checks them, so a record that ignored ROOST_RECORD_DIR and fell through to the
# default path fails here instead of landing in the developer's real state
# directory.
work="$(mktemp -d /tmp/amx.XXXX)"
s="$work/roost"
REC="$work/rec"
export ROOST_RECORD_DIR="$REC"
export HOME="$work/home" XDG_STATE_HOME="$work/xdg-state"
mkdir -p "$HOME" "$XDG_STATE_HOME"
cleanup() {
  tmux -S "$s" kill-server 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

tmux -S "$s" -f /dev/null new-session -d -x 200 -y 50 'ENV= exec /bin/sh'
spid="$(tmux -S "$s" display -p '#{pid}')"
export ROOST_SOCKET="$s"

# A fresh pane per scenario, in its own window: turn numbers belong to a pane,
# and a split can run out of room and return an empty id (tests/lib.sh).
new_pane() { tmux -S "$s" new-window -d -P -F '#{pane_id}' 'ENV= exec /bin/sh'; }
as_pane() { local p="$1"; shift; env TMUX="$s,$spid,0" TMUX_PANE="$p" "$@"; }

# What `read` prints for a reply of these bytes: the bytes with trailing
# newlines dropped (a `$(...)` drops them on both store paths), then one
# newline — the existing `printf '%s\n'`.
expect_file() { local v; v="$(cat "$1")"; printf '%s\n' "$v" > "$2"; }

# The text field of `read --json`, written to a file so it can be compared byte
# for byte. python3 does the decoding, so no shell quoting touches 200 KB of it.
json_text() {
  "$ROOST" read --json "$1" 2>/dev/null | python3 -c \
    'import json,sys; sys.stdout.write(json.load(sys.stdin)["text"])' > "$2"
}

# 200 KB, the size the issue asks for: comfortably past Linux's 131072 and past
# the 12 KB pane cap, so both halves of the mechanism are exercised at once.
big="$work/big.txt"
awk 'BEGIN{ for (i = 0; i < 3940; i++) printf "line %05d: padding text that makes this reply long\n", i }' > "$big"
expect_file "$big" "$work/want"
printf '%s' "$(cat "$big")" > "$work/want-raw"
bigbytes="$(wc -c < "$big" | tr -d ' ')"

# --- 1. `roost reply -` reads the reply from stdin --------------------------

p1="$(new_pane)"; require_pane "$p1" "stdin dash"
as_pane "$p1" "$ROOST" reply - < "$big"; rc=$?
assert_eq "$rc" 0 "\`roost reply -\` exits 0 on a $bigbytes-byte body"
"$ROOST" read "$p1" > "$work/out" 2> "$work/err"
cmp -s "$work/out" "$work/want"; assert_true $? "...and \`roost read\` returns all $bigbytes bytes"
assert_eq "$(cat "$work/err")" "" "...with nothing on stderr (no screen fallback)"
json_text "$p1" "$work/jout"
cmp -s "$work/jout" "$work/want-raw"; assert_true $? "...and \`roost read --json\` carries the same bytes in .text"

# The pane option is NOT grown to fit. It stays capped and marked, and the kept
# turn file is what serves the whole body above — the split this issue must not
# disturb.
case "$(tmux -S "$s" show-options -pqv -t "$p1" @roost-reply)" in
  *"reply truncated"*) assert_true 0 "the pane option still holds the 12 KB capped value" ;;
  *) assert_true 1 "the pane option still holds the 12 KB capped value" ;;
esac

# --- 2. `--stdin` is the same command spelled out ---------------------------

p2="$(new_pane)"; require_pane "$p2" "stdin flag"
as_pane "$p2" "$ROOST" reply --stdin < "$big"
"$ROOST" read "$p2" > "$work/out" 2>/dev/null
cmp -s "$work/out" "$work/want"; assert_true $? "\`roost reply --stdin\` reads the same $bigbytes bytes"

# --- 3. no argument at all, on a pipe, reads stdin --------------------------
#
# This is the form an adapter reaches for when it has a stream and no flag to
# add. It is safe only because of the tty check in block 6.

p3="$(new_pane)"; require_pane "$p3" "stdin bare"
as_pane "$p3" "$ROOST" reply < "$big"
"$ROOST" read "$p3" > "$work/out" 2>/dev/null
cmp -s "$work/out" "$work/want"; assert_true $? "\`roost reply\` with no argument and a pipe reads stdin"

# --- 4. the one-argument form is untouched ----------------------------------
#
# The whole point of the change is that nothing a human or an existing adapter
# already types changes meaning. Small text, several words, and a body past the
# 12 KB cap all go through argv exactly as before.

p4="$(new_pane)"; require_pane "$p4" "argv one word"
as_pane "$p4" "$ROOST" reply "the tests pass"
assert_eq "$("$ROOST" read "$p4" 2>/dev/null)" "the tests pass" "\`roost reply TEXT\` still records TEXT"

p5="$(new_pane)"; require_pane "$p5" "argv many words"
as_pane "$p5" "$ROOST" reply two lines of words
assert_eq "$("$ROOST" read "$p5" 2>/dev/null)" "two lines of words" "\`roost reply A B C\` still joins the words with spaces"

# A $bigbytes-byte reply through ARGV is platform-dependent, and pinning that
# split is the point of this issue rather than an inconvenience to work around.
# The probe is a real exec with the real body — `bash -c` forks and execs, so it
# meets the same MAX_ARG_STRLEN the `roost` exec would — because asking uname
# would assert what this file already claims in a comment instead of measuring
# the machine the test is running on.
p6="$(new_pane)"; require_pane "$p6" "argv big"
if bash -c 'exit 0' _ "$(cat "$big")" 2>/dev/null; then
  # macOS: no per-argument cap, so argv carries it and roost behaves as ever.
  as_pane "$p6" "$ROOST" reply "$(cat "$big")"
  "$ROOST" read "$p6" > "$work/out" 2>/dev/null
  cmp -s "$work/out" "$work/want"; assert_true $? "this OS takes a $bigbytes-byte argument, and the one-argument reply reads back whole"
else
  # Linux: THE BUG, pinned where it happens. The exec fails, so roost never
  # runs, nothing is recorded, and a sibling's `roost read` is left scraping the
  # screen. This is the assertion that says why the stdin form has to exist.
  as_pane "$p6" "$ROOST" reply "$(cat "$big")" 2> "$work/err"; rc=$?
  [ "$rc" -ne 0 ]; assert_true $? "this OS refuses a $bigbytes-byte argument, so the one-argument reply fails outright"
  assert_contains "$(cat "$work/err")" "Argument list too long" "...with the kernel's own message, before roost runs"
  "$ROOST" read "$p6" > "$work/out" 2> "$work/err"
  assert_contains "$(cat "$work/err")" "no recorded reply" "...and nothing was recorded, so read falls back to the screen"
fi

# A reply whose text merely BEGINS with a dash is still text: only an argument
# that is exactly `-` or `--stdin` selects stdin, and only in first position.
p7="$(new_pane)"; require_pane "$p7" "argv leading dash"
as_pane "$p7" "$ROOST" reply "-- not a flag"
assert_eq "$("$ROOST" read "$p7" 2>/dev/null)" "-- not a flag" "a reply beginning with dashes is text, not a flag"

# --- 5. hostile bytes survive the stdin path --------------------------------
#
# Built with printf octal escapes, never typed as literal characters: an editor
# or tool that normalises text would otherwise change the fixture silently. The
# trailing `;` is the one tmux's command parser eats (scripts/lib/roost-reply.sh).

emoji="$(printf '\360\237\230\200')"; eacute="$(printf '\303\251')"
{ cat "$big"; printf 'caf%s %s quotes " '\'' \\ $HOME end;' "$eacute" "$emoji"; } > "$work/bigh"
expect_file "$work/bigh" "$work/wanth"
p8="$(new_pane)"; require_pane "$p8" "hostile stdin"
as_pane "$p8" "$ROOST" reply - < "$work/bigh"
"$ROOST" read "$p8" > "$work/out" 2>/dev/null
cmp -s "$work/out" "$work/wanth"; assert_true $? "a long hostile body on stdin reads back byte-identical"

# --- 6. a human at a terminal is never left hanging -------------------------
#
# The reason `reply` read argv and never stdin in the first place: it is a
# documented public command someone types, and an unconditional `cat` waits for
# ^D forever. These two run INSIDE a real pane, where stdin is a tty — the only
# way to test that honestly; a pipe or /dev/null is not a tty and proves nothing.
#
# The marker is typed as TTY""DONE and printed as TTYDONE, so the command echoed
# at the prompt can never satisfy the match before the command has run.

tty_out=""
tty_run() {   # tty_run LABEL CMD -> 0 when the shell came back, $tty_out set
  local label="$1" cmd="$2" p i=0
  p="$(new_pane)"; require_pane "$p" "$label"
  tmux -S "$s" send-keys -t "$p" "$cmd; echo rc=\$? TTY\"\"DONE" Enter
  while [ "$i" -lt 80 ]; do
    tty_out="$(tmux -S "$s" capture-pane -p -t "$p" 2>/dev/null || true)"
    case "$tty_out" in *TTYDONE*) return 0 ;; esac
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

tty_run "bare on a tty" "$ROOST reply"; assert_true $? "\`roost reply\` typed at a terminal returns instead of waiting on stdin"

tty_run "dash on a tty" "$ROOST reply -"
assert_true $? "\`roost reply -\` typed at a terminal returns instead of waiting on stdin"
assert_contains "$tty_out" "rc=2" "...refusing with exit 2 rather than recording nothing"
assert_contains "$tty_out" "stdin" "...and saying stdin on stderr"

# --- 7. nothing landed in the real state directory --------------------------

assert_file_absent "$HOME/.local" "the run wrote nothing under the canary HOME"
assert_file_absent "$XDG_STATE_HOME/roost" "the run wrote nothing under the canary XDG_STATE_HOME"

exit 0
