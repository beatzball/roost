# roost-unblock.sh — clear a Claude Code `blocked` badge that a declined or
# dismissed permission dialog left behind (#38), and only clear it; and, since
# #95, clear a `working` badge that an Esc mid-stream or mid-tool left behind,
# recording the turn as `interrupted` (the second half of this file).
#
# Sourced by bin/roost. Defines functions and one constant and runs nothing at
# source time. It needs bin/roost's `t` (tmux on the right server).
#
# --- why this exists ---------------------------------------------------------
#
# Measured on Claude Code 2.1.270 with a logger on all 32 hook events: answering
# `No` at a permission dialog, or pressing Esc, fires NO hook. Not PostToolUse,
# not PostToolUseFailure, not PermissionDenied, not Stop. The 🛑 the
# Notification hook stamped is therefore never unstamped by an event, and
# `roost send` refused the pane with exit 3 forever, `wait-done` burned its
# whole timeout, and `read` called a current reply stale.
#
# codex has an event for this (Interrupt) and its adapter uses it. Claude does
# not. What Claude DOES do is write the decline into its own transcript — the
# JSONL file every hook payload names in `transcript_path` — as three records,
# the same for No and for Esc:
#
#   user    message.content = [tool_result "The user doesn't want to proceed
#           with this tool use. …"], toolDenialKind "user-rejected"
#   user    message.content = [text "[Request interrupted by user for tool use]"]
#   system  subtype "turn_duration"
#
# followed only by records that carry no conversation (see SKIP below).
#
# --- the rules, and each is fail-closed --------------------------------------
#
# A pane is cleared only when ALL of these hold. Anything else leaves 🛑 exactly
# where it is, because a false clear lets one agent paste into another's open
# dialog — the hazard `send`'s exit 3 exists to prevent.
#
#   1. It reads `blocked` at PANE scope.
#   2. Its @roost-transcript was written by the Notification hook for THIS
#      stamp: the record is "<@agent_since> <absolute path>", and its first
#      word must equal the pane's @agent_since. A record left by an earlier
#      stamp, or none at all (a hook wired before #38, or any other harness),
#      clears nothing.
#   3. The transcript is a readable regular file, and a JSON reader exists.
#   4. Walking the transcript BACKWARDS from its last line, skipping only the
#      record types named in SKIP, the first three records are exactly the
#      three above, in that order, and each has a timestamp no older than
#      @agent_since. An unknown record type, a line that is not a JSON object,
#      a missing timestamp or any other record first: cannot tell, stay
#      blocked.
#   5. The clear itself is a compare-and-clear: tmux re-checks the state and
#      the stamp in the same command that unsets them, so a hook that stamps
#      the pane in between wins.
#
# Rule 4 is what the first attempt at #38 lacked. It read the SCREEN, and a
# screen keeps history: an old "declined" line under a new, approved, still-
# running tool cleared a live badge. A transcript is ordered, so a newer user
# prompt or tool call after the decline means the decline is not the last
# thing that happened, and nothing is cleared.
#
# --- what it writes ----------------------------------------------------------
#
# Only unsets, plus two records of its own. It UNSETS @agent_state (never writes
# a value: setting state is the job of a harness event), @roost-reply (a
# declined turn fired no Stop, so what is stored is the previous turn's answer),
# @roost-transcript, @roost-blocked-on (the description of the dialog that has
# just been declined, #91), @roost-stop-swallowed (that dialog's one-Stop
# allowance, spent or not), @roost-dialog, @roost-answered and
# @roost-answer-nonce (that dialog's record for `roost answer`, #142), and
# writes @roost-unblocked "<now> since=<stamp> by=<token>" so a false clear can
# be found later, and -- since #95 --
# @roost-ended "<stamp> interrupted", because a declined dialog ended the turn
# and the human ended it: `wait-done` reads that record to exit 5 instead of
# 0 (the M7 measurement, "interrupted looks like success"), and an empty turn
# file with an `outcome` sidecar keeps the turn's number. It never writes
# anything under ~/.claude: the transcript is only ever opened for reading.
#
# --- what can break it -------------------------------------------------------
#
# The transcript format is Claude's, not a published contract. If an upgrade
# changes the three records, rule 4 stops matching and recovery silently stops
# — fail closed, the pre-#38 behaviour. tests/live/claude-decline-smoke.sh
# drives a real Claude and fails loudly when that happens; run it after every
# Claude Code upgrade.

# How much of a transcript is read, from its end. Transcripts grow for the
# whole session and can reach many megabytes; the records that matter are the
# last few. 4 MiB is far more than one turn's tail and still bounded.
ROOST_UNBLOCK_TAIL_BYTES=4194304

# roost_claude_declined FILE SINCE -> 0 iff FILE's tail is a decline no older
# than SINCE (epoch seconds). python3 first, then jq, as everywhere else in
# roost; with neither, nothing can be known and the answer is no.
roost_claude_declined() {
  [ -f "$1" ] && [ -r "$1" ] || return 1
  case "$2" in ''|*[!0-9]*) return 1 ;; esac
  if command -v python3 >/dev/null 2>&1; then
    roost_claude_declined_py "$1" "$2"
  elif command -v jq >/dev/null 2>&1; then
    roost_claude_declined_jq "$1" "$2"
  else
    return 1
  fi
}

