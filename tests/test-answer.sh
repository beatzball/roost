#!/usr/bin/env bash
# tests/test-answer.sh — `roost answer` (#142), the verb, with no real harness.
#
# A "dialog" here is a pane running a small script written into this run's
# directory. It stamps 🛑 through roost's REAL scripts/roost-agent-state with a
# PermissionRequest payload, so @roost-dialog, @roost-blocked-on and
# @roost-transcript are the ones a real Claude leaves. It then draws the two
# marker lines of a Claude permission dialog and reads keys raw, one byte at a
# time, logging each byte as hex BEFORE it reacts. So a test can prove which
# key arrived, and -- for every refusal -- that none did.
#
# What it does with a key is the part a real Claude owns (the answer design,
# docs/airig/specs/2026-09-30-roost-answer-design.md, M1 and M6):
#
#   state    approve: the dialog goes, and the hook stamps working (M1, M5)
#   screen   approve: the dialog goes, the pane stays blocked (M6: a slow tool)
#   next     approve: a NEW dialog is stamped at once (M4)
#   decline  Escape: the dialog goes, and the three decline records are
#            written into the transcript, as Claude does (#38)
#   late     any key: the dialog goes AND the decline records appear -- a
#            person declined at the pane a moment before (§12.3)
#   none     nothing changes, ever: no proof can come
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
ROOST="$HERE/bin/roost"
HOOK="$HERE/scripts/roost-agent-state"

if ! command -v python3 >/dev/null 2>&1; then
  echo "  SKIP: python3 not available (this file builds its payloads with it)"
  exit 0
fi

work="$(mktemp -d /tmp/amx.XXXX)"
s="$work/roost"   # a PATH ending in /roost: the hook acts only on those
CANARY="$work/canary"
export HOME="$CANARY/home" XDG_CONFIG_HOME="$CANARY/xdg-config" \
       XDG_STATE_HOME="$CANARY/xdg-state" XDG_DATA_HOME="$CANARY/xdg-data" \
       CLAUDE_SETTINGS="$CANARY/claude/settings.json" CODEX_HOME="$CANARY/codex" \
       COPILOT_HOME="$CANARY/copilot" PI_CODING_AGENT_DIR="$CANARY/pi/agent"
export ROOST_RECORD_DIR="$work/rec"
export ROOST_EVENTS=""
trap 'tmux -S "$s" kill-server 2>/dev/null; rm -rf "$work"' EXIT
tmux -S "$s" -f /dev/null new-session -d -s main -n home -x 200 -y 50 'ENV= exec /bin/sh'
T() { tmux -S "$s" "$@"; }
T set -g @roost-notify-backend none
# One second is the bound for every case that is meant to run out, so the
# file stays fast; the default (3) is checked on its own below.
T set -g @roost-answer-timeout 1
spid="$(T display -p '#{pid}')"
export ROOST_SOCKET="$s"
unset TMUX TMUX_PANE

opt() { T show-options -pqv -t "$1" "$2"; }
fpof() { local d; d="$(opt "$1" @roost-dialog)"; printf '%s' "${d%% *}"; }
keys() { cat "$work/keys.$1" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }

# mkpayloads TAG -> $work/bash.TAG, write.TAG, fetch.TAG and ask.TAG: PermissionRequest
# payloads in the shape tests/test-answer-record.sh pins, each naming the
# transcript its dialog pane writes to.
mkpayloads() {
  python3 - "$work" "$1" <<'PY'
import json, sys
w, name = sys.argv[1], sys.argv[2]
def pr(tool, inp):
    return json.dumps({"session_id": "00000000-0000-4000-8000-000000001422",
         "transcript_path": w + "/tr." + name + ".jsonl",
         "cwd": "/tmp/roost-fixture/proj", "prompt_id": "00000000-0000-4000-8000-0000000014a2",
         "permission_mode": "default", "hook_event_name": "PermissionRequest",
         "tool_name": tool, "tool_input": inp, "permission_suggestions": []})
open(w + "/bash." + name, "w").write(pr("Bash", {"command": "mkdir build-" + name, "description": "x"}))
open(w + "/write." + name, "w").write(pr("Write", {"file_path": "/tmp/roost-fixture/" + name, "content": "x"}))
open(w + "/fetch." + name, "w").write(pr("WebFetch", {"url": "https://example.com/" + name, "prompt": "x"}))
opts = [{"label": l, "description": l} for l in ("Red", "Green", "Blue")]
open(w + "/ask." + name, "w").write(pr("AskUserQuestion", {"questions": [{
    "question": "Which color do you want?", "header": "Color", "options": opts, "multiSelect": False}]}))
PY
}

