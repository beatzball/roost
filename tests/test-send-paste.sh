#!/usr/bin/env bash
# tests/test-send-paste.sh — `roost send` delivers a BRACKETED PASTE, and leaves
# nothing behind when it does.
#
# WHY THE TRANSPORT CHANGED. `send-keys -l` types the message as very fast
# keystrokes. Claude Code 2.1.263 answers that by keeping only the last partial
# chunk: measured, discarded = 1022 * floor(n/1022), so a 3502-byte brief
# arrives as its last 436 bytes and the agent never sees the front. A bracketed
# paste is a different thing to the receiving application — the \e[200~ and
# \e[201~ markers say "one block of pasted text, not typing" — and the same
# bytes then arrive whole, proven upstream by putting the instruction at the
# very START of the message and getting it obeyed.
#
# WHY THE HYGIENE IS TESTED RATHER THAN COMMENTED. A tmux buffer is not private
# scratch space: the human can see every one of them at `prefix + =`, and an
# agent's message can carry things nobody wants sitting in a picker. Three
# rules, one test each, and each test is shown to be capable of failing before
# it is trusted:
#
#   1. ONE named buffer, reused, so sends cannot pile up.
#   2. `paste-buffer -d`, so it is gone the instant it is pasted.
#   3. Never `-w`, which is the flag that would reach the SYSTEM clipboard.
#
# And the failure paths, because a send that gives up between the load and the
# paste would otherwise leave the whole message in the buffer list.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"

if ! command -v python3 >/dev/null 2>&1; then
  echo "  SKIP: python3 not available (the input-box model needs termios)"
  exit 0
fi

sdir="$(mktemp -d /tmp/amx.XXXX)"; s="$sdir/roost"
trap 'tmux -S "$s" kill-server 2>/dev/null; rm -rf "$sdir"' EXIT
export ROOST_SOCKET="$s"
FIXTURE="$HERE/tests/fixtures/cold-start-tui.py"
n=0
pane_for() {  # pane_for DELAY [collapse]
  n=$((n+1)); local f="$sdir/submitted.$n" p
  : > "$f"
  if [ "$n" = 1 ]; then
    tmux -S "$s" -f /dev/null new-session -d -x 200 -y 50 "exec python3 -u $FIXTURE $1 $f 0 ${2:-}"
    p="$(tmux -S "$s" display -p '#{pane_id}')"
  else
    p="$(tmux -S "$s" new-window -P -F '#{pane_id}' -d "exec python3 -u $FIXTURE $1 $f 0 ${2:-}")"
  fi
  printf '%s %s' "$p" "$f"
}
bufs() { tmux -S "$s" list-buffers 2>/dev/null | grep -c 'roost-send' | tr -d ' '; }

# --- 1. the transport really is a bracketed paste ---------------------------
#
# The fixture consumes \e[200~ / \e[201~ the way a real TUI does, so a message
# that arrives whole through it is evidence about the escape sequence only if
# the fixture is first shown to NOTICE the markers. Plant one by hand: a raw
# send-keys of the marker text must land in the submitted line, and a real
# bracketed paste of the same text must not.
read -r p f <<<"$(pane_for 0)"
sleep 1.0
tmux -S "$s" send-keys -t "$p" -l -- $'\e[200~MARKERS-AS-TEXT\e[201~'
tmux -S "$s" send-keys -t "$p" Enter; sleep 0.6
assert_eq "$(grep -c 'MARKERS-AS-TEXT' "$f" 2>/dev/null || echo 0)" "1" \
  "detector proof: the fixture receives what is typed at it"
got="$(cat "$f")"
case "$got" in
  *'['200'~'*) assert_eq "echoed" "consumed" \
     "detector proof: the fixture CONSUMES bracketed-paste markers" ;;
  *) assert_eq ok ok "detector proof: the fixture CONSUMES bracketed-paste markers" ;;
esac

read -r p f <<<"$(pane_for 0)"
sleep 1.0
msg="PASTE-HEAD-0001 $(LC_ALL=C awk 'BEGIN{s="";while(length(s)<4000)s=s "p";printf "%s", substr(s,1,4000)}') PASTE-TAIL-9999"
"$ROOST" send "$p" "$msg" >/dev/null 2>&1
sleep 1.2
got="$(cat "$f" 2>/dev/null || true)"
assert_contains "$got" "PASTE-HEAD-0001" "send delivers the head of a 4KB message"
assert_contains "$got" "PASTE-TAIL-9999" "send delivers the tail of a 4KB message"

# --- 2. one named buffer, and it does not survive the send -------------------

assert_eq "$(bufs)" "0" "no roost-send buffer is left behind after a send"

