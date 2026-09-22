# roost-unblock.sh — clear a Claude Code `blocked` badge that a declined or
# dismissed permission dialog left behind (#38), and only clear it.
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
# Only unsets, plus one record of its own. It UNSETS @agent_state (never writes
# a value: setting state is the job of a harness event), @roost-reply (a
# declined turn fired no Stop, so what is stored is the previous turn's answer),
# @roost-transcript, @roost-blocked-on (the description of the dialog that has
# just been declined, #91) and @roost-stop-swallowed (that dialog's one-Stop
# allowance, spent or not), and writes @roost-unblocked "<now>
# since=<stamp>" so a false clear can be found later. It never writes anything
# under ~/.claude: the transcript is only ever opened for reading.
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
  # One tmux command: the condition is evaluated and the unsets run with no
  # other client able to act in between. $since is digits only (checked
  # above) and $pane is %N, so neither can break out of the format or the
  # command string.
  t if-shell -F -t "$pane" \
    "#{&&:#{==:#{@agent_state},blocked},#{==:#{@agent_since},$since}}" \
    "set-option -pu -t $pane @agent_state ; set-option -pu -t $pane @roost-reply ; set-option -pu -t $pane @roost-transcript ; set-option -pu -t $pane @roost-blocked-on ; set-option -pu -t $pane @roost-stop-swallowed ; set-option -p -t $pane @roost-unblocked '$now since=$since'" \
    2>/dev/null || return 1
  [ "$(t show-options -pqv -t "$pane" @agent_state 2>/dev/null || true)" != "blocked" ] \
    && [ "$(t show-options -pqv -t "$pane" @roost-unblocked 2>/dev/null || true)" = "$now since=$since" ]
}