# The dialog stand-in. sh, not bash: CI's /bin/sh is dash.
cat > "$work/dialog" <<EOF
#!/bin/sh
# dialog MODE TAG PAYLOAD [question] — see the header of tests/test-answer.sh.
MODE="\$1"; TAG="\$2"; PAYLOAD="\$3"; DRAW="\${4:-permission}"
LOG="$work/keys.\$TAG"; TR="$work/tr.\$TAG.jsonl"
: > "\$LOG"; : > "\$TR"
draw() {
  printf '\033[2J\033[H'
  if [ "\$DRAW" = question ]; then
    # The shape of M2: the model's three options, then Claude's own two.
    printf ' [ ] Color\nWhich color do you want?\n> 1. Red\n  2. Green\n  3. Blue\n  4. Type something.\n  5. Chat about this\nEnter to select - up/down to navigate - Esc to cancel\n'
  else
    printf ' Bash command\n\n   mkdir build-%s\n\n Do you want to proceed?\n > 1. Yes\n   2. Yes, and always allow access\n   3. No\n\n Esc to cancel - Tab to amend\n' "\$TAG"
  fi
}
gone() { printf '\033[2J\033[H'; printf ' (the dialog has closed)\n'; }
decline() {
  python3 - "\$TR" <<'PY'
import json, sys, datetime
ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
recs = [
  {"type": "user", "toolDenialKind": "user-rejected", "timestamp": ts,
   "message": {"content": [{"type": "tool_result", "content": "The user doesn't want to proceed with this tool use. x"}]}},
  {"type": "user", "timestamp": ts, "message": {"content": [{"type": "text", "text": "[Request interrupted by user for tool use]"}]}},
  {"type": "system", "subtype": "turn_duration", "timestamp": ts},
]
open(sys.argv[1], "a").write("".join(json.dumps(r) + "\n" for r in recs))
PY
}
"$HOOK" working </dev/null
"$HOOK" blocked --permission-request-hook < "\$PAYLOAD"
draw
stty raw -echo 2>/dev/null
while :; do
  k="\$(dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  [ -n "\$k" ] || continue
  printf '%s\n' "\$k" >> "\$LOG"
  case "\$MODE" in
    state)   gone; "$HOOK" working </dev/null ;;
    screen)  gone ;;
    next)    "$HOOK" blocked --permission-request-hook < "$work/write.\$TAG" ;;
    decline) gone; decline ;;
    late)    decline; gone ;;
    none)    : ;;
  esac
done
EOF
chmod +x "$work/dialog"

# open MODE TAG [PAYLOAD-KIND [WINDOW]] -> prints the pane id, once the pane
# reads blocked and its dialog is on screen. A new window by default.
open_dialog() {
  local mode="$1" tag="$2" kind="${3:-bash}" p i=0 draw=permission
  mkpayloads "$tag"
  [ "$kind" = ask ] && draw=question
  if [ -n "${4:-}" ]; then
    p="$(T split-window -d -P -F '#{pane_id}' -t "$4" "$work/dialog $mode $tag $work/$kind.$tag $draw")"
  else
    p="$(T new-window -d -P -F '#{pane_id}' -t main -n "dlg-$tag" "$work/dialog $mode $tag $work/$kind.$tag $draw")"
  fi
  while [ "$i" -lt 100 ]; do
    if [ "$(opt "$p" @agent_state)" = blocked ] && [ -n "$(opt "$p" @roost-dialog)" ] \
       && T capture-pane -p -t "$p" | grep -q 'Esc to cancel'; then
      printf '%s' "$p"; return 0
    fi
    sleep 0.05; i=$((i + 1))
  done
  printf '%s' "$p"
}