# The check above is worthless unless it can see a buffer that IS there. Plant
# one under the same name and confirm it counts, then remove it.
printf '%s' "planted" | tmux -S "$s" load-buffer -b roost-send -
assert_eq "$(bufs)" "1" "detector proof: the buffer check can see a roost-send buffer"
tmux -S "$s" delete-buffer -b roost-send 2>/dev/null || true
assert_eq "$(bufs)" "0" "detector proof: ...and sees it go away again"

# Sends must not pile up: ten of them, still nothing left.
read -r p f <<<"$(pane_for 0)"
sleep 1.0
i=0; while [ "$i" -lt 10 ]; do "$ROOST" send "$p" "pile-$i" >/dev/null 2>&1; i=$((i+1)); done
assert_eq "$(bufs)" "0" "ten sends leave no roost-send buffer"
# ...and the buffer stack has not grown by ten under other names either.
assert_eq "$(tmux -S "$s" list-buffers 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "ten sends add nothing at all to the buffer stack"

# --- 3. the FAILURE path cleans up too --------------------------------------
#
# A send that gives up after loading the buffer must not leave the message in
# the list. The never-ready pane is the reachable version of that: it fails the
# landing check and exits 1 with the buffer already loaded.
tmux -S "$s" set-option -g @roost-send-ready-timeout 2
read -r p f <<<"$(pane_for 30)"
"$ROOST" send "$p" "SECRET-THAT-MUST-NOT-LINGER" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "a send to a never-ready pane still fails"
assert_eq "$(bufs)" "0" "a FAILED send leaves no roost-send buffer behind"
assert_eq "$(tmux -S "$s" list-buffers 2>/dev/null | grep -c 'SECRET-THAT-MUST-NOT-LINGER')" "0" \
  "a failed send's text is not in the buffer stack"
tmux -S "$s" set-option -gu @roost-send-ready-timeout

# The case above does NOT exercise the cleanup trap, and mutation testing is
# how that was found: removing the trap entirely left every assertion green.
# The reason is that a never-ready pane still ACCEPTS the paste — the bytes go
# into its tty and `-d` deletes the buffer on the way — so the buffer is gone
# without the trap doing anything.
#
# The trap only matters when the paste itself fails after the load succeeded,
# which needs the pane to die mid-send. That is arranged here rather than raced:
# the send is given a long budget against a pane that will never be ready, and
# the pane is killed while its retry loop is running, so a later load-buffer has
# no paste to follow it.
tmux -S "$s" set-option -g @roost-send-ready-timeout 12
read -r p f <<<"$(pane_for 60)"
( "$ROOST" send "$p" "SECRET-KILLED-MID-SEND" >/dev/null 2>&1 ) &
sendpid=$!
sleep 4
tmux -S "$s" kill-pane -t "$p" 2>/dev/null || true
wait "$sendpid" 2>/dev/null || true
assert_eq "$(bufs)" "0" \
  "a send whose pane DIES mid-flight leaves no roost-send buffer"
assert_eq "$(tmux -S "$s" list-buffers 2>/dev/null | grep -c 'SECRET-KILLED-MID-SEND')" "0" \
  "...and its text is nowhere in the buffer stack"
tmux -S "$s" set-option -gu @roost-send-ready-timeout

# --- 4. never -w ------------------------------------------------------------
#
# `-w` is the flag that would push the buffer to the SYSTEM clipboard. Asserted
# on the source, not on the clipboard: a test that actually wrote to the
# developer's pasteboard to prove roost does not would be the only thing in the
# suite that did.
assert_eq "$(grep -c 'paste-buffer' "$HERE/bin/roost")" "1" \
  "there is exactly one paste-buffer call to audit"
case "$(grep 'paste-buffer' "$HERE/bin/roost")" in
  *-w*) assert_eq "passes -w" "never -w" "roost send never passes -w to paste-buffer" ;;
  *)    assert_eq ok ok "roost send never passes -w to paste-buffer" ;;
esac
assert_contains "$(grep 'paste-buffer' "$HERE/bin/roost")" "-d" \
  "the paste-buffer call carries -d"
assert_contains "$(grep 'paste-buffer' "$HERE/bin/roost")" "-p" \
  "the paste-buffer call carries -p (bracketed paste)"

# --- 5. a pane that COLLAPSES the paste ---------------------------------------
#
# The real-world rendering, and the one that broke this fix the first time it
# met a live agent: Claude Code draws `[Pasted text #N]` instead of the text, so
# the message is nowhere on screen and the head check can never match. Measured
# live before this branch existed — roost retyped seven times and exited 1
# having submitted nothing, against exactly the target it exists to drive.
read -r p f <<<"$(pane_for 0 collapse)"
sleep 1.0
msg="COLLAPSE-HEAD-0001 $(LC_ALL=C awk 'BEGIN{s="";while(length(s)<3000)s=s "c";printf "%s", substr(s,1,3000)}') COLLAPSE-TAIL-9999"
err="$("$ROOST" send "$p" "$msg" 2>&1 >/dev/null)"; rc=$?
sleep 1.2
got="$(cat "$f" 2>/dev/null || true)"

