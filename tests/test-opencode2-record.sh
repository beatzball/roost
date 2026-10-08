#!/usr/bin/env bash
# The opencode 2 adapter's call pattern, through the real bin/roost (#150).
#
# tests/opencode2-plugin-harness.mjs proves WHICH `roost` calls the adapter
# makes. This proves what those calls do to a real pane and its on-disk record:
# a tab flip must not grow the turn record, and must leave `roost read` honest.
# No adapter, no node, no opencode — the pane replays the calls by hand.
#
# The sequence is the harness's A → B → A → B flips (its first front-change
# case, "front A → B → A → B, all finished, no events, ticks only": each flip
# is an empty `roost reply -`, then `roost state done`) on top of TWO turns
# that each finished while their own chat was in front. It is not the
# harness's exact replay: there, B's turn ends while A is still in front, so
# only A's text is ever published. Two in-front turns give the record two
# files, so `--turn 2` has something to read.
#
# Server, pane and record-directory setup copied from tests/test-reply-record.sh.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"

# Everything under one throwaway directory. HOME and XDG_STATE_HOME point at
# canaries nothing may write to: the last block of this file checks them, so a
# record that ignored ROOST_RECORD_DIR and fell through to the default path
# fails here instead of landing in the developer's real state directory.
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

# roost-agent-state acts only on a socket path ending in /roost, and bin/roost
# takes its socket from $ROOST_SOCKET — tests/test-reply-channel.sh's shape.
tmux -S "$s" -f /dev/null new-session -d -x 200 -y 50 'ENV= exec /bin/sh'
spid="$(tmux -S "$s" display -p '#{pid}')"
boot="$(tmux -S "$s" display -p '#{start_time}-#{pid}')"
export ROOST_SOCKET="$s"

# A fresh pane per scenario, in its own window: turn numbers belong to a pane,
# and a split can run out of room and return an empty id (tests/lib.sh).
new_pane() { tmux -S "$s" new-window -d -P -F '#{pane_id}' 'ENV= exec /bin/sh'; }
as_pane() { local p="$1"; shift; env TMUX="$s,$spid,0" TMUX_PANE="$p" "$@"; }
recdir()  { printf '%s/%s/%s' "$REC" "$boot" "${1#%}"; }
turns_in() { ls "$(recdir "$1")/replies" 2>/dev/null | grep -c '^[0-9][0-9]*$'; }
state_of() { tmux -S "$s" show-options -pqv -t "$1" @agent_state; }

# The adapter writes a reply on stdin, `roost reply -`, never as an argument.
reply() { local p="$1"; printf '%s' "$2" | as_pane "$p" "$ROOST" reply -; }
state() { as_pane "$1" "$ROOST" state "$2"; }

# Two turns, each finished with its own chat in front: A answers, then B is
# brought to the front and answers. The texts are the ones tabs.jsonl's two
# chats answered with.
two_turns() {
  reply "$1" "chat-A"; state "$1" done
  reply "$1" "chat-B"; state "$1" done
}

# --- 1. control: the first design's flips grow the record ------------------

# The first design published the front chat's last answer on every flip: a
# non-empty `roost reply -` each time. Three flips on top of two turns make
# five turn files. This is the failure the rest of the file exists to catch,
# and the count shows the file can see it.
pc="$(new_pane)"; require_pane "$pc" "control"
two_turns "$pc"
assert_eq "$(turns_in "$pc")" 2 "control: two in-front turns make two turn files"
for t in chat-B chat-A chat-B; do reply "$pc" "$t"; state "$pc" done; done
assert_eq "$(turns_in "$pc")" 5 "control: the first design's non-empty reply on each flip makes five turn files"

# --- 2. the adapter's flips leave the record alone --------------------------

pf="$(new_pane)"; require_pane "$pf" "flips"
two_turns "$pf"
assert_eq "$(turns_in "$pf")" 2 "two in-front turns make two turn files"
assert_eq "$("$ROOST" read "$pf")" "chat-B" "before any flip, read returns B's answer"
# A → B → A → B: B is in front after its turn, so the flips are to A, B, A —
# the harness's [OTHER, CHAT_A, OTHER] seen from the other side. Each is an
# empty reply, then the state: both chats have finished, so `done`.
n=0
for front in A B A; do
  n=$((n + 1))
  printf '' | as_pane "$pf" "$ROOST" reply -; rc=$?
  assert_eq "$rc" 0 "flip $n (to $front): the empty \`roost reply -\` exits 0"
  state "$pf" done
  assert_eq "$(turns_in "$pf")" 2 "flip $n (to $front): still two turn files"
  assert_eq "$(state_of "$pf")" done "flip $n (to $front): the state reads done"
done
"$ROOST" read "$pf" > "$work/out" 2> "$work/err"; rc=$?
assert_contains "$(cat "$work/err")" "no recorded reply for '$pf'" \
  "after the last flip, read says no recorded reply"
assert_eq "$rc" 0 "...at exit 0"
# The pane runs a shell that prints nothing, so its screen is blank lines; the
# point is that the output is the screen, not either chat's answer.
case "$(cat "$work/out")" in
  *chat-A*|*chat-B*) assert_true 1 "...and returns the screen, not a stored answer" ;;
  *) assert_true 0 "...and returns the screen, not a stored answer" ;;
esac
assert_eq "$("$ROOST" read --turn 1 "$pf")" "chat-A" "read --turn 1 returns A's answer"
assert_eq "$("$ROOST" read --turn 2 "$pf")" "chat-B" "read --turn 2 returns B's answer"

# --- 3. canaries ------------------------------------------------------------

# The record went where ROOST_RECORD_DIR said, and nothing fell through to the
# default path under a home.
assert_eq "$(find "$HOME" "$XDG_STATE_HOME" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')" 0 \
  "nothing was written under HOME or XDG_STATE_HOME"