# ans ARGS... -> runs `roost answer` from OUTSIDE any pane, stdin not a tty,
# and leaves $out, $err and $rc.
ans() {
  out="$(env -u TMUX -u TMUX_PANE "$ROOST" answer "$@" </dev/null 2>"$work/err")"; rc=$?
  err="$(cat "$work/err")"
}

# --- 1. usage, before anything is read ----------------------------------------
p="$(open_dialog none u)"; require_pane "$p" "the usage dialog"
fp="$(fpof "$p")"
ans; assert_eq "$rc" 1 "no arguments: exit 1"
assert_prefix "$err" "usage: roost answer" "...with the usage line"
ans "$p"; assert_eq "$rc" 1 "no action: exit 1"
ans --expect "$fp" "$p" --approve --deny; assert_eq "$rc" 1 "two actions: exit 1"
ans --expect "$fp" "$p" --option; assert_eq "$rc" 1 "--option with no number: exit 1"
ans --expect "$fp" "$p" --option two; assert_eq "$rc" 1 "--option with a word: exit 1"
ans "$p" --approve; assert_eq "$rc" 1 "--approve with no --expect: exit 1"
assert_contains "$err" "--approve and --option need --expect FINGERPRINT. Read it from roost status --json" \
  "...saying where the fingerprint comes from"
ans "$p" --option 1; assert_eq "$rc" 1 "--option with no --expect: exit 1"
ans --expect XYZ "$p" --approve; assert_eq "$rc" 1 "--expect that is not a fingerprint: exit 1"
ans --expect "$fp" "$p" --text hello; assert_eq "$rc" 8 "--text: exit 8"
assert_contains "$err" "--text is not supported yet. Answer at the pane" "...and says so"
ans --expect "$fp" --expect "$fp" "$p" --approve; assert_eq "$rc" 1 "a repeated flag is not consumed: exit 1"
ans --expect "$fp" "$p" --approve; assert_eq "$rc,$out" "10," "(control) the same call, well-formed, does send (to a pane that never confirms)"
assert_eq "$(keys u)" "31" "...exactly one key, the digit 1"
T kill-pane -t "$p"

# --- 2. the target ------------------------------------------------------------
ans --expect 000000000000 %999 --approve; assert_eq "$rc" 2 "no such pane: exit 2"
assert_eq "$err" "roost answer: no such target '%999'" "...named"
ans --expect 000000000000 nosuchwindow --approve; assert_eq "$rc" 2 "no such window: exit 2"
T set -g remain-on-exit on
dp="$(T new-window -d -P -F '#{pane_id}' -t main -n dead 'exit 0')"
sleep 0.3
ans "$dp" --deny; assert_eq "$rc" 2 "a dead pane: exit 2"
assert_contains "$err" "is a dead pane" "...named as dead"
T set -g remain-on-exit off
T kill-window -t "$dp"
# A window target: the one blocked pane in it.
w1="$(open_dialog state w1)"; T split-window -d -t "$w1" 'exec sleep 600'
fp="$(fpof "$w1")"
ans --expect "$fp" main:dlg-w1 --approve
assert_eq "$rc,$out" "0,$w1 approve $fp" "a window target answers the one blocked pane in it"
assert_eq "$(keys w1)" "31" "...with one key"
# Two blocked panes in one window: refused, naming both.
w2="$(open_dialog none w2)"
w3="$(open_dialog none w3 bash "$w2")"
ans main:dlg-w2 --deny; assert_eq "$rc" 2 "a window with two blocked panes: exit 2"
assert_contains "$err" "has more than one blocked pane ($w2 $w3)" "...naming both"
assert_eq "$(keys w2)|$(keys w3)" "|" "...and neither got a key"
T kill-window -t "$w2"