# Detector proof: the pane really did hide the text behind a placeholder. If it
# echoed after all, the assertions below would be testing the ordinary path
# under a misleading name.
scr="$(tmux -S "$s" capture-pane -p -t "$p" 2>/dev/null | tr -d '[:space:]')"
assert_contains "$scr" "Pastedtext" \
  "detector proof: the collapsing pane really shows a placeholder"
case "$scr" in
  *COLLAPSE-HEAD-0001*) assert_eq "on screen" "hidden" \
     "detector proof: ...and the message really is not on screen" ;;
  *) assert_eq ok ok "detector proof: ...and the message really is not on screen" ;;
esac

assert_eq "$rc" "0" "a send to a pane that collapses the paste still exits 0"
assert_contains "$got" "COLLAPSE-HEAD-0001" "...and the head is delivered"
assert_contains "$got" "COLLAPSE-TAIL-9999" "...and the tail is delivered"
assert_eq "$(printf '%s\n' "$got" | grep -c 'COLLAPSE-HEAD-0001')" "1" \
  "...exactly once, with no retype pile-up"
# A placeholder accounts for the missing text, so it is the expected success
# rendering, not an unknown. Warning here would fire on every long send to a
# real agent and train the reader to ignore the notice where it matters.
# The one line taken out is #177's: this fixture has no badge, so `send` says
# there is no turn number, and that is about the turn, not the paste.
assert_eq "$(printf '%s\n' "$err" | grep -v "^roost send: no turn number: " || true)" "" \
  "...and roost does not cry wolf about a placeholder it can explain"

# --- 6. other harnesses' placeholders (#176) ----------------------------------
#
# Claude is not the only TUI that collapses a paste. pi draws `[paste #N +K
# lines]` or `[paste #N K chars]` and opencode 2 draws `[Pasted ~K lines]`, and
# before this section existed neither was recognised: every long send to them
# ran the whole @roost-send-ready-timeout loop (15 s), re-pasted after a C-u up
# to seven times, then printed "accepted the keys but does not show them" and
# exited 0 after about 19 s. Measured in a real four-agent run, all four long
# sends — and the agents read the false warning as a failed delivery.
#
# pane_draw TEMPLATE [PLANT] — a collapsing pane that draws TEMPLATE (see the
# fixture) when a paste closes. PLANT is printed before the fixture starts, so
# it is on the screen as a left-over from "an earlier send" that nothing
# erases. TEMPLATE `collapse` is Claude's own placeholder, drawn by the fixture.
#
# mktemp, not pane_for's counter: pane_for runs in a $(...), so its n=$((n+1))
# never reaches this shell and every pane it makes shares one submitted file.
# The paste log below has to be per pane or it counts other panes' pastes.
pane_draw() {
  local d f mode p
  d="$(mktemp -d "$sdir/draw.XXXX")"; f="$d/submitted"
  : > "$f"; printf '%s\n' "$1" > "$d/template"; printf '%s\n' "${2:-}" > "$d/plant"
  case "$1" in collapse) mode="collapse" ;; *) mode="draw $d/template" ;; esac
  p="$(tmux -S "$s" new-window -P -F '#{pane_id}' -d "cat $d/plant; exec python3 -u $FIXTURE 0 $f 0 $mode")"
  printf '%s %s' "$p" "$f"
}
ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
twelve_lines() {  # twelve_lines HEAD — a 12-line message whose first line is HEAD
  local i=2; printf '%s first line of a multi-line brief' "$1"
  while [ "$i" -le 12 ]; do printf '\nline %d of the brief' "$i"; i=$((i+1)); done
}
long_line() {  # long_line HEAD — one line of about 4200 characters
  printf '%s %s' "$1" "$(LC_ALL=C awk 'BEGIN{s="";while(length(s)<4190)s=s "q";printf "%s", s}')"
}

