#!/usr/bin/env bash
# tests/test-send-readiness.sh — `roost send` into a pane that is still STARTING.
#
# The bug, as measured in the field: a 3466-byte brief was sent to a freshly
# spawned Claude pane. Roughly the last 450 bytes arrived; the FRONT was gone.
# `roost send` exited 0 and reported delivery.
#
# That is not the ~16344-byte tmux command cap — 3466 is nowhere near it. It is
# a cold-start race. `roost spawn` prints the pane id the moment the PANE
# exists, which is well before the agent inside it is reading its terminal, and
# a TUI takes the tty over by putting it in raw mode and DISCARDING whatever is
# already buffered. Everything typed before that instant is destroyed, and the
# remainder arrives looking exactly like a whole message.
#
# `roost send`'s verification could not see it because it verified the SUBMIT
# and never the CONTENT: it checked that the input line had stopped holding the
# message, which a half-eaten message satisfies just as well as a whole one.
#
# tests/fixtures/cold-start-tui.py models that sequence and nothing else. Its
# startup delay is a parameter, so the same fixture gives a pane that is ready
# instantly, one that is ready after a beat, and one that is never ready inside
# the budget. Submitted lines go to a FILE, never to the screen, so text left
# sitting in the input box can never be counted as a delivery.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"

if ! command -v python3 >/dev/null 2>&1; then
  echo "  SKIP: python3 not available (the cold-start model needs termios)"
  exit 0
fi

sdir="$(mktemp -d /tmp/amx.XXXX)"; s="$sdir/roost"
trap 'tmux -S "$s" kill-server 2>/dev/null; rm -rf "$sdir"' EXIT
export ROOST_SOCKET="$s"
FIXTURE="$HERE/tests/fixtures/cold-start-tui.py"

n=0
pane_for() {  # pane_for DELAY -> prints "PANE_ID SUBMITTED_FILE"
  n=$((n+1))
  local f="$sdir/submitted.$n" p
  : > "$f"
  if [ "$n" = 1 ]; then
    tmux -S "$s" -f /dev/null new-session -d -x 200 -y 50 \
      "exec python3 -u $FIXTURE $1 $f"
    p="$(tmux -S "$s" display -p '#{pane_id}')"
  else
    p="$(tmux -S "$s" new-window -P -F '#{pane_id}' -d "exec python3 -u $FIXTURE $1 $f")"
  fi
  printf '%s %s' "$p" "$f"
}

MSG="HEAD-MARKER-0001 the front of this message is what a cold start eats, and it is the part nobody was checking TAIL-MARKER-9999"

# --- the harness must be able to PASS before any failure means anything ------
#
# A probe whose own setup is broken delivers nothing and reports nothing
# changed, which is indistinguishable from the bug it is hunting. So the first
# case is a pane that is ready before the send starts. If the message does not
# arrive whole HERE, every "the head is missing" line below is measuring a
# broken fixture rather than roost.
read -r p f <<<"$(pane_for 0)"
sleep 1.0
"$ROOST" send "$p" "$MSG" >/dev/null 2>&1; rc=$?
sleep 0.8
got="$(cat "$f" 2>/dev/null || true)"
assert_eq "$rc" "0" "detector proof: send into an ALREADY-READY pane exits 0"
assert_contains "$got" "HEAD-MARKER-0001" "detector proof: the fixture submits a whole message"
assert_contains "$got" "TAIL-MARKER-9999" "detector proof: the fixture submits it to the end"

# --- and it must be able to FAIL, or a green run proves nothing either -------
#
# Plant the defect by hand: type into the pane during its startup window, the
# way the unfixed `roost send` did, and confirm the bytes really are destroyed.
# Without this line a green suite could mean "roost is fixed" or "this fixture
# never lost anything in the first place", and those look identical.
read -r p f <<<"$(pane_for 2.0)"
tmux -S "$s" send-keys -t "$p" -l -- "SWALLOWED-BY-THE-RACE"
sleep 3.0
tmux -S "$s" send-keys -t "$p" -l -- "TYPED-AFTER-READY"
tmux -S "$s" send-keys -t "$p" Enter
sleep 0.6
got="$(cat "$f" 2>/dev/null || true)"
assert_contains "$got" "TYPED-AFTER-READY" \
  "detector proof: the fixture does accept keys once it is ready"
