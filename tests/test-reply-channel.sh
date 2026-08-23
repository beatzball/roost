#!/usr/bin/env bash
# The reply channel: an agent records what it just said on its own pane, and a
# sibling's `roost read` gets that instead of a screenshot of its TUI.
#
# See docs/airig/issues/2026-08-21-read-returns-tui-chrome.md for the bug, and
# docs/airig/specs/2026-08-23-read-reply-channel-design.md for why it is stored
# in a pane option rather than a file.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"

# roost-agent-state only acts on a socket path ending in /roost, and bin/roost
# takes its socket from $ROOST_SOCKET, so build one directly rather than via
# roost_test_server — the same shape tests/test-state-cmd.sh uses.
sdir="$(mktemp -d /tmp/amx.XXXX)"; s="$sdir/roost"
trap 'tmux -S "$s" kill-server 2>/dev/null; rm -rf "$sdir"' EXIT
tmux -S "$s" -f /dev/null new-session -d -x 200 -y 50 'ENV= exec /bin/sh'
pane="$(tmux -S "$s" display -p '#{pane_id}')"
spid="$(tmux -S "$s" display -p '#{pid}')"
export ROOST_SOCKET="$s"

# `roost reply` refuses to write unless the caller's $TMUX names THIS server,
# so every in-pane invocation has to carry a believable one.
as_pane() { env TMUX="$s,$spid,0" TMUX_PANE="$pane" "$@"; }
stored()  { tmux -S "$s" show-options -pqv -t "$pane" @roost-reply; }

# --- the round trip ---------------------------------------------------------

as_pane "$ROOST" reply $'first line\nsecond line\nthird line'
assert_eq "$("$ROOST" read "$pane")" $'first line\nsecond line\nthird line' \
  "read returns the recorded reply, all of it, in order"

# The reply is what comes back, NOT the pane's screen. This is the whole bug:
# the pane below is running a shell whose screen says something else entirely.
tmux -S "$s" send-keys -t "$pane" "printf 'SCREEN-NOISE\n'" Enter
sleep 0.5
out="$("$ROOST" read "$pane" 2>/dev/null)"
case "$out" in
  *SCREEN-NOISE*) assert_eq screen reply "read prefers the recorded reply over the pane's screen" ;;
  *) assert_eq ok ok "read prefers the recorded reply over the pane's screen" ;;
esac

# --- hostile content --------------------------------------------------------

# tmux format syntax inside a REPLY must not be expanded on the way out. An
# agent quoting this repo's own code emits `#{pane_id}` and `#[fg=red]` as a
# matter of course. Verified byte-identical on tmux 3.6; this locks it.
hostile=$'a #{pane_id} b\n#[fg=red]styled#[default]\t100% done\n#{?x,y,z}'
as_pane "$ROOST" reply "$hostile"
assert_eq "$("$ROOST" read "$pane")" "$hostile" \
  "a reply containing tmux format and style syntax survives unexpanded"

# --- N describes the screen, never the reply --------------------------------

# `tail -n N` on a recorded reply would chop off its BEGINNING, and
# skills/roost/SKILL.md passes 40 today — so a reply longer than that would be
# silently cut at exactly the point a caller would never think to check.
long="$(printf 'reply-line-%02d\n' $(seq 1 60))"
as_pane "$ROOST" reply "$long"
got="$("$ROOST" read "$pane" 5)"
assert_eq "$(printf '%s' "$got" | grep -c '^reply-line-')" "60" \
  "a LINES argument does not truncate a recorded reply"
assert_contains "$got" "reply-line-01" "the reply keeps its first line despite LINES=5"

# --- staleness is reported, not hidden --------------------------------------

as_pane "$ROOST" reply "PREVIOUS TURN"
tmux -S "$s" set-option -p -t "$pane" @agent_state working
err="$("$ROOST" read "$pane" 2>&1 >/dev/null)"
assert_contains "$err" "previous turn" \
  "a reply read while the pane is working is flagged as stale"
assert_eq "$("$ROOST" read "$pane" 2>/dev/null)" "PREVIOUS TURN" \
  "...and is still printed — a stale reply is reported, not withheld"

tmux -S "$s" set-option -p -t "$pane" @agent_state done
err="$("$ROOST" read "$pane" 2>&1 >/dev/null)"
assert_eq "$err" "" "a reply read while the pane is done carries no notice"