# --- 3. who is calling (§7) ----------------------------------------------------
# A pane an agent has reported from: badged. The caller's own $TMUX names this
# server by pid, as tmux gives it to every pane.
c="$(open_dialog none c)"; fp="$(fpof "$c")"
agent="$(T new-window -d -P -F '#{pane_id}' -t main -n agent 'exec sleep 600')"
T set -p -t "$agent" @agent_state working
from_pane() { # PANE ARGS...
  local fromp="$1"; shift
  out="$(env TMUX="$s,$spid,0" TMUX_PANE="$fromp" "$ROOST" answer "$@" </dev/null 2>"$work/err")"; rc=$?
  err="$(cat "$work/err")"
}
from_pane "$agent" --expect "$fp" "$c" --approve
assert_eq "$rc" 9 "a caller in an agent's pane: exit 9"
assert_eq "$err" "roost answer: this is a person's command, and it was called from an agent's pane ($agent)
roost answer: pass --force only if a person told you to answer this dialog" "...with the two lines of §9"
assert_eq "$(keys c)" "" "...and no key"
# Refused before the pane is read: a wrong fingerprint is still exit 9, so an
# agent learns nothing about the dialog from the refusal.
from_pane "$agent" --expect 000000000000 "$c" --approve
assert_eq "$rc" 9 "the caller check runs before the dialog is read"
# A pane with an identity and no badge is an agent's pane too (#141 record).
T set -pu -t "$agent" @agent_state; T set -p -t "$agent" @roost-session sess-1
from_pane "$agent" --expect "$fp" "$c" --approve
assert_eq "$rc" 9 "a pane with only an identity record counts as an agent's pane"
# A pane id that is not on THIS server is not this server's pane.
out="$(env TMUX="/tmp/other-server,1,0" TMUX_PANE="$agent" "$ROOST" answer --expect "$fp" "$c" --deny </dev/null 2>"$work/err")"; rc=$?
assert_eq "$rc" 10 "\$TMUX naming another server: not an agent's pane here, so it goes on (and this pane never confirms)"
assert_eq "$(keys c)" "1b" "...one Escape"
T kill-window -t "$c"
c="$(open_dialog state c2)"; fp="$(fpof "$c")"
from_pane "$agent" --force --expect "$fp" "$c" --approve
assert_eq "$rc,$out" "0,$c approve $fp" "--force from an agent's pane answers"
assert_eq "$(opt "$c" @roost-answered)" "" "(the record went with the dialog when the pane left blocked)"
# A person's shell pane inside roost: no badge, no identity, no flag needed.
c="$(open_dialog state c3)"; fp="$(fpof "$c")"
shellp="$(T new-window -d -P -F '#{pane_id}' -t main -n shell 'exec sleep 600')"
from_pane "$shellp" --expect "$fp" "$c" --approve
assert_eq "$rc,$out" "0,$c approve $fp" "a person's shell pane inside roost passes with no flag (Q1)"

# --- 4. the guards, each with an empty key log --------------------------------
g="$(open_dialog none g)"; fp="$(fpof "$g")"
ans --expect 0123456789ab "$g" --approve; assert_eq "$rc" 7 "--expect that does not match: exit 7"
assert_eq "$err" "roost answer: '$g' is now blocked on a different dialog (expected 0123456789ab, found $fp). Nothing was sent" \
  "...naming both fingerprints"