case "$got" in
  *"SWALLOWED-BY-THE-RACE"*) assert_eq "survived" "swallowed" \
     "detector proof: the fixture really destroys keys typed before it is ready" ;;
  *) assert_eq ok ok \
     "detector proof: the fixture really destroys keys typed before it is ready" ;;
esac

# --- 1. the message must arrive WHOLE, head included ------------------------

read -r p f <<<"$(pane_for 2.0)"
"$ROOST" send "$p" "$MSG" >/dev/null 2>&1; rc=$?
sleep 0.8
got="$(cat "$f" 2>/dev/null || true)"
assert_contains "$got" "HEAD-MARKER-0001" "send into a STARTING pane delivers the head"
assert_contains "$got" "TAIL-MARKER-9999" "send into a STARTING pane delivers the tail"
assert_eq "$rc" "0" "send into a STARTING pane exits 0 once it has delivered"
# Retyping is how the race is beaten, so the message must arrive ONCE, not
# twice: a peer briefed twice is a different bug, not a fix.
assert_eq "$(printf '%s\n' "$got" | grep -c 'HEAD-MARKER-0001')" "1" \
  "send into a STARTING pane delivers the message exactly once"

# --- 2. exit 0 must never mean a partial delivery ---------------------------
#
# This assertion outranks the one above. Delivering the whole message is the
# goal; never CLAIMING to have delivered it is the contract. A pane still
# starting when the budget runs out must produce a non-zero exit, so a caller
# in a loop retries instead of moving on believing its peer was briefed.
tmux -S "$s" set-option -g @roost-send-ready-timeout 2
read -r p f <<<"$(pane_for 30)"
err="$("$ROOST" send "$p" "$MSG" 2>&1 >/dev/null)"; rc=$?
sleep 0.3
got="$(cat "$f" 2>/dev/null || true)"
assert_eq "$got" "" "the never-ready pane really did submit nothing"
[ "$rc" -ne 0 ] \
  && assert_eq ok ok "send exits NON-ZERO when it cannot prove the message landed" \
  || assert_eq "exit 0" "non-zero" "send exits NON-ZERO when it cannot prove the message landed"
assert_contains "$err" "nothing was submitted" \
  "...and says plainly that nothing was submitted"
tmux -S "$s" set-option -gu @roost-send-ready-timeout

# --- 3. the over-long message must name its real cause ----------------------
#
# tmux rejects the whole `send-keys` COMMAND above ~16344 bytes. Nothing is
# ever half-typed there — that part was already safe — but the pane is alive
# and idle, so "pane may have died" sent the caller to look at the one thing
# that was not wrong.
read -r p f <<<"$(pane_for 0)"
sleep 1.0
big="$(LC_ALL=C awk 'BEGIN{s="";while(length(s)<20000)s=s "z";printf "%s", substr(s,1,20000)}')"
err="$("$ROOST" send "$p" "$big" 2>&1 >/dev/null)"; rc=$?
assert_eq "$rc" "1" "an over-long message exits 1"
assert_contains "$err" "too long" "an over-long message says it is too long"
assert_contains "$err" "16344" "an over-long message names the limit it must get under"
assert_contains "$err" "20000" "an over-long message names how long it actually was"
case "$err" in
  *"may have died"*) assert_eq "blames the pane" "names the length" \
     "an over-long message does not blame the pane" ;;
  *) assert_eq ok ok "an over-long message does not blame the pane" ;;
esac
assert_eq "$(cat "$f" 2>/dev/null || true)" "" \
  "an over-long message submits nothing at all"