# The two engines are separate functions so the suite can run BOTH against the
# same real captures and hold them to the same answers.
roost_claude_declined_py() {
  [ -f "$1" ] && [ -r "$1" ] || return 1
  python3 - "$1" "$2" "$ROOST_UNBLOCK_TAIL_BYTES" <<'PY' 2>/dev/null
import json
import sys
from datetime import datetime, timezone

# Records that carry no conversation. Each was observed in a real transcript
# AFTER a decline or between its records (Claude Code 2.1.270). Anything not
# named here is not skipped: an unknown type means "cannot tell".
SKIP = {
    "last-prompt", "ai-title", "mode", "permission-mode", "atis-latch",
    "bridge-session", "attachment", "file-history-snapshot",
}
INTERRUPT = "[Request interrupted by user for tool use]"
REJECT = "The user doesn't want to proceed with this tool use."


def stamp(rec):
    t = rec.get("timestamp")
    if not isinstance(t, str):
        return None
    try:
        return datetime.strptime(t, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return None


def content(rec):
    msg = rec.get("message")
    return msg.get("content") if isinstance(msg, dict) else None


def is_turn_end(rec):
    return rec.get("type") == "system" and rec.get("subtype") == "turn_duration"


def is_interrupt(rec):
    return rec.get("type") == "user" and content(rec) == [{"type": "text", "text": INTERRUPT}]


def is_rejection(rec):
    c = content(rec)
    return (rec.get("type") == "user"
            and rec.get("toolDenialKind") == "user-rejected"
            and isinstance(c, list) and len(c) > 0
            and all(isinstance(b, dict) and b.get("type") == "tool_result"
                    and isinstance(b.get("content"), str) and b["content"].startswith(REJECT)
                    for b in c))


def main():
    path, since, limit = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    with open(path, "rb") as fh:
        fh.seek(0, 2)
        size = fh.tell()
        start = max(0, size - limit)
        fh.seek(start)
        lines = fh.read().split(b"\n")
    if start > 0:
        lines = lines[1:]      # a seek lands mid-line; that line is not a record
    want = [is_turn_end, is_interrupt, is_rejection]
    for raw in reversed(lines):
        if not raw.strip():
            continue
        rec = json.loads(raw)  # not JSON: raises, and the answer is no
        if not isinstance(rec, dict):
            return 1
        if rec.get("type") in SKIP:
            continue
        t = stamp(rec)
        if not want[0](rec) or t is None or t < since:
            return 1
        want.pop(0)
        if not want:
            return 0
    return 1


try:
    sys.exit(main())
except Exception:
    sys.exit(1)
PY
}

roost_claude_declined_jq() {
  [ -f "$1" ] && [ -r "$1" ] || return 1
  local size cut
  size="$(wc -c < "$1" 2>/dev/null | tr -d ' ')"
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  cut=0; [ "$size" -gt "$ROOST_UNBLOCK_TAIL_BYTES" ] && cut=1
  # The same walk as the python engine, written as a filter: split into lines,
  # drop the partial first line of a cut read, parse each line (a failure
  # becomes a non-object, which no check accepts), newest first, drop the SKIP
  # types, and look at the first three that are left.
  tail -c "$ROOST_UNBLOCK_TAIL_BYTES" "$1" 2>/dev/null | jq -R -s -e \
    --argjson since "$2" --argjson cut "$cut" '
    def skip: ["last-prompt","ai-title","mode","permission-mode","atis-latch",
               "bridge-session","attachment","file-history-snapshot"];
    def stamp: try (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null;
    def recent: type == "object" and (stamp | type) == "number" and stamp >= $since;
    [ split("\n") | (if $cut == 1 then .[1:] else . end)[]
      | select(test("^\\s*$") | not)
      | (try fromjson catch "not json") ]
    | reverse
    | map(select((type == "object" and ((.type | tostring) as $t | skip | index($t))) | not))
    | .[0:3] as $r
    | ($r | length) == 3
      and ($r | all(.[]; recent))
      and ($r[0].type == "system" and $r[0].subtype == "turn_duration")
      and ($r[1].type == "user"
           and $r[1].message.content == [{"type": "text", "text": "[Request interrupted by user for tool use]"}])
      and ($r[2].type == "user" and $r[2].toolDenialKind == "user-rejected"
           and ($r[2].message.content | type) == "array"
           and ($r[2].message.content | length) > 0
           and ($r[2].message.content | all(.[];
                 type == "object" and .type == "tool_result"
                 and (.content | type) == "string"
                 and (.content | startswith("The user doesn'"'"'t want to proceed with this tool use.")))))
    ' >/dev/null 2>&1
}

# roost_unblock_token -> ROOST_UNBLOCK_TOKEN, a word unique to this caller:
# its pid and two $RANDOMs, digits and dots only, so it sits in a tmux format
# and a command string unquoted by anything but '…'.
#
# WHY IT EXISTS (flock round 1 on #95, reproduced 20 of 20 runs). The clear
# below is a compare-and-clear, so only one of several callers recovering one
# pane at once -- a wait-done poll, a read, a send -- actually clears it. But
# the check AFTER it read @roost-unblocked back as "<now> since=<stamp>", and
# every caller that ran in the same second computed the same value: each
# believed it had won, and each appended an empty interrupted turn, so one
# prompt took three turn numbers. With the token in the value, the read-back
# names exactly one caller, and only that caller records the turn.
roost_unblock_token() {
  ROOST_UNBLOCK_TOKEN="$$.$RANDOM$RANDOM"
}

# roost_unblock_record_turn PANE [OUTCOME [OURS]] -- after a recovery cleared PANE:
# append the ended turn (the held main reply as its text, when there was one)
# to the pane's record, with OUTCOME in its sidecar -- `interrupted` when none
# is given, `died_in_shell` from the dead-agent clear below -- only for a
# record this roost can write (state 0) or that has none yet (1). Fails soft: the badge is already cleared and `wait-done`
# reads @roost-ended, so a record that could not be written costs the turn
# number, never the outcome.
#
# When NO durable copy was saved -- recording off (ROOST_RECORD_DIR=""), a
# record roost cannot write, a full disk -- and the turn had a held main
# reply, that reply is put back on the pane, which the clear unset: the
# pane was its only copy, and losing it there lost the agent's answer for
# good (flock round 2, reproduced on both recovery paths). The badge and the
# hold record stay cleared. A reader between the clear and this write sees
# no reply for that moment; the clear has to come first, because only the
# caller whose clear landed may write.
#
# OURS is 0 from the dead-agent clear when a newer turn has stamped the pane
# since its clear landed (roost_died_pane, THE NUMBER): the turn is still
# filed, but the held reply is never put back, because the pane's reply
# belongs to the newer turn now. Any other value, or none, is today's.
roost_unblock_record_turn() {
  local saved=0
  if record_for "$1" "$1" && [ "$RF_LIVE" = 1 ]; then
    case "$RF_STATE" in
      0|1) roost_record_append_outcome "$RF_DIR" "$(t display-message -p '#{socket_path}' 2>/dev/null || true)" "${2:-interrupted}" "$ROOST_UNBLOCK_HELD" && saved=1 ;;
    esac
  fi
  if [ "$saved" = 0 ] && [ -n "${ROOST_UNBLOCK_HELD:-}" ] && [ "${3:-1}" != 0 ]; then
    . "${BASH_SOURCE[0]%/*}/roost-reply.sh" 2>/dev/null || return 0
    t set-option -p -t "$1" @roost-reply "$(roost_reply_escape "$ROOST_UNBLOCK_HELD")" 2>/dev/null || true
  fi
  return 0
}

# roost_unblock_held_reply PANE SINCE -> ROOST_UNBLOCK_HELD, the main reply of
# a turn held by its own background work (#97), or "" when the pane is not
# held for this stamp. A recovery that ends such a turn records THIS as the
# turn's text instead of an empty file: the hold put the main reply on the
# pane and nothing on disk, so clearing @roost-reply without it threw the
# agent's answer away (flock round 1 on #95, reproduced). Read before the
# clear, which unsets the reply; the hold record must agree with SINCE, the
# @roost-transcript rule.
roost_unblock_held_reply() {
  local bg
  ROOST_UNBLOCK_HELD=""
  bg="$(t show-options -pqv -t "$1" @roost-background 2>/dev/null || true)"
  case "$bg" in "$2 "?*) ;; *) return 0 ;; esac
  ROOST_UNBLOCK_HELD="$(t show-options -pqv -t "$1" @roost-reply 2>/dev/null || true)"
}

# roost_unblock_pane TARGET -> 0 iff TARGET's pane read `blocked` and was
# cleared here. Any other answer is 1, and a 1 changes nothing.
roost_unblock_pane() {
  local info pane since state rec rsince rpath now
  info="$(t display-message -p -t "$1" '#{pane_id} #{@agent_since}' 2>/dev/null || true)"
  pane="${info%% *}"
  since="${info#* }"
  case "$pane" in %[0-9]*) : ;; *) return 1 ;; esac
  # Pane scope only: a window- or global-scope value is not this pane's stamp.
  state="$(t show-options -pqv -t "$pane" @agent_state 2>/dev/null || true)"
  [ "$state" = "blocked" ] || return 1
  case "$since" in ''|*[!0-9]*) return 1 ;; esac
  rec="$(t show-options -pqv -t "$pane" @roost-transcript 2>/dev/null || true)"
  rsince="${rec%% *}"
  rpath="${rec#* }"
  # A string comparison, never arithmetic: a zero-padded stamp must not be read
  # as octal, and nothing here needs the number.
  [ -n "$rec" ] && [ "$rsince" = "$since" ] || return 1
  case "$rpath" in /*) : ;; *) return 1 ;; esac
  roost_claude_declined "$rpath" "$since" || return 1
  now="$(date +%s)"
  roost_unblock_token
  roost_unblock_held_reply "$pane" "$since"
  # One tmux command: the condition is evaluated and the unsets run with no
  # other client able to act in between. $since is digits only (checked
  # above) and $pane is %N, so neither can break out of the format or the
  # command string.
  #
  # @roost-dialog, @roost-answered and @roost-answer-nonce (#142) describe the
  # dialog that was just declined, as @roost-blocked-on does, and go with it.
  # So do the hold record, its types and its owner (@roost-background-session,
  # #188): a turn the human ended holds nothing for SessionEnd to release.
  t if-shell -F -t "$pane" \
    "#{&&:#{==:#{@agent_state},blocked},#{==:#{@agent_since},$since}}" \
    "set-option -pu -t $pane @agent_state ; set-option -pu -t $pane @roost-reply ; set-option -pu -t $pane @roost-reply-turn ; set-option -pu -t $pane @roost-transcript ; set-option -pu -t $pane @roost-blocked-on ; set-option -pu -t $pane @roost-stop-swallowed ; set-option -pu -t $pane @roost-dialog ; set-option -pu -t $pane @roost-answered ; set-option -pu -t $pane @roost-answer-nonce ; set-option -pu -t $pane @roost-background ; set-option -pu -t $pane @roost-background-types ; set-option -pu -t $pane @roost-background-session ; set-option -p -t $pane @roost-ended '$since interrupted' ; set-option -p -t $pane @roost-unblocked '$now since=$since by=$ROOST_UNBLOCK_TOKEN'" \
    2>/dev/null || return 1
  . "${BASH_SOURCE[0]%/*}/roost-events.sh" 2>/dev/null || true
  roost_events_unblocked "$pane" "$now" "$since" blocked "the dialog was declined or dismissed" "$ROOST_UNBLOCK_TOKEN" 2>/dev/null || true
  [ "$(t show-options -pqv -t "$pane" @agent_state 2>/dev/null || true)" != "blocked" ] \
    && [ "$(t show-options -pqv -t "$pane" @roost-unblocked 2>/dev/null || true)" = "$now since=$since by=$ROOST_UNBLOCK_TOKEN" ] \
    || return 1
  # The empty turn (#95), as roost_interrupted_pane below writes it, and for
  # the same reason; fails soft the same way.
  roost_unblock_record_turn "$pane"
  return 0
}


# --- an interrupted turn (#95) -----------------------------------------------
#
# Step 2 of docs/airig/specs/2026-09-29-turn-over-design.md. Esc while the
# model streams, and Esc while a foreground tool runs, fire NO Claude hook at
# all -- measured on 2.1.283 (M5, M6 there) and again on 2.1.310 (known-gaps,
# "Step 1 measurements"): no Stop, no StopFailure, no PostToolUseFailure, no
# Notification in 80 s. So the ⏳ UserPromptSubmit stamped stays until the next
# prompt, `wait-done` burns its timeout, and `read` calls the previous reply
# stale for ever. What Claude DOES write is its transcript, and the two tails
# are fixed shapes:
#
#   mid-stream   assistant  (the partial answer; isAbortedMidStream on 2.1.310)
#                user       message.content = [text "[Request interrupted by user]"]
#   mid-tool     user       message.content = [tool_result "The user doesn't want
#                           to proceed with this tool use. …"], toolDenialKind
#                           "user-rejected"
#                user       message.content = [text "[Request interrupted by user
#                           for tool use]"]
#
# and, unlike the declined dialog above, NO `system turn_duration` after
# either. The decline's three records on a blocked pane are the reader above;
# these two pairs on a WORKING pane are this one. Same rules, same reasons:
#
#   1. The pane reads `working` at PANE scope. A blocked pane is a dialog, and
#      the decline reader's; a done or idle pane has nothing to recover.
#   2. @roost-transcript is "<@agent_since> <absolute path>" and its first
#      word equals the pane's @agent_since. UserPromptSubmit writes it with
#      the `working` stamp (scripts/roost-agent-state), and the transition
#      out of a dialog re-stamps it, so a working pane has one for its own
#      turn and never an earlier turn's.
#   3. The transcript is a readable regular file, and a JSON reader exists.
#   4. Walking backwards from the last line, skipping only the SKIP types,
#      the first two records are exactly one of the two pairs above, in order,
#      each with a timestamp no older than @agent_since. An unknown record
#      type, a line that is not JSON, a missing timestamp, a turn_duration, a
#      tool_use that is not the rejection: cannot tell, stay working. A newer
#      prompt after the Esc stamps a newer @agent_since than the marker, so
#      rule 4 fails and nothing is cleared -- which is right: that pane is
#      working on the newer prompt.
#   5. The clear is a compare-and-clear in one tmux command.
#
# What it writes: it UNSETS @agent_state (never a value), @roost-reply (a turn
# that fired no Stop left the previous turn's answer there), @roost-reply-turn,
# @roost-transcript and a hold record (#97: the turn is over, so nothing holds
# it -- the held main reply becomes the turn's text below), and writes @roost-ended "<since> interrupted" -- the
# record `wait-done` reads to exit 5 instead of 0, ignored by every reader
# unless its first word still equals @agent_since -- and @roost-unblocked
# "<now> since=<stamp>", as the decline does. Then ONE EMPTY TURN FILE with an
# `outcome` sidecar of `interrupted` (scripts/lib/roost-record.sh), so the
# interrupted prompt keeps its number and the next prompt's reply does not
# take it (§5.4): `wait-done --turn N` on it exits 5, `read --turn N` prints
# nothing and says why.
#
# What can break it: the transcript format is Claude's, not a contract. A
# renamed marker fails closed -- the pane stays working, as before #95 -- and
# the live smoke tests under tests/live/ are the guard after a Claude upgrade.

# roost_claude_interrupted FILE SINCE -> 0 iff FILE's tail is one of the two
# interrupt shapes, no older than SINCE (epoch seconds). python3 first, then
# jq; with neither, nothing can be known and the answer is no.
roost_claude_interrupted() {
  [ -f "$1" ] && [ -r "$1" ] || return 1
  case "$2" in ''|*[!0-9]*) return 1 ;; esac
  if command -v python3 >/dev/null 2>&1; then
    roost_claude_interrupted_py "$1" "$2"
  elif command -v jq >/dev/null 2>&1; then
    roost_claude_interrupted_jq "$1" "$2"
  else
    return 1
  fi
}

roost_claude_interrupted_py() {
  [ -f "$1" ] && [ -r "$1" ] || return 1
  case "$2" in ''|*[!0-9]*) return 1 ;; esac
  python3 - "$1" "$2" "$ROOST_UNBLOCK_TAIL_BYTES" <<'PY' 2>/dev/null
import json
import sys
from datetime import datetime, timezone

# The same SKIP set as the decline reader, for the same reason: a type not
# named here is not skipped, and an unknown type means "cannot tell".
SKIP = {
    "last-prompt", "ai-title", "mode", "permission-mode", "atis-latch",
    "bridge-session", "attachment", "file-history-snapshot",
}
STREAM = "[Request interrupted by user]"
TOOL = "[Request interrupted by user for tool use]"
REJECT = "The user doesn't want to proceed with this tool use."


def stamp(rec):
    t = rec.get("timestamp")
    if not isinstance(t, str):
        return None
    try:
        return datetime.strptime(t, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return None


def content(rec):
    msg = rec.get("message")
    return msg.get("content") if isinstance(msg, dict) else None


def is_text(rec, text):
    return rec.get("type") == "user" and content(rec) == [{"type": "text", "text": text}]


def is_assistant(rec):
    return rec.get("type") == "assistant" and isinstance(rec.get("message"), dict)


def is_rejection(rec):
    c = content(rec)
    return (rec.get("type") == "user"
            and rec.get("toolDenialKind") == "user-rejected"
            and isinstance(c, list) and len(c) > 0
            and all(isinstance(b, dict) and b.get("type") == "tool_result"
                    and isinstance(b.get("content"), str) and b["content"].startswith(REJECT)
                    for b in c))


def main():
    path, since, limit = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    with open(path, "rb") as fh:
        fh.seek(0, 2)
        size = fh.tell()
        start = max(0, size - limit)
        fh.seek(start)
        lines = fh.read().split(b"\n")
    if start > 0:
        lines = lines[1:]      # a seek lands mid-line; that line is not a record
    want = None
    for raw in reversed(lines):
        if not raw.strip():
            continue
        rec = json.loads(raw)  # not JSON: raises, and the answer is no
        if not isinstance(rec, dict):
            return 1
        if rec.get("type") in SKIP:
            continue
        t = stamp(rec)
        if t is None or t < since:
            return 1
        if want is None:
            # The newest conversation record decides which pair this could be.
            if is_text(rec, STREAM):
                want = is_assistant
            elif is_text(rec, TOOL):
                want = is_rejection
            else:
                return 1
            continue
        return 0 if want(rec) else 1
    return 1


try:
    sys.exit(main())
except Exception:
    sys.exit(1)
PY
}

roost_claude_interrupted_jq() {
  [ -f "$1" ] && [ -r "$1" ] || return 1
  case "$2" in ''|*[!0-9]*) return 1 ;; esac
  local size cut
  size="$(wc -c < "$1" 2>/dev/null | tr -d ' ')"
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  cut=0; [ "$size" -gt "$ROOST_UNBLOCK_TAIL_BYTES" ] && cut=1
  # The python walk as a filter, the shape of roost_claude_declined_jq: the
  # newest two conversation records, both no older than SINCE, forming one
  # of the two pairs.
  tail -c "$ROOST_UNBLOCK_TAIL_BYTES" "$1" 2>/dev/null | jq -R -s -e \
    --argjson since "$2" --argjson cut "$cut" '
    def skip: ["last-prompt","ai-title","mode","permission-mode","atis-latch",
               "bridge-session","attachment","file-history-snapshot"];
    def stamp: try (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null;
    def recent: type == "object" and (stamp | type) == "number" and stamp >= $since;
    def is_text(t): .type == "user" and .message.content == [{"type": "text", "text": t}];
    def is_rejection: .type == "user" and .toolDenialKind == "user-rejected"
      and (.message.content | type) == "array" and (.message.content | length) > 0
      and (.message.content | all(.[]; type == "object" and .type == "tool_result"
            and (.content | type) == "string"
            and (.content | startswith("The user doesn'"'"'t want to proceed with this tool use."))));
    [ split("\n") | (if $cut == 1 then .[1:] else . end)[]
      | select(test("^\\s*$") | not)
      | (try fromjson catch "not json") ]
    | reverse
    | map(select((type == "object" and ((.type | tostring) as $t | skip | index($t))) | not))
    | .[0:2] as $r
    | ($r | length) == 2
      and ($r | all(.[]; recent))
      and ((($r[0] | is_text("[Request interrupted by user]"))
            and $r[1].type == "assistant" and ($r[1].message | type) == "object")
           or (($r[0] | is_text("[Request interrupted by user for tool use]"))
               and ($r[1] | is_rejection)))
    ' >/dev/null 2>&1
}

# roost_interrupted_pane TARGET -> 0 iff TARGET's pane read `working`, its
# transcript ends in an interrupt for this stamp, and it was cleared here.
# Any other answer is 1, and a 1 changes nothing. Needs bin/roost's `t` and
# `record_for`.
roost_interrupted_pane() {
  local info pane since state rec rsince rpath now
  info="$(t display-message -p -t "$1" '#{pane_id} #{@agent_since}' 2>/dev/null || true)"
  pane="${info%% *}"
  since="${info#* }"
  case "$pane" in %[0-9]*) : ;; *) return 1 ;; esac
  state="$(t show-options -pqv -t "$pane" @agent_state 2>/dev/null || true)"
  [ "$state" = "working" ] || return 1
  case "$since" in ''|*[!0-9]*) return 1 ;; esac
  rec="$(t show-options -pqv -t "$pane" @roost-transcript 2>/dev/null || true)"
  rsince="${rec%% *}"
  rpath="${rec#* }"
  [ -n "$rec" ] && [ "$rsince" = "$since" ] || return 1
  case "$rpath" in /*) : ;; *) return 1 ;; esac
  roost_claude_interrupted "$rpath" "$since" || return 1
  now="$(date +%s)"
  roost_unblock_token
  roost_unblock_held_reply "$pane" "$since"
  # One tmux command, test and unsets together, as the decline's clear. The
  # outcome record is written in the same command: a reader that sees the
  # badge gone finds the reason beside it, or finds neither.
  # The hold record, its types and its owner (@roost-background-session,
  # #188) go with the badge, as in the decline's clear.
  t if-shell -F -t "$pane" \
    "#{&&:#{==:#{@agent_state},working},#{==:#{@agent_since},$since}}" \
    "set-option -pu -t $pane @agent_state ; set-option -pu -t $pane @roost-reply ; set-option -pu -t $pane @roost-reply-turn ; set-option -pu -t $pane @roost-transcript ; set-option -pu -t $pane @roost-background ; set-option -pu -t $pane @roost-background-types ; set-option -pu -t $pane @roost-background-session ; set-option -p -t $pane @roost-ended '$since interrupted' ; set-option -p -t $pane @roost-unblocked '$now since=$since by=$ROOST_UNBLOCK_TOKEN'" \
    2>/dev/null || return 1
  # This caller's token, not the second: see roost_unblock_token.
  [ "$(t show-options -pqv -t "$pane" @agent_state 2>/dev/null || true)" != "working" ] \
    && [ "$(t show-options -pqv -t "$pane" @roost-unblocked 2>/dev/null || true)" = "$now since=$since by=$ROOST_UNBLOCK_TOKEN" ] \
    || return 1
  . "${BASH_SOURCE[0]%/*}/roost-events.sh" 2>/dev/null || true
  roost_events_unblocked "$pane" "$now" "$since" working "the turn was interrupted" "$ROOST_UNBLOCK_TOKEN" 2>/dev/null || true
  # The empty turn (#95, §5.4): only for a pane whose record this roost can
  # write (state 0) or that has none yet (1); an unreadable or newer record
  # is left alone, as everywhere. Fails soft: the badge is already cleared
  # and `wait-done` reads @roost-ended, so a record that could not be written
  # costs the turn number, never the outcome.
  roost_unblock_record_turn "$pane"
  return 0
}


# --- the pane whose agent died (#105, part 2) ----------------------------------
#
# Step 5 of docs/airig/specs/2026-09-29-turn-over-design.md, §4.4. An agent
# typed at a shell prompt and killed there leaves the pane alive at its
# prompt, pane_dead 0 and the badge busy, and no hook ever says otherwise.
# #64 taught `wait-done` to see it -- job_gone in bin/roost, from the job the
# sink recorded in @roost-agent-job and two kernel facts about it -- but
# `wait-done` only EXITED 2: the badge went on reading working, `read` called
# the previous turn's reply stale for ever, and `send` refused a pane left
# blocked with exit 3 for a dialog nobody will ever answer. This moves that
# one check into one function the three share, as roost_unblock_pane is
# shared above, and on a death it does what the recovery channel may do
# (§4.1): UNSET, and record why.
#
# `status` does NOT call it. A read command stays a read command (the human's
# Q6): `status` shows what is stored and changes nothing.
#
# The rules, each fail-closed, the shape of the two readers above:
#
#   1. The pane reads `working` or `blocked` at PANE scope. A done, idle or
#      error pane finished first and keeps its answer.
#   2. job_gone says the recorded job has no process left AND the pane's
#      shell holds the terminal again. Both facts are the kernel's; there is
#      still no process-tree walk here, as wait-done's comment requires ("both
#      guess"). The report filter's walk (scripts/lib/roost-ancestry.sh)
#      admits reports and never declares a death (§4.4).
#   3. The clear is a compare-and-clear in one tmux command: the state, the
#      stamp and the job record must still be the ones read, so a new agent
#      typed at the same prompt that has stamped in between wins. A new agent
#      that reports `working` onto the pane that already reads working is a
#      repeat to the sink's unchanged-state bail, which used to write nothing,
#      so all three still matched and its live badge was cleared (fix round 1,
#      found by review, reproduced). The sink now treats a busy report over a
#      job record with no process left as a transition: it re-records the job
#      and restamps, and this compare fails (scripts/roost-agent-state, the
#      stale-job check). tests/test-died-shared.sh forces the interleaving.
#
# What it writes: it UNSETS @agent_state (never a value), @roost-agent-job
# (the job is gone; a later check must not judge a new agent by it), the
# dialog records when the pane was blocked (no dialog is open in a shell),
# @roost-transcript and the hold record with its types and owner (the turn is
# over), and -- unless the pane was held by background work (#97) -- the reply
# and its pointer, which are the previous turn's: no Stop replaced them, and a
# reply left on an unbadged pane is served as current with nothing on stderr.
# A HELD pane's reply is this turn's main answer, kept only on the pane, so it
# stays, and `read` says the agent died (its #188 wording, which is the truth
# for a held pane). It writes @roost-ended "<stamp> died" -- `wait-done` exits
# 2 on it, as it does for every pane whose agent is gone -- and
# @roost-unblocked "<now> since=<stamp> by=<token>", as the two readers above
# do, so the event log (#98) can name the clear and a false one can be found.
#
# THE TURN FILE. The interrupt recovery appends an empty turn so the next
# prompt cannot take the interrupted prompt's number (§5.4), and this does
# the same, through the same function, with its own outcome word:
# `died_in_shell`. The first cut filed nothing, on the ground that an empty
# `died` turn would be read back in SessionEnd's words ("before its
# background work finished"), which is not what happened here. But filing
# nothing lost the outcome: the clear removes the badge and the job record
# job_gone needs, so the FIRST `wait-done --turn N` exited 2 and the second
# timed out -- or, with no bound, was answered by the next agent's turn N
# (fix round 1, found by review, reproduced). A word of its own keeps both:
# the turn has its number, and `read --turn` and `wait-done --turn` say the
# agent exited inside its shell. A held pane's main reply is the turn's text,
# as the interrupt recovery files it; it also stays on the pane (below).
#
# THE NUMBER IS RESERVED IN THE CLEAR (fix round 2, found by review,
# reproduced both ways). The clear removes the badge and the turn file lands
# after it, and a replacement agent typed at the prompt inside that gap is a
# new turn on an unbadged pane. When the replacement also FINISHED inside
# it, its Stop took turn N and the death was filed as N+1, so `wait-done
# --turn N` answered the dead prompt with the replacement's reply. When it
# reported before the clear was read back, the read-back saw its badge and
# called the clear refused, and the death was never filed at all. #188's
# SessionEnd release had both holes and closed them first; this is the same
# mechanism (scripts/roost-agent-state, THE TURN NUMBER IS RESERVED IN THE
# RELEASE; scripts/lib/roost-record.sh, roost_record_reserved):
#
#   - the number is decided before the clear and written as
#     @roost-turn-reserved in the clear's own command, so no Stop can file
#     before it, and every appender after it starts above it;
#   - a clear that LANDED is told from one that was refused by the token
#     alone, never by the badge, and files its turn at the reserved number
#     even when a newer turn has superseded it;
#   - only a clear that is still the pane's (OURS) logs its event line, puts
#     a held reply back, or returns 0: after a superseded one the pane is the
#     replacement's, and `send`, `read` and `wait-done` go on with it.
#
# A replacement that reported before the clear ran is the stale-job check's
# (rule 3): it files the dead turn itself, before it restamps.
#
# The two known misses of job_gone stay as they are: Claude's `caffeinate`
# helper keeps its job alive for up to ~300 s, and a wrapper that outlives
# its agent keeps it for ever. Both are a badge that stays busy, never a
# false `died`.

# roost_died_pane TARGET -> 0 iff TARGET's pane read busy, its recorded agent
# job is gone, and the pane was cleared here. Any other answer is 1, and a 1
# changes nothing. Needs bin/roost's `t` and `job_gone`.
roost_died_pane() {
  local info pane since state ppid job now held_wr res res_wr hint created sockp ours
  # `|` between the fields: none can hold one. The pane pid and the job keep
  # a fixed letter in front, as wait-done's snapshot does (#165): either can
  # be EMPTY, and the letter keeps the fields where they are.
  info="$(t display-message -p -t "$1" '#{pane_id}|#{@agent_since}|#{@agent_state}|p#{pane_pid}|j#{@roost-agent-job}' 2>/dev/null || true)"
  pane="${info%%|*}"; info="${info#*|}"
  since="${info%%|*}"; info="${info#*|}"
  state="${info%%|*}"; info="${info#*|}"
  ppid="${info%%|*}"; job="${info#*|}"
  case "$pane" in %[0-9]*) : ;; *) return 1 ;; esac
  # Pane scope only, as everywhere: a window- or global-scope value is not
  # this pane's badge.
  state="$(t show-options -pqv -t "$pane" @agent_state 2>/dev/null || true)"
  case "$state" in working|blocked) : ;; *) return 1 ;; esac
  case "$since" in ''|*[!0-9]*) return 1 ;; esac
  job_gone "${ppid#p}" "$job" || return 1
  # job_gone accepted it, so it is "PGID:PANE_PID", digits and one colon:
  # safe inside the format below.
  job="${job#j}"
  now="$(date +%s)"
  roost_unblock_token
  roost_unblock_held_reply "$pane" "$since"
  if [ -n "$ROOST_UNBLOCK_HELD" ]; then
    held_wr=""
  else
    held_wr="set-option -pu -t $pane @roost-reply ; set-option -pu -t $pane @roost-reply-turn ; "
  fi
  # The turn's number, reserved before the clear (THE NUMBER, above). Only
  # for a record this roost can write (state 0) or that has none yet (1),
  # the rule roost_unblock_record_turn keeps; the record is created here if
  # the pane has none, which is not a turn. The `.reserving.<token>` hint is
  # written first, so it is there before the reservation can be, and removed
  # last. Records off, a record roost cannot write, a hint that cannot be
  # written: no number, and the clear is the same command without it.
  res="" res_wr="" hint="" created=0 sockp=""
  if record_for "$pane" "$pane" && [ "$RF_LIVE" = 1 ]; then
    case "$RF_STATE" in
      0|1)
        sockp="$(t display-message -p '#{socket_path}' 2>/dev/null || true)"
        if roost_record_ensure "$RF_DIR" "$sockp"; then
          created="$ROOST_RECORD_CREATED"
          hint="$RF_DIR/replies/.reserving.$ROOST_UNBLOCK_TOKEN"
          if { : > "$hint"; } 2>/dev/null; then
            # Above the newest turn, and above a number a SessionEnd release
            # or another clear holds on this pane: two reserve two numbers.
            roost_record_scan "$RF_DIR/replies"
            res=$((ROOST_RECORD_MAX + 1))
            roost_record_reserved "$RF_DIR" "$sockp"
            if [ -n "$ROOST_RECORD_RESERVED" ] && [ "$ROOST_RECORD_RESERVED" -ge "$res" ]; then
              res=$((ROOST_RECORD_RESERVED + 1))
            fi
            res_wr=" ; set-option -p -t $pane @roost-turn-reserved $res"
          else
            hint=""
          fi
        fi ;;
    esac
  fi
  t if-shell -F -t "$pane" \
    "#{&&:#{==:#{@agent_state},$state},#{&&:#{==:#{@agent_since},$since},#{==:#{@roost-agent-job},$job}}}" \
    "set-option -pu -t $pane @agent_state ; ${held_wr}set-option -pu -t $pane @roost-agent-job ; set-option -pu -t $pane @roost-transcript ; set-option -pu -t $pane @roost-blocked-on ; set-option -pu -t $pane @roost-stop-swallowed ; set-option -pu -t $pane @roost-dialog ; set-option -pu -t $pane @roost-answered ; set-option -pu -t $pane @roost-answer-nonce ; set-option -pu -t $pane @roost-background ; set-option -pu -t $pane @roost-background-types ; set-option -pu -t $pane @roost-background-session ; set-option -p -t $pane @roost-ended '$since died' ; set-option -p -t $pane @roost-unblocked '$now since=$since by=$ROOST_UNBLOCK_TOKEN'$res_wr" \
    2>/dev/null || true
  # LANDED is this caller's token, not the second (see roost_unblock_token),
  # and that alone decides whether the turn is filed. Nothing but a recovery
  # writes @roost-unblocked, and a new stamp leaves it, so a token read back
  # is a clear that landed. OURS is narrower: the pane still shows the clear.
  # A replacement that stamped in between SUPERSEDED it; it did not refuse
  # it, and the dead turn is still filed (THE NUMBER, above). The first fix
  # read the badge as well, so a replacement that reported before this read
  # made a landed clear look refused, and the death was never filed (fix
  # round 2, found by review, reproduced).
  info="$(t display-message -p -t "$pane" '#{@agent_state}|#{@roost-ended}|#{@roost-unblocked}' 2>/dev/null || true)"
  if [ "${info##*|}" != "$now since=$since by=$ROOST_UNBLOCK_TOKEN" ]; then
    [ -z "$hint" ] || rm -f "$hint" 2>/dev/null || true
    return 1
  fi
  ours=0
  [ "$info" != "|$since died|$now since=$since by=$ROOST_UNBLOCK_TOKEN" ] || ours=1
  if [ "$ours" = 1 ]; then
    . "${BASH_SOURCE[0]%/*}/roost-events.sh" 2>/dev/null || true
    roost_events_unblocked "$pane" "$now" "$since" "$state" "the agent exited inside its shell" "$ROOST_UNBLOCK_TOKEN" 2>/dev/null || true
  fi
  # The turn file (above): only the caller whose clear landed, as the two
  # recoveries above. Fails soft the same way: @roost-ended already says died.
  # Filed at the reserved number. A plain assignment, never a prefix on the
  # call: bash exports a prefix assignment to a function's children for the
  # length of the call (the SessionEnd block says the same). A superseded
  # clear with no number reserved files nothing: the replacement's turn may
  # already sit at the next number, and filing after it would put the death
  # under a number no prompt was sent as. Its held reply is not put back
  # either: the pane's reply is the replacement's now.
  if [ -n "$res" ]; then
    ROOST_RECORD_AT="$res"
    roost_unblock_record_turn "$pane" died_in_shell "$ours"
    ROOST_RECORD_AT=""
    [ "$created" != 1 ] || roost_record_sweep
    # The reservation goes once the turn is filed, or could not be, and only
    # while it is still this call's. No pointer (@roost-reply-turn) is
    # written after the clear, here or in roost_unblock_record_turn: the
    # clear unset the old one with the reply, and a newer turn's pointer is
    # the one its own Stop set, left alone.
    t if-shell -F -t "$pane" "#{==:#{@roost-turn-reserved},$res}" \
      "set-option -pu -t $pane @roost-turn-reserved" 2>/dev/null || true
  elif [ "$ours" = 1 ]; then
    roost_unblock_record_turn "$pane" died_in_shell
  fi
  [ -z "$hint" ] || rm -f "$hint" 2>/dev/null || true
  [ "$ours" = 1 ] || return 1
  return 0
}