ans --expect "$fp" %0 --deny; assert_eq "$rc" 6 "a pane that is not blocked: exit 6"
assert_contains "$err" "is not blocked (it reads no badge). There is nothing to answer" "...saying what it reads"
T copy-mode -t "$g"
ans --expect "$fp" "$g" --approve; assert_eq "$rc" 6 "a pane in copy mode: exit 6"
assert_contains "$err" "is in copy mode, so keys would not reach the agent" "...saying why"
T send-keys -t "$g" -X cancel
assert_eq "$(keys g)" "" "no key reached the dialog in any refusal so far"
# The marker is not on screen: blocked, but nothing to answer (M6). The same
# pane, its dialog replaced by a screen with no dialog on it, and the badge
# and record put back as they were.
T respawn-pane -k -t "$g" "sh -c 'printf \"a pane that reads blocked with no dialog drawn\\n\"; exec sleep 600'"
sleep 0.2
T set -p -t "$g" @agent_state blocked
T set -p -t "$g" @roost-dialog "$fp claude permission 0 00000000"
ans --expect "$fp" "$g" --approve; assert_eq "$rc" 6 "blocked with no dialog on screen: exit 6"
assert_eq "$err" "roost answer: '$g' reads blocked, but no dialog is on its screen. Nothing was sent" "...saying so"
# No dialog record: 7 with --expect, 8 without.
T set -pu -t "$g" @roost-dialog
ans --expect "$fp" "$g" --approve; assert_eq "$rc" 7 "no dialog record, with --expect: exit 7"
assert_contains "$err" "has no dialog record, so roost cannot tell which dialog this is" "...saying why"
ans "$g" --deny; assert_eq "$rc" 8 "no dialog record, a deny without --expect: exit 8"
T kill-window -t "$g"
# Kind other: no measured keys.
o="$(open_dialog none o fetch)"; fp="$(fpof "$o")"
assert_contains "$(opt "$o" @roost-dialog)" " claude other 0 " "(a WebFetch dialog, not measured, is kind other)"
ans --expect "$fp" "$o" --approve; assert_eq "$rc" 8 "a dialog of kind other: exit 8"
assert_eq "$err" "roost answer: no measured keys for this claude dialog. Answer at the pane" "...in the words of §9"
ans --expect "$fp" "$o" --option 1; assert_eq "$rc" 8 "--option on a dialog of kind other: exit 8"
ans --expect "$fp" "$o" --deny; assert_eq "$rc" 8 "...and a deny too: nothing is measured for it"
assert_eq "$(keys o)" "" "no key reached a dialog of kind other"
# --option on a permission prompt.
T set -p -t "$o" @roost-dialog "$fp claude permission 0 00000000"
ans --expect "$fp" "$o" --option 1; assert_eq "$rc" 8 "--option on a permission prompt: exit 8"
assert_eq "$err" "roost answer: this is a permission prompt. Use --approve or --deny" "...saying what to use"
# A codex dialog: measured, but held back until #145.
T set -p -t "$o" @roost-dialog "$fp codex permission 0 00000000"
ans --expect "$fp" "$o" --approve; assert_eq "$rc" 8 "a codex dialog: exit 8 in this cut (#145)"
assert_eq "$err" "roost answer: no measured keys for this codex dialog. Answer at the pane" "...in the words of §9"
assert_eq "$(keys o)" "" "no key reached the pane in any refusal"
T kill-window -t "$o"

# --- 5. answered already -----------------------------------------------------
a="$(open_dialog screen a)"; fp="$(fpof "$a")"
ans --expect "$fp" "$a" --approve
assert_eq "$rc,$out" "0,$a approve $fp" "approve on a slow tool: confirmed by the screen (M6)"
assert_prefix "$(opt "$a" @roost-answered)" "$fp " "@roost-answered names this dialog"
assert_contains "$(opt "$a" @roost-answered)" " approve program" "...with the action and where the call ran"
assert_eq "$(opt "$a" @agent_state)" "blocked" "(the pane still reads blocked, as a real one does)"
ans --expect "$fp" "$a" --approve; assert_eq "$rc" 6 "a second answer to the same dialog: exit 6"
assert_prefix "$err" "roost answer: this dialog was already answered (approve, " "...saying what and when"
ans "$a" --deny; assert_eq "$rc" 6 "...and a deny of it too"
assert_eq "$(keys a)" "31" "exactly one key in all"
jdialog="$("$ROOST" status --json | python3 -c 'import json,sys
d = json.load(sys.stdin)
p = [x for x in d["panes"] if x["id"] == sys.argv[1]][0]
print(p["dialog"]["answered"]["action"], p["dialog"]["answered"]["by"])' "$a")"
assert_eq "$jdialog" "approve program" "status --json says the dialog was answered, so a board can stop saying it needs you"
T kill-window -t "$a"