# --- pane scope only --------------------------------------------------------

# A format lookup falls back pane -> window -> global. `roost read` uses
# show-options -p so it cannot serve a stray outer-scope value as this agent's
# own reply — the same accident tmux/roost.conf carries a `set -gu` to undo for
# @agent_state.
tmux -S "$s" set-option -pu -t "$pane" @roost-reply
tmux -S "$s" set-option -g @roost-reply "GLOBAL LEAK"
out="$("$ROOST" read "$pane" 3 2>/dev/null)"
case "$out" in
  *"GLOBAL LEAK"*) assert_eq leaked pane-scoped "a global @roost-reply is not served as a pane's reply" ;;
  *) assert_eq ok ok "a global @roost-reply is not served as a pane's reply" ;;
esac
tmux -S "$s" set-option -gu @roost-reply

# --- the fallback is loud, and stdout stays clean ---------------------------

# With no reply recorded, read must never return NOTHING: an empty result is a
# worse failure than the chrome this fixed, because the caller cannot tell it
# from "the agent said nothing".
out="$("$ROOST" read "$pane" 5 2>/dev/null)"; assert_contains "$out" "SCREEN-NOISE" \
  "with no recorded reply, read falls back to the pane's screen"
err="$("$ROOST" read "$pane" 5 2>&1 >/dev/null)"
assert_contains "$err" "no recorded reply" "the fallback announces itself on stderr"
# stdout must stay clean: tests/test-coordination.sh and tests/test-panes.sh
# both pipe `roost read` into grep -q, and the site documents a bare
# `for w in ...; do roost read "$w"; done` loop.
assert_eq "$(printf '%s' "$out" | grep -c 'roost read:')" "0" \
  "the fallback notice never reaches stdout"

# --- roost screen -----------------------------------------------------------

out="$("$ROOST" screen "$pane" 5)"
assert_contains "$out" "SCREEN-NOISE" "roost screen returns the pane's screen"
err="$("$ROOST" screen "$pane" 5 2>&1 >/dev/null)"
assert_eq "$err" "" "roost screen never warns — the screen IS what it promises"

# screen ignores a recorded reply entirely; that is the point of having it
as_pane "$ROOST" reply "A RECORDED REPLY"
out="$("$ROOST" screen "$pane" 5)"
case "$out" in
  *"A RECORDED REPLY"*) assert_eq reply screen "roost screen ignores the recorded reply" ;;
  *) assert_eq ok ok "roost screen ignores the recorded reply" ;;
esac

# --- truncation is visible --------------------------------------------------

# tmux rejects an over-long COMMAND (measured: 16332 bytes accepted, 16333 not),
# so a long reply must be cut before it reaches set-option. Cut silently and a
# caller reads a confident, incomplete answer with no sign anything is missing.
tmux -S "$s" set-option -pu -t "$pane" @roost-reply
big="$(awk 'BEGIN{for(i=0;i<1200;i++) printf "line %05d padding padding padding\n", i}')"
as_pane "$ROOST" reply "$big"
got="$(stored)"
assert_contains "$got" "reply truncated" "an over-long reply is marked as truncated"
assert_contains "$got" "line 00000" "truncation keeps the HEAD of the reply"
[ "$(printf '%s' "$got" | wc -c)" -lt 16332 ] \
  && assert_eq ok ok "a truncated reply fits inside tmux's command-length limit" \
  || assert_eq "" fits "a truncated reply fits inside tmux's command-length limit"

# The cap is a BYTE budget, so a reply of multi-byte characters must be cut by
# bytes and must still be valid UTF-8 — bash counts ${#var} in CHARACTERS under
# a UTF-8 locale, and 12288 emoji would be 49152 bytes.
as_pane "$ROOST" reply "$(awk 'BEGIN{for(i=0;i<500;i++){for(j=0;j<40;j++) printf "\xf0\x9f\x90\x94"; printf "\n"}}')"
got="$(stored)"
[ "$(printf '%s' "$got" | wc -c)" -lt 16332 ] \
  && assert_eq ok ok "a multi-byte reply is capped by bytes, not characters" \
  || assert_eq "" fits "a multi-byte reply is capped by bytes, not characters"