# fast_send LABEL PANE FILE HEAD MSG GREP — the send is quick, quiet, exit 0,
# delivered whole and once, and pasted ONCE (the fixture logs every paste block
# to FILE.pastes). GREP is a fixed string the placeholder must show.
fast_send() {
  local label="$1" p="$2" f="$3" head="$4" msg="$5" grep_for="$6" t0 t1 err rc scr shown
  sleep 1.0
  t0="$(ms)"
  err="$("$ROOST" send "$p" "$msg" 2>&1 >/dev/null)"; rc=$?
  t1="$(ms)"
  sleep 0.8
  scr="$(tmux -S "$s" capture-pane -p -t "$p" 2>/dev/null)"
  # Detector proof: the screen shows the placeholder and NOT the message, or
  # the assertions below would be about the ordinary echoing path.
  assert_contains "$scr" "$grep_for" "$label: detector proof: the pane draws its placeholder"
  case "$(printf '%s' "$scr" | tr -d '[:space:]')" in
    *"$head"*) shown="on screen" ;;
    *) shown="hidden" ;;
  esac
  assert_eq "$shown" "hidden" "$label: detector proof: the message is not on screen"
  assert_eq "$rc" "0" "$label: send exits 0"
  # #177's "no turn number" line is about the turn, not the paste: these
  # fixtures carry no badge. Taken out the same way as in section 5.
  assert_eq "$(printf '%s\n' "$err" | grep -v "^roost send: no turn number: " || true)" "" \
    "$label: send prints no warning"
  [ $((t1 - t0)) -lt 3000 ]; assert_true $? "$label: send returns in under 3 s (took $((t1 - t0)) ms)"
  assert_eq "$(grep -c "$head" "$f" 2>/dev/null || echo 0)" "1" "$label: the message is submitted exactly once"
  assert_eq "$(cat "$f.pastes" 2>/dev/null | wc -l | tr -d ' ')" "1" \
    "$label: one paste, no re-paste"
}

read -r p f <<<"$(pane_draw '[paste #%(n)d +%(lines)d lines]')"
fast_send "pi lines" "$p" "$f" "PI-LINES-HEAD-0001" "$(twelve_lines PI-LINES-HEAD-0001)" "[paste #"
assert_contains "$(tmux -S "$s" capture-pane -p -t "$p")" " +12 lines]" \
  "pi lines: detector proof: the placeholder carries the line count"

read -r p f <<<"$(pane_draw '[paste #%(n)d %(chars)d chars]')"
fast_send "pi chars" "$p" "$f" "PI-CHARS-HEAD-0001" "$(long_line PI-CHARS-HEAD-0001)" "[paste #"

read -r p f <<<"$(pane_draw '[Pasted ~%(lines)d lines]')"
fast_send "opencode 2" "$p" "$f" "OC2-HEAD-0001" "$(twelve_lines OC2-HEAD-0001)" "[Pasted ~"

read -r p f <<<"$(pane_draw collapse)"
fast_send "claude" "$p" "$f" "CLAUDE-HEAD-0001" "$(twelve_lines CLAUDE-HEAD-0001)" "[Pasted text #"

# slow_send LABEL PANE FILE HEAD — nothing roost can recognise appeared, so the
# old slow path runs to its (shortened) bound and the warning is printed. Still
# exit 0 and still delivered once: this is the "loud and slow, not lossy" side.
slow_send() {
  local label="$1" p="$2" f="$3" head="$4" t0 t1 err rc
  sleep 1.0
  t0="$(ms)"
  err="$("$ROOST" send "$p" "$(twelve_lines "$head")" 2>&1 >/dev/null)"; rc=$?
  t1="$(ms)"
  sleep 0.8
  assert_eq "$rc" "0" "$label: send still exits 0"
  assert_contains "$err" "does not show them" "$label: the could-not-verify warning is printed"
  [ $((t1 - t0)) -ge 2000 ]; assert_true $? "$label: the slow path ran to its bound (took $((t1 - t0)) ms)"
  assert_eq "$(grep -c "$head" "$f" 2>/dev/null || echo 0)" "1" "$label: the message is submitted exactly once"
}
tmux -S "$s" set-option -g @roost-send-ready-timeout 2

# A placeholder left on screen by an EARLIER send proves nothing about this
# one. All three shapes are planted, and the pane then draws only `*` for the
# new paste: the screen changes, but no placeholder is new.
read -r p f <<<"$(pane_draw '*' '[Pasted text #1 +12 lines] [paste #1 +12 lines] [paste #2 4210 chars] [Pasted ~12 lines]')"
slow_send "old placeholders" "$p" "$f" "OLD-PLACEHOLDER-HEAD-0001"

# Look-alikes outside the family: a bracket and the word, but no number.
read -r p f <<<"$(pane_draw '[pasted]')"
slow_send "look-alike [pasted]" "$p" "$f" "LOOKALIKE-A-HEAD-0001"
read -r p f <<<"$(pane_draw '[paste]')"
slow_send "look-alike [paste]" "$p" "$f" "LOOKALIKE-B-HEAD-0001"

tmux -S "$s" set-option -gu @roost-send-ready-timeout