# --- 6. confirmation: each proof, and what is not a proof ---------------------
b="$(open_dialog state b)"; fp="$(fpof "$b")"
ans --expect "$fp" "$b" --approve
assert_eq "$rc,$out" "0,$b approve $fp" "approve: confirmed"
assert_eq "$(keys b)" "31" "...by one key, the digit 1"
assert_eq "$(opt "$b" @agent_state)" "working" "...and the pane moved on"
n="$(open_dialog next n)"; fp="$(fpof "$n")"
ans --expect "$fp" "$n" --approve
assert_eq "$rc,$out" "0,$n approve $fp" "approve that opens the next dialog at once: confirmed"
[ "$(fpof "$n")" != "$fp" ]; assert_true $? "...and the pane carries a new fingerprint"
ans --expect "$fp" "$n" --approve; assert_eq "$rc" 7 "the OLD fingerprint on the next dialog: exit 7"
assert_eq "$(keys n)" "31" "...and no second key"
dn="$(open_dialog decline dn)"; fp="$(fpof "$dn")"
ans "$dn" --deny
assert_eq "$rc,$out" "0,$dn deny $fp" "deny with no --expect: confirmed from the transcript"
assert_eq "$err" "roost answer: denying '$dn': Bash: mkdir build-dn" "...after saying, on stderr, what it denied"
assert_eq "$(keys dn)" "1b" "...by one Escape, never a digit"
assert_eq "$(opt "$dn" @agent_state)|$(opt "$dn" @roost-dialog)" "|" "...and the badge and record were cleared, as send would"
late="$(open_dialog late late)"; fp="$(fpof "$late")"
ans --expect "$fp" "$late" --approve
assert_eq "$rc,$out" "10," "approve, but the transcript shows a decline: exit 10, nothing on stdout"
assert_contains "$err" "its transcript shows the dialog was declined, not by this call" "...saying what the pane shows"
assert_contains "$err" "do NOT answer again. Look: roost screen $late" "...and not to answer again"
none="$(open_dialog none none)"; fp="$(fpof "$none")"
t0="$(date +%s)"
ans --expect "$fp" "$none" --approve
t1="$(date +%s)"
assert_eq "$rc,$out" "10," "a key that nothing confirms: exit 10"
assert_eq "$err" "roost answer: the key was sent to '$none', and nothing confirmed it inside 1 s
roost answer: do NOT answer again. Look: roost screen $none" "...in the words of §6"
assert_eq "$(keys none)" "31" "...and exactly one key went in: there is no retry"
[ $((t1 - t0)) -le 3 ]; assert_true $? "...inside the bound (took $((t1 - t0)) s with a 1 s bound)"
ans --expect "$fp" "$none" --approve; assert_eq "$rc" 6 "and a second try is refused as already answered"
assert_eq "$(keys none)" "31" "...so a second key cannot go in"