# python3, NOT `iconv -f UTF-8 -t UTF-8`: macOS iconv rejects this byte string
# even though it decodes cleanly, so it would fail the suite on one platform
# and pass on the other — the same "passes on one OS, fails on the other" trap
# tests/lib.sh warns about for #{pane_current_command}. python3 is already a
# test-suite dependency (tests/test-contrast.py is a CI step); skip rather than
# fail if it is somehow absent, since this asserts a refinement of the
# byte-cap check above, which stands on its own.
if command -v python3 >/dev/null 2>&1; then
  if printf '%s' "$got" | python3 -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' 2>/dev/null; then
    assert_eq ok ok "truncation does not split a multi-byte character in half"
  else
    assert_eq invalid valid "truncation does not split a multi-byte character in half"
  fi
fi

# --- roost reply's guards ---------------------------------------------------

out="$(env -u TMUX -u TMUX_PANE "$ROOST" reply "nowhere" 2>&1)"; rc=$?
assert_eq "$rc" "0" "roost reply exits 0 outside tmux"
assert_eq "$out" "" "roost reply prints nothing outside tmux"

# A pane id from ANOTHER tmux server is a perfectly valid id on this one, so an
# unguarded write would land on a real, unrelated pane and report success.
other_dir="$(mktemp -d /tmp/amx.XXXX)"; other="$other_dir/roost"
tmux -S "$other" -f /dev/null new-session -d
tmux -S "$s" set-option -pu -t "$pane" @roost-reply
env TMUX="$other,$(tmux -S "$other" display -p '#{pid}'),0" TMUX_PANE="$pane" \
  "$ROOST" reply "FROM ANOTHER SERVER"
assert_eq "$(stored)" "" "roost reply from another server's pane writes nothing here"
tmux -S "$other" kill-server 2>/dev/null; rm -rf "$other_dir"

# --- the Claude Stop hook ---------------------------------------------------

payload='{"session_id":"x","hook_event_name":"Stop","last_assistant_message":"HOOK line 1\nHOOK \"quoted\" line 2"}'
tmux -S "$s" set-option -p -t "$pane" @agent_state working
printf '%s' "$payload" | env TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/scripts/roost-agent-state" done --stop-hook
assert_eq "$(stored)" $'HOOK line 1\nHOOK "quoted" line 2' \
  "the Stop hook records last_assistant_message as the reply"
assert_eq "$(tmux -S "$s" show-options -pqv -t "$pane" @agent_state)" "done" \
  "the Stop hook still badges the pane done"

# The reply write sits ABOVE the unchanged-state early bail. A Stop arriving
# when the pane already reads done — a turn with no UserPromptSubmit, a
# re-entrant stop — must not skip straight past the recording and leave the
# PREVIOUS turn's reply in place.
printf '%s' '{"last_assistant_message":"SECOND TURN"}' \
  | env TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/scripts/roost-agent-state" done --stop-hook
assert_eq "$(stored)" "SECOND TURN" \
  "a Stop on an already-done pane still records the new reply"

# Without the flag nothing is read from stdin, so a plain `roost state done` --
# which a human may type at a terminal -- can never block on a `cat` that never
# sees EOF, and never clobbers a recorded reply either.
printf '%s' '{"last_assistant_message":"MUST NOT BE READ"}' \
  | env TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/scripts/roost-agent-state" working
assert_eq "$(stored)" "SECOND TURN" \
  "roost-agent-state without --stop-hook does not read stdin"

# An empty or malformed payload records nothing rather than an empty reply: an
# empty @roost-reply would read as "no reply" and fall back, which is the right
# outcome, but writing one would still be pointless work on the hot path out.
tmux -S "$s" set-option -pu -t "$pane" @roost-reply
printf '%s' 'not json at all' \
  | env TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/scripts/roost-agent-state" done --stop-hook
assert_eq "$(stored)" "" "a malformed Stop payload records no reply"

# --- discoverability --------------------------------------------------------

usage="$("$ROOST" not-a-command 2>&1 || true)"
assert_contains "$usage" "screen" "roost screen appears in the usage line"
assert_contains "$usage" "reply" "roost reply appears in the usage line"
help="$("$ROOST" help 2>&1 || true)"
assert_contains "$help" "roost screen" "roost screen appears in the help text"
assert_contains "$help" "roost reply" "roost reply appears in the help text"

# The hook config roost prints must carry the flag, or every user who follows
# the documented setup gets a silently reply-less install.
assert_contains "$("$ROOST" hooks)" "done --stop-hook" \
  "roost hooks wires the Stop hook with --stop-hook"
