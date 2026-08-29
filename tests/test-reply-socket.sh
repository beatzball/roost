#!/usr/bin/env bash
# tests/test-reply-socket.sh — bin/roost must talk to the roost server the
# CALLER IS IN, not to the production default, when $ROOST_SOCKET is unset.
#
# The gap this closes: every other reply-channel test exports ROOST_SOCKET
# before driving anything (tests/test-reply-channel.sh:21, test-panes.sh:7,
# test-coordination.sh:7), which hand-points bin/roost's `t` at the right
# server and makes the mismatch below impossible to reach. The real case has
# nobody setting it — neither adapters/opencode/roost.js nor
# adapters/copilot/extension.mjs does — so this file NEVER sets it, and that
# omission is the whole point of the file. Do not "fix" a failure here by
# exporting it.
#
# What used to happen with it unset, on a server that is not the default
# `-L roost`: `roost state` went through scripts/roost-agent-state, which
# takes the socket from $TMUX, so the badge landed; `roost reply` went through
# bin/roost's `t`, which defaulted to `-L roost`, so its pid guard could never
# match and it exited 0 having written nothing. Badge, no reply, no error.
#
# SAFETY, and it is not optional: the pre-fix fallback is literally the
# developer's live `-L roost` server, which holds real agents. `-L NAME`
# resolves under $TMUX_TMPDIR, so this file points that at a throwaway dir
# before running anything. A red run of this test on unfixed code then reaches
# an empty socket dir instead of real work — which is what makes it safe to do
# what docs/known-gaps.md's process lesson requires and watch it fail first.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"

# Short dirs — the ~104-char unix socket limit silently corrupts long paths.
tmpdir="$(mktemp -d /tmp/amx.XXXX)"
export TMUX_TMPDIR="$tmpdir"

# The socket path ENDS IN /roost on purpose. That is the rule
# scripts/roost-agent-state has always used to decide "am I inside a roost
# server", and after the fix bin/roost uses the same one — so a test socket at
# the fixed name roost_test_server gives you (.../s) would not be recognised by
# either, and would prove nothing about the middle resolution step.
sdir="$(mktemp -d /tmp/amx.XXXX)"; s="$sdir/roost"
# A second server whose socket is NOT named roost, for the negative case.
ndir="$(mktemp -d /tmp/amx.XXXX)"; n="$ndir/plain"
trap 'tmux -S "$s" kill-server 2>/dev/null; tmux -S "$n" kill-server 2>/dev/null; rm -rf "$sdir" "$ndir" "$tmpdir"' EXIT

tmux -S "$s" -f /dev/null new-session -d -x 200 -y 50 'ENV= exec /bin/sh'
pane="$(tmux -S "$s" display -p '#{pane_id}')"
spid="$(tmux -S "$s" display -p '#{pid}')"

tmux -S "$n" -f /dev/null new-session -d -x 200 -y 50 'ENV= exec /bin/sh'
npane="$(tmux -S "$n" display -p '#{pane_id}')"
npid="$(tmux -S "$n" display -p '#{pid}')"

# An agent's own invocation: it has $TMUX and $TMUX_PANE from its pane, and no
# ROOST_SOCKET at all. `env -u` rather than just not setting it — the suite may
# be run from a shell that has one exported.
as_pane()  { env -u ROOST_SOCKET TMUX="$s,$spid,0" TMUX_PANE="$pane" "$@"; }
as_plain() { env -u ROOST_SOCKET TMUX="$n,$npid,0" TMUX_PANE="$npane" "$@"; }
stored()   { tmux -S "$s" show-options -pqv -t "$pane" @roost-reply; }
badge()    { tmux -S "$s" show-options -pqv -t "$pane" @agent_state; }

# --- the pair: badge and reply, same pane, same run, no ROOST_SOCKET ---------

as_pane "$ROOST" state done
assert_eq "$(badge)" "done" \
  "roost state stamps the badge on the caller's own server with no ROOST_SOCKET"

as_pane "$ROOST" reply "REPLY-NO-SOCKET"
assert_eq "$(stored)" "REPLY-NO-SOCKET" \
  "roost reply records on the SAME pane the badge landed on, with no ROOST_SOCKET"

# --- the reading half of the contract ---------------------------------------

# read must find that reply. Driven from the pane too: an agent asking about a
# sibling is in a pane itself, and before the fix this went to -L roost, where
# the pane id is valid and belongs to a stranger.
assert_eq "$(as_pane "$ROOST" read "$pane" 2>/dev/null)" "REPLY-NO-SOCKET" \
  "roost read resolves the caller's own server with no ROOST_SOCKET"

tmux -S "$s" send-keys -t "$pane" "printf 'SCREEN-MARKER\\n'" Enter
sleep 0.5
assert_contains "$(as_pane "$ROOST" screen "$pane" 2>/dev/null)" "SCREEN-MARKER" \
  "roost screen reads the caller's own server with no ROOST_SOCKET"

# --- the writing half: send. The dangerous one -------------------------------
# On the old code this typed into whatever pane carried the same id on the
# production server and pressed Enter. Only $TMUX_TMPDIR above makes it safe to
# run this assertion against unfixed code at all.
as_pane "$ROOST" send "$pane" "printf 'SENT-MARKER\\n'" >/dev/null 2>&1
rc=$?
assert_eq "$rc" "0" "roost send exits 0 against the caller's own server"
assert_contains "$(tmux -S "$s" capture-pane -p -t "$pane")" "SENT-MARKER" \
  "roost send types into the caller's own server with no ROOST_SOCKET"

# --- wait-done reads state from the same server ------------------------------
# An errored pane must be reported as errored. Pointed at the wrong (empty)
# server, wait-done sees no state at all and reports success — the one wrong
# answer a coordinating agent cannot recover from.
tmux -S "$s" set-option -p -t "$pane" @agent_state error
as_pane "$ROOST" wait-done "$pane" 5 >/dev/null 2>&1
rc=$?
assert_eq "$rc" "1" \
  "roost wait-done sees the caller's own server's state with no ROOST_SOCKET"
tmux -S "$s" set-option -p -t "$pane" @agent_state done

# --- the guard that must survive the fix -------------------------------------
# An explicit ROOST_SOCKET still outranks $TMUX (precedence, not replacement),
# and when the two disagree `reply` must still refuse: $TMUX_PANE from another
# server is a perfectly valid pane id here, so an unguarded write lands on a
# real, unrelated pane with no error. $TMUX names the `plain` server; the
# socket names ours; the pane id is ours, so a missing guard would be visible
# as a write.
before="$(stored)"
env ROOST_SOCKET="$s" TMUX="$n,$npid,0" TMUX_PANE="$pane" \
  "$ROOST" reply "CROSS-SERVER-WRITE"
assert_eq "$(stored)" "$before" \
  "reply still refuses to write when \$TMUX names a different server than ROOST_SOCKET"

# --- one rule, both halves ---------------------------------------------------
# A server whose socket is not named roost is not a roost server, for BOTH
# commands. This is the unification: before the fix `state` refused here on the
# socket path while `reply` refused here for an unrelated reason (a pid that
# could not match), and the two rules agreeing only by accident is how they
# drifted apart in the first place.
as_plain "$ROOST" state working
assert_eq "$(tmux -S "$n" show-options -pqv -t "$npane" @agent_state)" "" \
  "roost state stamps nothing on a server whose socket is not named roost"
as_plain "$ROOST" reply "PLAIN-SERVER-REPLY"
assert_eq "$(tmux -S "$n" show-options -pqv -t "$npane" @roost-reply)" "" \
  "roost reply writes nothing on a server whose socket is not named roost"