# --- 6b. a question (--option N, step 3) --------------------------------------
q="$(open_dialog state q ask)"; fp="$(fpof "$q")"
assert_contains "$(opt "$q" @roost-dialog)" " claude question 3 " "(a three-option question is kind question, 3)"
ans --expect "$fp" "$q" --approve; assert_eq "$rc" 8 "--approve on a question: exit 8"
assert_eq "$err" "roost answer: this is a question with 3 options. Use --option N, or --deny" "...saying what to use"
ans --expect "$fp" "$q" --option 4; assert_eq "$rc" 8 "--option 4 on three options: exit 8 (Claude's own 'Type something.')"
assert_eq "$err" "roost answer: option 4 is not one of the 3 options the agent gave" "...in the words of §9"
ans --expect "$fp" "$q" --option 0; assert_eq "$rc" 8 "--option 0: exit 8"
assert_eq "$(keys q)" "" "no key reached the question in any refusal"
ans --expect "$fp" "$q" --option 02
assert_eq "$rc,$out" "0,$q option 2 $fp" "--option 2 (written 02): confirmed, and printed as 'option 2'"
assert_eq "$(keys q)" "32" "...by one key, the digit 2"
qd="$(open_dialog decline qd ask)"; fp="$(fpof "$qd")"
ans "$qd" --deny
assert_eq "$rc,$out" "0,$qd deny $fp" "deny on a question: confirmed from the transcript"
assert_eq "$(keys qd)" "1b" "...by one Escape"
qs="$(open_dialog none qs ask)"; fp="$(fpof "$qs")"
T set -p -t "$qs" @roost-dialog "$fp claude permission 0 00000000"
ans --expect "$fp" "$qs" --approve; assert_eq "$rc" 6 "a permission record over a question's screen: the marker refuses it (exit 6)"
assert_eq "$(keys qs)" "" "...and nothing was sent"
T kill-window -t "$qs"
rec="$(find "$ROOST_RECORD_DIR" -name answers -path "*/${q#%}/answers" 2>/dev/null | head -1)"
assert_contains "$(cat "$rec" 2>/dev/null)" " claude question option2 program forced=0 confirmed=" "an option answer is recorded as optionN"
assert_contains "$(cat "$rec" 2>/dev/null)" "AskUserQuestion: Which color do you want?" "...with the question as its description"

# --- 7. the one-command send refuses a dialog that moved (§3.1 step 9) --------
# The window is too small to hit through the verb on demand, so the PROPERTY
# is asserted on the function that closes it: the test and the send are one
# tmux command, and a stale fingerprint sends nothing.
. "$HERE/scripts/lib/roost-answer.sh"
t() { tmux -S "$s" "$@"; }
r="$(open_dialog none r)"; fp="$(fpof "$r")"
roost_answer_send "$r" 0123456789ab 1 "0123456789ab 1790000000 approve program" "1.1"; src=$?
assert_eq "$src|$(keys r)|$(opt "$r" @roost-answered)" "1||" "a stale fingerprint at the send: refused, no key, no record"
T set -p -t "$r" @roost-answered "$fp 1790000000 approve terminal"
roost_answer_send "$r" "$fp" 1 "$fp 1790000001 approve program" "1.2"; src=$?
assert_eq "$src|$(keys r)" "1|" "an answer that landed after the read: refused at the send"
T set -pu -t "$r" @roost-answered
T copy-mode -t "$r"
roost_answer_send "$r" "$fp" 1 "$fp 1790000002 approve program" "1.3"; src=$?
assert_eq "$src|$(keys r)" "1|" "copy mode entered after the read: refused at the send"
T send-keys -t "$r" -X cancel
T set -p -t "$r" @agent_state working
roost_answer_send "$r" "$fp" 1 "$fp 1790000003 approve program" "1.4"; src=$?
assert_eq "$src|$(keys r)" "1|" "a pane that left blocked after the read: refused at the send"
T set -p -t "$r" @agent_state blocked
roost_answer_send "$r" "$fp" 1 "$fp 1790000004 approve program" "1.5"; src=$?
assert_eq "$src|$(keys r)|$(opt "$r" @roost-answered)" "0|31|$fp 1790000004 approve program" "(control) all four hold: one key, and the record"
roost_answer_send "$r" "$fp" 1 "$fp 1790000004 approve program" "1.6"; src=$?
assert_eq "$src|$(keys r)" "1|31" "the same value again from a second caller: its own nonce tells it nothing was sent"

# --- 8. the record ------------------------------------------------------------
rec="$(find "$ROOST_RECORD_DIR" -name answers -path "*/${b#%}/answers" 2>/dev/null | head -1)"
[ -n "$rec" ]; assert_true $? "an answer is recorded in the pane's record directory"
line="$(cat "$rec" 2>/dev/null)"
case "$line" in
  [0-9]*" $(printf '%s' "$line" | cut -d' ' -f2) claude permission approve program forced=0 confirmed=state Bash: mkdir build-b") ok=0 ;;
  *) ok=1 ;;
