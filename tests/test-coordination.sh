#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
AMUX="$HERE/bin/amux"
amux_test_server; sock="$AMUX_TEST_SOCK"; trap amux_test_teardown EXIT
export AMUX_SOCKET="$sock"   # bin/amux talks to the isolated test server (path → -S)

# a shell window to receive input; capture its canonical target
recv="$(T new-window -P -F '#{session_name}:#{window_index}' -n recv)"

# Poll the pane for a pattern (up to ~4s) instead of a fixed sleep — the receiving
# shell's execution+render can lag on a loaded machine, which would flake a
# fixed `sleep 1`.
wait_for() { # wait_for TARGET PATTERN
  local tgt="$1" pat="$2" n=20
  while [ "$n" -gt 0 ]; do
    T capture-pane -p -t "$tgt" 2>/dev/null | grep -q "$pat" && return 0
    sleep 0.2; n=$((n - 1))
  done
  return 1
}

# send reliability: a two-step submit must actually EXECUTE the command.
# "MARK-DONE" (contiguous) can only appear from execution, not from the typed line.
"$AMUX" send "$recv" "printf 'MARK-%s\n' DONE"
wait_for "$recv" 'MARK-DONE' \
  && assert_eq ok ok "send delivers text AND submits (two-step Enter works)" \
  || assert_eq no-exec executed "send delivers text AND submits (two-step Enter works)"

# literal text: a message containing the word Enter is typed as text, executed once
"$AMUX" send "$recv" "echo hi-Enter-bye"
wait_for "$recv" 'hi-Enter-bye' \
  && assert_eq ok ok "message text is literal (the word Enter is not a keypress)" \
  || assert_eq no-exec executed "message text is literal (the word Enter is not a keypress)"

# validation: a bogus target fails loudly (exit 2), delivers nothing
out="$("$AMUX" send "nope:99" "x" 2>&1)"; rc=$?
assert_eq "$rc" "2" "send to a bad target exits 2"
assert_contains "$out" "no such target" "send to a bad target explains why"

# a non-numeric @amux-send-enter-delay must NOT break send — it falls back to 0.3
# and still submits (no abort with the text left unsent).
T set-option -g @amux-send-enter-delay "not-a-number"
"$AMUX" send "$recv" "printf 'DELAY-%s\n' OK"; rc=$?
assert_eq "$rc" "0" "send survives a garbage @amux-send-enter-delay (exit 0)"
wait_for "$recv" 'DELAY-OK' \
  && assert_eq ok ok "send still submits despite a garbage delay value" \
  || assert_eq no-exec executed "send still submits despite a garbage delay value"
T set-option -gu @amux-send-enter-delay 2>/dev/null || true

# a dot-heavy delay (e.g. "1.2.3") slips a char-class guard but must NOT leave the
# prompt half-delivered — it falls back to 0.3 and the sleep can't abort.
T set-option -g @amux-send-enter-delay "1.2.3"
"$AMUX" send "$recv" "printf 'DOT-%s\n' OK"; rc=$?
assert_eq "$rc" "0" "send survives a dot-heavy delay value (exit 0)"
wait_for "$recv" 'DOT-OK' \
  && assert_eq ok ok "send still submits with a dot-heavy delay value" \
  || assert_eq no-exec executed "send still submits with a dot-heavy delay value"
T set-option -gu @amux-send-enter-delay 2>/dev/null || true

# --- whoami ---
pane="$(T display-message -p -t "$recv" '#{pane_id}')"
me="$(TMUX_PANE="$pane" "$AMUX" whoami)"
assert_eq "$me" "$recv" "whoami prints the caller's session:index"

out="$(env -u TMUX_PANE "$AMUX" whoami 2>&1)"; rc=$?
assert_eq "$rc" "1" "whoami outside an amux pane exits 1"
assert_contains "$out" "not inside an amux session" "whoami explains it's outside amux"

# --- spawn ---
active_win() { T list-windows -F '#{window_active} #{window_index}' | awk '$1==1{print $2}'; }
before="$(T list-windows | wc -l | tr -d ' ')"
active_before="$(active_win)"
new="$(TMUX_PANE="$pane" "$AMUX" spawn helper)"
after="$(T list-windows | wc -l | tr -d ' ')"
assert_eq "$after" "$((before + 1))" "spawn creates a new window"
# spawn must NOT steal focus — the session's active window is unchanged (-d).
assert_eq "$(active_win)" "$active_before" "spawn creates in the background (does not switch the active window)"
assert_eq "$(T display-message -p -t "$new" '#{window_name}')" "helper" "spawn names the window"
# the printed target resolves (proves format + that spawn returned, i.e. did not attach)
assert_contains "$new" ":" "spawn prints a session:index target"
[ -n "$(T display-message -p -t "$new" '#{window_id}')" ] \
  && assert_eq ok ok "spawn's printed target resolves to a live window" \
  || assert_eq "" live "spawn's printed target resolves to a live window"

# spawn with a CMD runs it in the new window
new2="$(TMUX_PANE="$pane" "$AMUX" spawn helper2 true)"
assert_contains "$new2" ":" "spawn NAME CMD prints a target"

# --- switcher target column (unit-check the row format; fzf needs a tty) ---
# fields: sid \t wid \t state \t since \t name \t cmd \t path \t glyph \t idleglyph \t session:index
row="$(printf '$0\t@1\tidle\t\tapi\tzsh\tapi\t💤\t💤\tmain:2\n')"
line="$(printf '%s' "$row" | awk -F'\t' -v now=100 '
  { st=$3; since=$4; el=(since==""?0:now-since); m=int(el/60);
    dot=($8!=""?$8:($9!=""?$9:"💤")); tgt=$10;
    printf "%s %-8s %3dm  %-14s %s  (%s/%s)\n", dot, st, m, tgt, $5, $6, $7 }')"
assert_contains "$line" "main:2" "switcher row shows the session:index target"
assert_contains "$line" "api" "switcher row still shows the window name"

# --- skill integrity: it must reference only real amux subcommands ---
# Check each `amux <cmd>` the skill names is a real subcommand, by word-matching
# it in bin/amux (matches its dispatch branch and/or the usage synopsis). This
# sidesteps dispatch-syntax quirks like `wait-done|wait)`.
SKILL="$HERE/skills/amux/SKILL.md"
[ -f "$SKILL" ] && assert_eq ok ok "skills/amux/SKILL.md exists" || assert_eq "" exists "skills/amux/SKILL.md exists"
for cmd in whoami spawn send wait-done read status; do
  if grep -q "amux $cmd" "$SKILL" 2>/dev/null && grep -qw "$cmd" "$HERE/bin/amux" 2>/dev/null; then
    assert_eq ok ok "skill uses a real subcommand: amux $cmd"
  else
    assert_eq "" real "skill uses a real subcommand: amux $cmd"
  fi
done
