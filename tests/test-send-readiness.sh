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
pane_for() {  # pane_for DELAY [HEADCUT] -> prints "PANE_ID SUBMITTED_FILE"
  n=$((n+1))
  local f="$sdir/submitted.$n" p
  : > "$f"
  if [ "$n" = 1 ]; then
    tmux -S "$s" -f /dev/null new-session -d -x 200 -y 50 \
      "exec python3 -u $FIXTURE $1 $f ${2:-0}"
    p="$(tmux -S "$s" display -p '#{pane_id}')"
  else
    p="$(tmux -S "$s" new-window -P -F '#{pane_id}' -d "exec python3 -u $FIXTURE $1 $f ${2:-0}")"
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

# --- 1b. a message cut ABOVE tmux and BELOW the agent -----------------------
#
# A second loss, reported from the field and NOT explained by the startup race.
# Two briefs, 3466 and 3502 bytes, were cut at offsets 3067 and 3066: mid-word,
# head discarded, tail kept, `roost send` exit 0 both times. The control that
# matters: the same 3502 bytes were pushed through `send-keys -l` to a
# throwaway socket with a plain reader, and again with that reader asleep for
# five seconds. 3501 of 3502 arrived both times. tmux delivers it.
#
# A near-CONSTANT discarded prefix across two different message lengths is the
# signature of a fixed boundary, not of a timing race, so this case is separate
# from the startup one above and the fixture models it separately.
#
# What is asserted here is the CONTRACT, not the mechanism, because the
# mechanism is not known: `roost send` must not report success over a message
# whose front was destroyed. Whether it recovers depends on whether the real
# ceiling repeats on a retyped message, which nobody has measured — so both
# outcomes are accepted, and only a silent exit 0 over a cut message is not.
read -r p f <<<"$(pane_for 0 3066)"
sleep 1.0
BIG_MSG="HEAD-MARKER-0001 $(LC_ALL=C awk 'BEGIN{s="";while(length(s)<3400)s=s "q";printf "%s", substr(s,1,3400)}') TAIL-MARKER-9999"
# Detector proof: the pane really does destroy the front. Type it by hand first,
# the way the unfixed send did, and confirm the head is gone and the tail is not
# — otherwise the assertion below would be measuring a fixture that cuts nothing.
tmux -S "$s" send-keys -t "$p" -l -- "$BIG_MSG"
tmux -S "$s" send-keys -t "$p" Enter
sleep 1.0
raw_got="$(cat "$f" 2>/dev/null || true)"
assert_contains "$raw_got" "TAIL-MARKER-9999" \
  "detector proof: the head-cut fixture keeps the tail"
case "$raw_got" in
  *"HEAD-MARKER-0001"*) assert_eq "survived" "cut" \
     "detector proof: the head-cut fixture really destroys the front" ;;
  *) assert_eq ok ok "detector proof: the head-cut fixture really destroys the front" ;;
esac

read -r p f <<<"$(pane_for 0 3066)"
sleep 1.0
err="$("$ROOST" send "$p" "$BIG_MSG" 2>&1 >/dev/null)"; rc=$?
sleep 0.8
got="$(cat "$f" 2>/dev/null || true)"
whole=no; case "$got" in *"HEAD-MARKER-0001"*"TAIL-MARKER-9999"*) whole=yes ;; esac
if [ "$rc" -eq 0 ]; then
  assert_eq "$whole" "yes" \
    "a head-cut pane is never reported as a clean send unless the message really got through"
else
  assert_contains "$err" "roost send:" \
    "a head-cut pane that cannot be recovered fails loudly"
  assert_eq ok ok "a head-cut pane is never reported as a clean send"
fi

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

# --- 3. the old ~16344-byte command ceiling is GONE ---------------------------
#
# It was never a property of the message, only of how the message travelled:
# `send-keys -l` puts the whole text on a tmux COMMAND LINE, and tmux refuses a
# command over ~16384 bytes. The text now goes over STDIN to `load-buffer`, so
# the ceiling does not apply to it at all. This used to assert exit 1 and an
# error naming 16344; it asserts delivery instead, which is the same fact from
# the other side.
read -r p f <<<"$(pane_for 0)"
sleep 1.0
big="HEAD-MARKER-0001 $(LC_ALL=C awk 'BEGIN{s="";while(length(s)<20000)s=s "z";printf "%s", substr(s,1,20000)}') TAIL-MARKER-9999"
err="$("$ROOST" send "$p" "$big" 2>&1 >/dev/null)"; rc=$?
sleep 1.2
got="$(cat "$f" 2>/dev/null || true)"
assert_eq "$rc" "0" "a 20KB message now exits 0 — the command-length ceiling is gone"
assert_contains "$got" "HEAD-MARKER-0001" "a 20KB message delivers its head"
assert_contains "$got" "TAIL-MARKER-9999" "a 20KB message delivers its tail"
assert_eq "$(printf '%s\n' "$got" | grep -c 'HEAD-MARKER-0001')" "1" \
  "a 20KB message is delivered exactly once"