esac
assert_true "$ok" "...as one line: epoch, fingerprint, harness, kind, action, by, forced, confirmed, description (got: $line)"
rec="$(find "$ROOST_RECORD_DIR" -name answers -path "*/${none#%}/answers" 2>/dev/null | head -1)"
assert_contains "$(cat "$rec" 2>/dev/null)" " confirmed=none " "an unconfirmed answer is recorded too, as confirmed=none"
rec="$(find "$ROOST_RECORD_DIR" -name answers -path "*/${c#%}/answers" 2>/dev/null | head -1)"
assert_contains "$(cat "$rec" 2>/dev/null)" " approve pane:$shellp forced=0 " "a call from a pane is recorded as pane:%N"
perm="$(ls -l "$rec" | cut -c1-10)"
assert_eq "$perm" "-rw-------" "the answers file is private, like the replies beside it"
ROOST_RECORD_DIR="" ans --expect "$(fpof "$r")" "$r" --approve >/dev/null
assert_eq "$(find "$ROOST_RECORD_DIR" -name answers -path "*/${r#%}/answers" | wc -l | tr -d ' ')" 0 \
  "with ROOST_RECORD_DIR=\"\" nothing is recorded"

# --- 9. the bound -------------------------------------------------------------
T set -gu @roost-answer-timeout
d3="$(open_dialog none d3)"; fp="$(fpof "$d3")"
t0="$(date +%s)"; ans --expect "$fp" "$d3" --approve; t1="$(date +%s)"
assert_eq "$rc" 10 "the default bound runs out on a pane that never confirms"
assert_contains "$err" "inside 3 s" "...and the default is 3 s"
[ $((t1 - t0)) -ge 2 ] && [ $((t1 - t0)) -le 6 ]; assert_true $? "...which it waited (took $((t1 - t0)) s)"
T set -g @roost-answer-timeout 099
d4="$(open_dialog none d4)"; fp="$(fpof "$d4")"
T set -g @roost-answer-timeout 0
t0="$(date +%s)"; ans --expect "$fp" "$d4" --approve; t1="$(date +%s)"
assert_contains "$err" "inside 1 s" "a bound of 0 is clamped up to 1"
T set -g @roost-answer-timeout 1

# --- 10. nothing but `roost answer` sends a key into a dialog (§7.4) ----------
# A hook, an adapter or another roost command that called `answer` would be
# roost answering on its own. Comment lines are skipped (the help text and
# this design's prose are comments), as are the verb's own messages.
calls() { # FILE... -> every non-comment line that runs `roost answer`
  grep -nE '(roost|ROOST|bin/roost)["}'"'"']*[[:space:]]+answer[[:space:]]+(-|%|\$|"|[A-Za-z])' "$@" 2>/dev/null \
    | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' \
    | grep -vE 'usage: roost answer|"roost answer: |roost answer: '
}
printf '#!/bin/sh\n"$ROOST" answer --force --expect abc %%3 --approve\n' > "$work/planted"
assert_contains "$(calls "$work/planted")" 'answer --force' "(control) the check finds a planted call"
found="$(cd "$HERE" && calls bin/roost scripts/* scripts/lib/* adapters/*/* adapters/opencode/v2/* 2>/dev/null)"
assert_eq "$found" "" "no hook, adapter or other roost command calls roost answer"

leaks="$(find "$CANARY" -mindepth 1 2>/dev/null | sort)"
assert_eq "$leaks" "" "nothing was written under the canary homes"

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
