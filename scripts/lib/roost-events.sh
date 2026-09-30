# roost-events.sh — the event log behind `roost events` (#98): one JSON line
# per state change, appended to a file, so a program that wants every change
# can tail it instead of polling `roost status --json`.
#
# Sourced by scripts/roost-agent-state (the writer) and by bin/roost (`events`
# reads it, `forget --all` clears it). No daemon and no socket: a file, and a
# reader that follows it.
#
# WHERE. $ROOST_EVENTS when it is SET, which wins outright — "" is the off
# switch, the way ROOST_RECORD_DIR="" turns kept replies off, and anything that
# is not an absolute path is off too. Unset, the log lives in `events/` inside
# the kept-replies root (scripts/lib/roost-record.sh), beside the per-server
# directories that hold the replies, and it follows that root's "recording is
# off" rule: no root, no log. So tests/lib.sh's ROOST_RECORD_DIR="" keeps the
# whole suite off this path too.
#
# THE LAYOUT, plain files, no parser:
#
#   events/gen        one line, "<epoch>-<pid>": this log's generation. A new
#                     one is made whenever the directory is made again, which
#                     is what lets a cursor from before `forget --all` be told
#                     apart from one into the new log
#   events/000001 ... segments, oldest first. Writers append to the newest
#
# A CURSOR is "GEN:SEGMENT:OFFSET" — the byte offset in that segment just past
# the line it was printed with. `--since` starts reading there. Nothing stored
# carries it: the reader works it out as it reads, so a writer never needs to
# know where its line landed, and that is what lets writers take no lock.
#
# NO LOCK. macOS ships no flock(1). A line is ONE printf to a file opened with
# O_APPEND (`>>`), which the kernel places at the end and writes whole: POSIX
# makes the seek-and-write of an O_APPEND write atomic on a regular file, and a
# line is kept under this machine's 512-byte PIPE_BUF (getconf PIPE_BUF on
# macOS 26.3) so bash's builtin printf issues it as a single write(2). The
# 200-writer test in tests/test-events.sh is the evidence, with lines of 454
# bytes. A segment or the gen file is CREATED the roost-record.sh way: mktemp,
# then a hard link, which refuses a name that exists, so two writers rotating
# at once make one segment between them and neither loses its line.
#
# ROTATION keeps at least the newest ROOST_EVENTS_KEEP lines (default 5000) and
# at most a quarter more. A segment holds KEEP/4 lines; when an append brings
# the newest segment to that, the next one is created, empty, and the oldest
# segments beyond five are removed. Five segments, the newest possibly empty,
# are four full ones: KEEP lines. Every line is under 512 bytes, so the log is
# also bounded by size — 5000 lines is at most ~3 MB, ~1 MB at the ~200-byte
# lines the hook writes.
#
# Everything here is bash 3.2: no associative arrays, no ${a[@]} on an array
# that may be empty under `set -u`, no printf %(...)T.

ROOST_EVENTS_SCHEMA=1
# The line cap, in bytes, before the newline. Under PIPE_BUF (512) with room to
# spare; see NO LOCK above.
ROOST_EVENTS_LINE_MAX=500
# Segments kept. Four full, plus the newest one being filled.
ROOST_EVENTS_SEGMENTS=5

# roost-record.sh gives the root, the "recording is off" rule, the boot key's
# shape check and the numeric segment scan. Sourced by path relative to this
# file, so neither caller has to know the order.
. "${BASH_SOURCE[0]%/*}/roost-record.sh"

# roost_events_dir -> ROOST_EVENTS_DIR, the log's directory, or "" when the log
# is off. SETS rather than prints, the roost_record_root shape: a $(...) is a
# fork, and the hook calls this on every state change.
roost_events_dir() {
  local r
  ROOST_EVENTS_DIR=""
  if [ "${ROOST_EVENTS+set}" = set ]; then
    r="$ROOST_EVENTS"
  else
    roost_record_root
    [ -n "$ROOST_RECORD_ROOT" ] || return 0
    r="$ROOST_RECORD_ROOT/events"
  fi
  case "$r" in /*) ;; *) return 0 ;; esac
  while [ "${r%/}" != "$r" ]; do r="${r%/}"; done
  [ -n "$r" ] || return 0
  ROOST_EVENTS_DIR="$r"
}

# roost_events_keep -> ROOST_EVENTS_SEG_LINES, the lines one segment holds:
# a quarter of ROOST_EVENTS_KEEP (a positive integer, else 5000), at least 1.
roost_events_keep() {
  local LC_ALL=C k
  case "${ROOST_EVENTS_KEEP:-}" in
    ''|*[!0-9]*|0*) k=5000 ;;
    *) k="$ROOST_EVENTS_KEEP" ;;
  esac
  # Past nine digits the arithmetic below is not ours to trust.
  [ "${#k}" -le 9 ] || k=5000
  ROOST_EVENTS_SEG_LINES=$(( (k + 3) / 4 ))
}

# roost_events_seg DIR N -> ROOST_EVENTS_FILE, segment N's path.
roost_events_seg() {
  local name
  printf -v name '%06d' "$2"
  ROOST_EVENTS_FILE="$1/$name"
}

# roost_events__create FILE CONTENT — create FILE holding CONTENT unless it
# exists: mktemp (0600), then a hard link, which refuses a name that is there.
# 0 when FILE exists afterwards, whoever made it.
roost_events__create() {
  local tmp
  [ -f "$1" ] && return 0
  tmp="$(mktemp "${1%/*}/.tmp.XXXXXX" 2>/dev/null)" || return 1
  if ! { printf '%s' "$2" > "$tmp"; } 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  ln "$tmp" "$1" 2>/dev/null || true
  rm -f "$tmp"
  [ -f "$1" ]
}

# roost_events_gen DIR -> ROOST_EVENTS_GEN, the log's generation, or "" when
# there is none (no log yet, or one a human damaged). `read`, not $(cat): no
# fork.
roost_events_gen() {
  local LC_ALL=C g=""
  ROOST_EVENTS_GEN=""
  [ -f "$1/gen" ] || return 1
  IFS= read -r g < "$1/gen" || [ -n "$g" ] || true
  case "$g" in
    [0-9]*-[0-9]*) ;;
    *) return 1 ;;
  esac
  case "${g%%-*}${g#*-}" in ''|*[!0-9]*) return 1 ;; esac
  ROOST_EVENTS_GEN="$g"
}

# roost_events_write LINE [nocreate] — append LINE to the log, and rotate if
# it is due. With `nocreate`, only when a log (a valid gen file) is there.
# Always returns 0: the hook that calls this is on every live agent's state
# change, and a log that cannot be written must never break the agent.
#
# The forks: `wc -l` on every call, to decide rotation, and mkdir, mktemp, ln
# and date only when a directory, the gen file or a segment is first made.
roost_events_write() {
  local LC_ALL=C line="$1" dir seg n
  roost_events_dir
  dir="$ROOST_EVENTS_DIR"
  [ -n "$dir" ] || return 0
  [ "${#line}" -le "$ROOST_EVENTS_LINE_MAX" ] || return 0
  # `nocreate`: write only into a log that is already there. The close check
  # passes it: a run that was still waiting when `forget --all` removed the log
  # must not bring the log back with its own lines (review round 2 found a
  # removed directory back in /tmp, holding a new gen and three closed lines).
  if [ "${2:-}" = nocreate ]; then
    roost_events_gen "$dir" || return 0
  fi
  if [ ! -d "$dir" ]; then
    # 0700 on the directory this creates, and on the root when it creates
    # that too — the rule roost_record_append follows: a line can name the
    # command a dialog is asking about. A root the user made keeps its mode.
    if [ ! -d "${dir%/*}" ]; then
      mkdir -p "${dir%/*}" 2>/dev/null || return 0
      chmod 700 "${dir%/*}" 2>/dev/null || true
    fi
    mkdir -m 700 "$dir" 2>/dev/null || [ -d "$dir" ] || return 0
  fi
  if ! roost_events_gen "$dir"; then
    roost_events__create "$dir/gen" "$(date +%s)-$$
" || return 0
  fi
  roost_record_scan "$dir"
  n="$ROOST_RECORD_MAX"
  if [ "$n" -eq 0 ]; then
    n=1
    roost_events_seg "$dir" "$n"
    roost_events__create "$ROOST_EVENTS_FILE" "" || return 0
  fi
  roost_events_seg "$dir" "$n"
  seg="$ROOST_EVENTS_FILE"
  # The one write. The braces carry 2>/dev/null to the redirection itself, so
  # a segment removed under the writer (a racing `forget --all`) prints
  # nothing from inside the hook.
  { printf '%s\n' "$line" >> "$seg"; } 2>/dev/null || return 0
  roost_events__rotate "$dir" "$n" "$seg"
  return 0
}

# roost_events__rotate DIR N SEGMENT — when SEGMENT (number N, the newest) is
# full, create N+1 and prune the oldest beyond ROOST_EVENTS_SEGMENTS.
#
# A writer that listed the segments just before N+1 was made appends to N a
# moment after it closed. Its line is not lost — it is in N, which readers
# still read — but a reader already past N does not go back for it.
# docs/known-gaps.md carries this, with how narrow the window is.
roost_events__rotate() {
  local LC_ALL=C dir="$1" n="$2" lines
  roost_events_keep
  lines="$(wc -l < "$3" 2>/dev/null)" || return 0
  lines="${lines//[!0-9]/}"
  [ -n "$lines" ] || return 0
  [ "$lines" -ge "$ROOST_EVENTS_SEG_LINES" ] || return 0
  roost_events_seg "$dir" $((n + 1))
  roost_events__create "$ROOST_EVENTS_FILE" "" || return 0
  roost_record_scan "$dir"
  while [ "$ROOST_RECORD_COUNT" -gt "$ROOST_EVENTS_SEGMENTS" ]; do
    roost_events_seg "$dir" "$ROOST_RECORD_MIN"
    [ -f "$ROOST_EVENTS_FILE" ] || return 0
    rm -f "$ROOST_EVENTS_FILE" || return 0
    roost_record_scan "$dir"
  done
}

# --- building a line ---------------------------------------------------------

# roost_events__plain VALUE -> 0 when VALUE can go into JSON between quotes as
# it is: letters, digits and a spelled-out set of printable punctuation, no `"`
# and no `\`. Spelled out rather than written as a range, because bash 3.2
# matches a range by the locale's collation. Anything else goes through
# roost_jsonout_encode, which costs an awk fork; the common line needs none.
roost_events__plain() {
  local LC_ALL=C
  case "$1" in
    *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\ ._:/%@=+,\(\)\;\'\#\$\&\*\<\>\?\[\]\^\{\|\}~\!-]*) return 1 ;;
  esac
  return 0
}

# roost_events_line TS SERVER PANE WINDOW SESSION_ID EVENT FROM TO TURN REASON
#   -> ROOST_EVENTS_LINE, one JSON object with no newline; 1 when it cannot be
#   built under ROOST_EVENTS_LINE_MAX.
#
# SESSION_ID, FROM, TO and TURN may be "" for null. The key is `session_id`,
# not `session`: in `status --json`, panes[].session is the TMUX session's
# name, and this is the harness's own session id, read from @roost-session. REASON is cut to 160 bytes, then
# to 40, then dropped, until the line fits: a line past PIPE_BUF could be torn
# by a racing writer, and a shorter reason is the cheaper loss.
roost_events_line() {
  local LC_ALL=C ts="$1" server="$2" pane="$3" window="$4" session="$5"
  local event="$6" from="$7" to="$8" turn="$9" reason="${10}"
  local cut j_from j_to j_session j_reason j_turn doc
  ROOST_EVENTS_LINE=""
  case "$ts" in ''|*[!0-9]*) return 1 ;; esac
  case "$turn" in ''|*[!0-9]*|0*) j_turn=null ;; *) j_turn="$turn" ;; esac
  for cut in 160 40 0; do
    reason="${reason:0:$cut}"
    if roost_events__plain "$server$pane$window$session$event$from$to$reason"; then
      j_session=null; [ -z "$session" ] || j_session="\"$session\""
      j_from=null; [ -z "$from" ] || j_from="\"$from\""
      j_to=null; [ -z "$to" ] || j_to="\"$to\""
      j_reason="\"$reason\""
      doc="{\"schema\":$ROOST_EVENTS_SCHEMA,\"ts\":$ts,\"server\":\"$server\",\"pane\":\"$pane\",\"window\":\"$window\",\"session_id\":$j_session,\"event\":\"$event\",\"from\":$j_from,\"to\":$j_to,\"turn\":$j_turn,\"reason\":$j_reason}"
    else
      # Only the reason can need this in practice — every other field is
      # checked to a plain shape before it gets here — but all of them go
      # through the encoder together, so no field is ever trusted to be plain.
      [ -n "$(type -t roost_jsonout_encode)" ] || . "${BASH_SOURCE[0]%/*}/roost-jsonout.sh"
      roost_jsonout_encode "$server" "$pane" "$window" "$session" "$event" "$from" "$to" "$reason" || return 1
      j_session=null; [ -z "$session" ] || j_session="${ROOST_JSONOUT_STR[3]}"
      j_from=null; [ -z "$from" ] || j_from="${ROOST_JSONOUT_STR[5]}"
      j_to=null; [ -z "$to" ] || j_to="${ROOST_JSONOUT_STR[6]}"
      doc="{\"schema\":$ROOST_EVENTS_SCHEMA,\"ts\":$ts,\"server\":${ROOST_JSONOUT_STR[0]},\"pane\":${ROOST_JSONOUT_STR[1]},\"window\":${ROOST_JSONOUT_STR[2]},\"session_id\":$j_session,\"event\":${ROOST_JSONOUT_STR[4]},\"from\":$j_from,\"to\":$j_to,\"turn\":$j_turn,\"reason\":${ROOST_JSONOUT_STR[7]}}"
    fi
    if [ "${#doc}" -le "$ROOST_EVENTS_LINE_MAX" ]; then
      ROOST_EVENTS_LINE="$doc"
      return 0
    fi
  done
  return 1
}

# --- the hook side -------------------------------------------------------------
#
# scripts/roost-agent-state calls roost_events_arm ONCE, just before its
# unchanged-state early exit, and only when the call can produce a line: a
# state change, or a `blocked` that repeats (a new dialog on a pane that is
# already blocked). The line itself is written by an EXIT trap, after every
# write the hook makes, for two reasons:
#
#   1. Both paths that need a line leave the script by different doors — the
#      repeat through the early `exit 0`, a transition by running off the end —
#      and one trap covers both with the single call line the hook is allowed.
#   2. A Stop that lands while a dialog is open is decided by TMUX, in the same
#      command as the write (#91), so only after the write can anyone know
#      whether the state moved. The trap reads the pane then, and writes no line
#      for a Stop that was held back.
#
# The trap is `roost_events__fire || true`. Measured on bash 3.2.57: under
# `set -e` a failing command inside an EXIT trap turns the script's exit status
# into 1, even over an explicit `exit 7`; with `|| true` the status the script
# chose is kept and `set -e` is off inside the handler. A hook's exit status is
# read by the harness, so the trap must never change it.
#
# The hook installs no other EXIT trap. One added later would replace this one
# silently; it would have to call roost_events__fire itself.

# roost_events_arm SOCKET PANE PREV STATE PERMISSION_REQUEST_HOOK STOP_WHILE_BLOCKED
roost_events_arm() {
  ROOST_EVENTS__SOCK="$1" ROOST_EVENTS__PANE="$2" ROOST_EVENTS__PREV="$3"
  ROOST_EVENTS__STATE="$4" ROOST_EVENTS__PRH="$5" ROOST_EVENTS__SWB="$6"
  ROOST_EVENTS__OLD_ON=""
  roost_events_dir
  [ -n "$ROOST_EVENTS_DIR" ] || return 0
  if [ "$4" = "$3" ]; then
    # A repeat can only be a blocked one (the call line checks), and only the
    # PermissionRequest hook says WHAT a dialog is about. The Notification for
    # the same dialog arrives six seconds later carrying nothing, and codex's
    # flagless `blocked` carries nothing either, so neither can say the dialog
    # changed. docs/known-gaps.md has the codex half.
    [ "$4" = blocked ] && [ "$5" = 1 ] || return 0
    # What the pane is blocked on BEFORE this hook stamps the new dialog. One
    # tmux read, on a pane that is already waiting on a human.
    ROOST_EVENTS__OLD_ON="$(tmux -S "$1" show-options -pqv -t "$2" @roost-blocked-on 2>/dev/null || true)"
  fi
  trap 'roost_events__fire || true' EXIT
}

# roost_events__fire — the EXIT trap. Reads the pane once, after every write,
# and appends at most one line.
#
# No `local LC_ALL=C` in this function: it runs tmux, and a tmux client started
# under an exported C locale prints tab, newline and non-ASCII as `_`
# (scripts/lib/roost-jsonout.sh's header has the measurement). The byte work is
# in roost_events_line and roost_events_write, which set it themselves.
roost_events__fire() {
  local info rest boot window cur on why session tabs event from to reason turn ts
  info="$(tmux -S "$ROOST_EVENTS__SOCK" display-message -p -t "$ROOST_EVENTS__PANE" \
    $'#{start_time}-#{pid}\t#{window_id}\t#{@agent_state}\t#{@roost-session}\t#{@roost-error-reason}\t#{@roost-blocked-on}' \
    2>/dev/null || true)"
  # Exactly five tabs, or the free text is not trusted: three of these fields
  # are text anyone can `tmux set` (or, for the error reason, export), and a
  # tab inside one would shift every field after it. The blocked-on text is
  # last, so a newline in it is simply cut off. When the count is wrong the
  # line is still written, from a second read of the three fields that cannot
  # hold a tab, with reason "" and session_id null: a state change is never
  # lost to a stray tab (review round 1 found it was).
  info="${info%%$'\n'*}"
  tabs="${info//[!$'\t']/}"
  if [ "${#tabs}" -ne 5 ]; then
    info="$(tmux -S "$ROOST_EVENTS__SOCK" display-message -p -t "$ROOST_EVENTS__PANE" \
      $'#{start_time}-#{pid}\t#{window_id}\t#{@agent_state}\t\t\t' 2>/dev/null || true)"
    info="${info%%$'\n'*}"
    tabs="${info//[!$'\t']/}"
    [ "${#tabs}" -eq 5 ] || return 0
  fi
  boot="${info%%$'\t'*}"; rest="${info#*$'\t'}"
  window="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
  cur="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
  session="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
  why="${rest%%$'\t'*}"; on="${rest#*$'\t'}"
  roost_events__shape "$boot" "$ROOST_EVENTS__PANE" "$window" || return 0
  # @roost-session is written by whatever records the harness's own session id.
  # It is taken only when it is the shape an id has; anything else is null.
  case "$session" in
    *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-]*) session="" ;;
  esac
  # The error reason and the blocked-on text are printed back as roost's own
  # words; a tab or newline in either is not.
  case "$why" in *$'\t'*|*$'\n'*) why="" ;; esac
  case "$on" in *$'\t'*|*$'\n'*) on="" ;; esac
  [ "${#session}" -le 64 ] || session=""

  from="$ROOST_EVENTS__PREV" to="$ROOST_EVENTS__STATE" reason=""
  if [ "$from" = "$to" ]; then
    # Still blocked, on something new. The pane must still read blocked —
    # anything else moved it since, and that writer logs its own line.
    [ "$cur" = blocked ] || return 0
    [ -n "$on" ] && [ "$on" != "$ROOST_EVENTS__OLD_ON" ] || return 0
    event=blocked_on reason="$on"
  else
    # A Stop held back under an open dialog left the pane blocked: no change.
    if [ "$ROOST_EVENTS__SWB" = 1 ] && [ "$cur" = blocked ]; then return 0; fi
    event=state
    case "$to" in
      blocked) reason="$on" ;;
      error) reason="$why" ;;
    esac
  fi
  case "$from" in blocked|working|done|error|idle) ;; *) from="" ;; esac

  roost_events__turn "$boot" "$ROOST_EVENTS__PANE" "$to"
  turn="$ROOST_EVENTS_TURN"
  ts="$(date +%s)"
  roost_events_line "$ts" "$boot" "$ROOST_EVENTS__PANE" "$window" "$session" \
    "$event" "$from" "$to" "$turn" "$reason" || return 0
  roost_events_write "$ROOST_EVENTS_LINE"
}

# roost_events__shape BOOT PANE WINDOW -> 0 when all three are the shapes tmux
# gives: they go into the line without an encoder.
roost_events__shape() {
  local LC_ALL=C
  case "$1" in [0-9]*-[0-9]*) ;; *) return 1 ;; esac
  case "${1%%-*}${1#*-}" in ''|*[!0-9]*) return 1 ;; esac
  case "$2" in %[0-9]*) ;; *) return 1 ;; esac
  case "${2#%}" in *[!0-9]*) return 1 ;; esac
  case "$3" in @[0-9]*) ;; *) return 1 ;; esac
  case "${3#@}" in *[!0-9]*) return 1 ;; esac
  return 0
}

# roost_events__turn BOOT PANE TO -> ROOST_EVENTS_TURN, the turn this line
# belongs to, numbered as `roost send` numbers them, or "" (null) when replies
# are not kept and there is no numbering.
#
# The newest recorded turn is N. A Stop that recorded its reply in this very
# call (ROOST_RECORD_TURN, set by roost-record.sh in the same shell) is turn
# N; everything else belongs to the turn not yet recorded, N+1 — the number
# `send` prints for a prompt, `wait-done --turn` waits for and a reply will be
# filed under. A turn that ends with no reply (an error, an interrupt) records
# nothing, so the next turn shares its number, exactly as `send` would say.
roost_events__turn() {
  local LC_ALL=C
  ROOST_EVENTS_TURN=""
  roost_record_root
  [ -n "$ROOST_RECORD_ROOT" ] || return 0
  roost_record_pane_dir "$1" "$2" || return 0
  if [ "$3" = done ]; then
    case "${ROOST_RECORD_TURN:-}" in
      ''|*[!0-9]*) ;;
      *) ROOST_EVENTS_TURN="$ROOST_RECORD_TURN"; return 0 ;;
    esac
  fi
  roost_record_scan "$ROOST_RECORD_PANE_DIR/replies"
  ROOST_EVENTS_TURN=$((ROOST_RECORD_MAX + 1))
}

# --- lines no hook writes ------------------------------------------------------
#
# Two changes happen without the agent's hook running, so the hook cannot log
# them: roost itself clearing a 🛑 after a declined dialog, and a pane closing.

# roost_events_unblocked PANE NOW SINCE — scripts/lib/roost-unblock.sh calls
# this after its one-command clear, with the stamp it wrote. The line is
# written only when that clear is what the pane now shows: @agent_state unset
# and @roost-unblocked holding exactly "NOW since=SINCE". Anything else means
# the clear did not land, or another writer has moved the pane since and logs
# its own line.
#
# `to` is null, as `status --json` shows the pane: the clear UNSETS the state.
# Needs bin/roost's `t`, the way the reader below does.
roost_events_unblocked() {
  local info rest boot window cur unb session
  roost_events_dir
  [ -n "$ROOST_EVENTS_DIR" ] || return 0
  # `|` between the fields, not a tab. This runs under bin/roost, whose tmux
  # client is not UTF-8 when the locale is not (no $TMUX, no UTF-8 LANG), and
  # such a client prints every tab as `_` — measured in the Ubuntu CI image,
  # where the tab-separated first version never wrote this line. None of the
  # first four values can hold a `|`; @roost-session is last and may hold
  # anything, so the remainder is it, and the shape check below throws out
  # whatever is not an id.
  info="$(t display-message -p -t "$1" \
    '#{start_time}-#{pid}|#{window_id}|#{@agent_state}|#{@roost-unblocked}|#{@roost-session}' \
    2>/dev/null || true)"
  info="${info%%$'\n'*}"
  case "$info" in *'|'*'|'*'|'*'|'*) ;; *) return 0 ;; esac
  boot="${info%%|*}"; rest="${info#*|}"
  window="${rest%%|*}"; rest="${rest#*|}"
  cur="${rest%%|*}"; rest="${rest#*|}"
  unb="${rest%%|*}"; session="${rest#*|}"
  [ -z "$cur" ] && [ "$unb" = "$2 since=$3" ] || return 0
  roost_events__shape "$boot" "$1" "$window" || return 0
  case "$session" in
    *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-]*) session="" ;;
  esac
  [ "${#session}" -le 64 ] || session=""
  roost_events__turn "$boot" "$1" ""
  roost_events_line "$(date +%s)" "$boot" "$1" "$window" "$session" \
    state blocked "" "$ROOST_EVENTS_TURN" "the dialog was declined or dismissed" || return 0
  roost_events_write "$ROOST_EVENTS_LINE"
}

# roost_events_reconcile SOCKET BOOT [PANE] — write a `closed` line for every
# pane of BOOT that the log knows and the server no longer has. tmux/roost.conf
# runs it (as `roost events --reconcile`, in the background) from the hooks
# that fire when a pane goes. Measured on tmux 3.4 and 3.6, with a logger on
# each hook of a throwaway server:
#
#   the pane's program exits   pane-exited      #{hook_pane} is the pane
#   kill-pane                  after-kill-pane  no pane, window or session id
#   kill-window                window-unlinked  #{hook_window} only
#   kill-session               session-closed, then window-unlinked
#   kill-server                nothing: no hook runs
#
# Three of the four name no pane, so this does not trust a hook to say which
# one went. It asks: every pane whose newest line in the log is not `closed`
# is a candidate, and ONE `list-panes` of the server at SOCKET decides for all
# of them (roost_events__panes, bounded at three seconds). A candidate the
# server no longer lists is gone; if the server itself is gone, every
# candidate is. A server that answers with another boot key, or no answer,
# writes nothing: "could not ask" is never read as "gone". PANE, from
# pane-exited, is gone by tmux's own word and is not looked for.
#
# `from` is the pane's last state in the log, `window` and `session_id` its
# last line's; `to` and `turn` are null. A pane with no line (a plain shell)
# gets none here either — and neither does a pane whose lines have all
# rotated out, because the candidates come from the log (docs/known-gaps.md).
#
# ONE AT A TIME. Several hooks fire for one close (a window's last pane
# exiting fires pane-exited and window-unlinked), and two runs reading the log
# at once would both find the pane open and both log it. A mkdir lock
# serialises them — this is not the hook's write path, which takes no lock —
# and the second run then reads the first one's line.
#
# A lock is taken over only when it is OLD — more than a minute, which no run
# takes — never because it is merely in the way. The first version took over
# any lock after five seconds of waiting, and two waiters then removed each
# other's fresh lock and logged one close twice (review round 2, reproduced).
# The take-over itself is done under a second lock, `.reconcile.take`, and the
# age is checked again once that is held, so two runs that both saw the old
# lock cannot both replace it: the second finds the first one's fresh lock.
# A run that waits five seconds on a lock that is not old gives up quietly.
# It loses little: the holder lists the server's panes after it took the lock.
roost_events_reconcile() {
  local sock="$1" boot="$2" known="${3:-}" dir lock k=""
  roost_events_dir
  dir="$ROOST_EVENTS_DIR"
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  roost_events_gen "$dir" || return 0
  case "$boot" in [0-9]*-[0-9]*) ;; *) return 0 ;; esac
  case "${boot%%-*}${boot#*-}" in ''|*[!0-9]*) return 0 ;; esac
  case "$known" in %[0-9]*) ;; *) known="" ;; esac
  lock="$dir/.reconcile"
  if ! mkdir "$lock" 2>/dev/null; then
    if roost_events__old "$lock" && mkdir "$lock.take" 2>/dev/null; then
      if roost_events__old "$lock"; then
        rmdir "$lock" 2>/dev/null
        mkdir "$lock" 2>/dev/null && k=held
      fi
      rmdir "$lock.take" 2>/dev/null
    fi
    if [ "$k" != held ]; then
      k=0
      until mkdir "$lock" 2>/dev/null; do
        k=$((k + 1))
        [ "$k" -lt 50 ] || return 0
        sleep 0.1 2>/dev/null || sleep 1
      done
    fi
  fi
  roost_events__reconcile "$sock" "$boot" "$known" "$dir"
  rmdir "$lock" 2>/dev/null
  return 0
}

# roost_events__old DIR -> 0 when DIR was last changed more than a minute ago.
# find's -maxdepth and -mmin exist in BSD, GNU and busybox find.
roost_events__old() {
  [ -n "$(find "$1" -maxdepth 0 -mmin +1 2>/dev/null)" ]
}

roost_events__reconcile() {
  local sock="$1" boot="$2" known="$3" dir="$4" s cand pane window from session rest
  roost_record_scan "$dir"
  [ "$ROOST_RECORD_COUNT" -gt 0 ] || return 0
  set --
  s="$ROOST_RECORD_MIN"
  while [ "$s" -le "$ROOST_RECORD_MAX" ]; do
    roost_events_seg "$dir" "$s"
    [ -f "$ROOST_EVENTS_FILE" ] && set -- "$@" "$ROOST_EVENTS_FILE"
    s=$((s + 1))
  done
  [ "$#" -gt 0 ] || return 0
  # One awk over the segments, oldest first: the newest line of each of
  # BOOT's panes, and of those, the ones that are not already closed. Every
  # value read here is one this lib wrote in a plain shape (%N, @N, a state
  # word, an id-shaped session_id), so none holds a quote or a tab.
  cand="$(LC_ALL=C awk -v boot="$boot" '
    function val(line, key,   i, r) {
      i = index(line, "\"" key "\":")
      if (i == 0) return ""
      r = substr(line, i + length(key) + 3)
      if (substr(r, 1, 1) != "\"") return ""
      r = substr(r, 2)
      return substr(r, 1, index(r, "\"") - 1)
    }
    index($0, "\"server\":\"" boot "\"") {
      p = val($0, "pane")
      if (p == "") next
      if (!(p in last)) order[++n] = p
      last[p] = $0
    }
    END {
      for (i = 1; i <= n; i++) {
        l = last[order[i]]
        if (val(l, "event") == "closed") continue
        printf "%s\t%s\t%s\t%s\n", order[i], val(l, "window"), val(l, "to"), val(l, "session_id")
      }
    }' "$@" 2>/dev/null)" || return 0
  # Nothing open in the log: nothing to ask the server about.
  [ -n "$cand" ] || return 0
  # ONE question to the server, whatever the fleet's size: every live pane
  # with its boot key. The first version asked roost_record_liveness once per
  # open pane — 31 tmux calls and 512 ms per run with 31 agents open, paid on
  # every close of every pane (review round 2).
  roost_events__panes "$sock" "$boot"
  case "$ROOST_EVENTS_SERVER" in answered|gone) ;; *) return 0 ;; esac
  while IFS= read -r rest; do
    pane="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    window="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    from="${rest%%$'\t'*}"; session="${rest#*$'\t'}"
    if [ "$pane" != "$known" ] && [ "$ROOST_EVENTS_SERVER" = answered ]; then
      case "$ROOST_EVENTS_LIVE" in *" $pane "*) continue ;; esac
    fi
    roost_events__shape "$boot" "$pane" "$window" || continue
    case "$from" in blocked|working|done|error|idle) ;; *) from="" ;; esac
    roost_events_line "$(date +%s)" "$boot" "$pane" "$window" "$session" \
      closed "$from" "" "" "" || continue
    roost_events_write "$ROOST_EVENTS_LINE" nocreate
  done <<EOF
$cand
EOF
}

# roost_events__panes SOCKET BOOT -> ROOST_EVENTS_SERVER and ROOST_EVENTS_LIVE.
#
#   answered  the server at SOCKET is BOOT; ROOST_EVENTS_LIVE is its live pane
#             ids, space-separated with a space at each end (" %1 %4 ")
#   gone      no server is there any more: "no server running on", or the
#             socket or its directory is missing — every pane of BOOT is gone
#   other     a server answered with a boot key that is not BOOT. It can say
#             nothing about BOOT's panes, so nothing is written (review round
#             2: a mismatched socket and boot key closed a live server's panes)
#   unknown   anything else, or no answer inside the bound
#
# roost_record_liveness's shape, for its reasons — see its comment in
# roost-record.sh: a 2-second watchdog that escalates to SIGKILL, because a
# client of a stopped server spins rather than blocks; output to an unlinked
# file rather than a pipe, because a stopped server holds a pipe open; tmux's
# error text read in the C locale. One call for all the panes instead of one
# per pane.
roost_events__panes() {
  local sock="$1" boot="$2" got rc body line b
  ROOST_EVENTS_SERVER=unknown ROOST_EVENTS_LIVE=" "
  [ -n "$sock" ] || return 0
  command -v tmux >/dev/null 2>&1 || return 0
  got="$(
    f="$(mktemp "${TMPDIR:-/tmp}/roost-panes.XXXXXX" 2>/dev/null)" || exit 0
    exec 3>"$f" 4<"$f"
    rm -f "$f"
    env -u LC_ALL LC_MESSAGES=C tmux -S "$sock" list-panes -a \
      -F '#{start_time}-#{pid} #{pane_id}' </dev/null >&3 2>&3 3>&- 4<&- &
    probe=$!
    { sleep 2; kill "$probe"; sleep 1; kill -9 "$probe"; } \
      </dev/null >/dev/null 2>&1 3>&- 4<&- &
    dog=$!
    status=0
    wait "$probe" || status=$?
    kill "$dog" 2>/dev/null
    exec 3>&-
    cat <&4
    printf '\nrc=%s' "$status"
  )"
  case "$got" in *"
rc="*) ;; *) return 0 ;; esac
  rc="${got##*
rc=}"
  body="${got%
rc=*}"
  body="${body%
}"
  if [ "$rc" != 0 ]; then
    case "$body" in
      "no server running on "*) ROOST_EVENTS_SERVER=gone ;;
      "error connecting to "*"(No such file or directory)") ROOST_EVENTS_SERVER=gone ;;
    esac
    return 0
  fi
  [ -n "$body" ] || return 0
  while IFS= read -r line; do
    b="${line%% *}"
    case "$line" in
      [0-9]*-[0-9]*" %"[0-9]*) ;;
      *) ROOST_EVENTS_LIVE=" "; return 0 ;;
    esac
    if [ "$b" != "$boot" ]; then
      ROOST_EVENTS_SERVER=other ROOST_EVENTS_LIVE=" "
      return 0
    fi
    ROOST_EVENTS_LIVE="$ROOST_EVENTS_LIVE${line#* } "
  done <<EOF
$body
EOF
  ROOST_EVENTS_SERVER=answered
}

# --- the reader side ---------------------------------------------------------
#
# roost_events_read BOOT SINCE PANE FOLLOW -> the lines, each with its cursor.
# Returns:
#   0  printed what there was (perhaps nothing); with FOLLOW, the server stopped
#   3  SINCE is not in the log any more — rotated away, or the log was cleared.
#      One line on stderr. The caller re-reads `status --json` and starts again
#   4  SINCE is not a cursor at all
#
# Only BOOT's lines are printed: the log is shared by every server that writes
# to this state directory, and pane ids restart at %0 with each server.
#
# FOLLOW uses bin/roost's `t` to ask whether the server is still BOOT, the way
# roost-jsonout.sh uses it, so the socket rule stays in one place.
roost_events_read() {
  local boot="$1" since="$2" pane="$3" follow="$4" dir gen s off g rest
  local pending="" now_boot sz
  roost_events_dir
  dir="$ROOST_EVENTS_DIR"
  gen="" s=0 off=0
  if [ -n "$since" ]; then
    roost_events__cursor "$since" || return 4
    g="$ROOST_EVENTS_C_GEN" s="$ROOST_EVENTS_C_SEG" off="$ROOST_EVENTS_C_OFF"
    roost_events_gen "$dir" || true
    if [ "$g" != "$ROOST_EVENTS_GEN" ]; then
      echo "roost events: cursor $since is from a log that has since been cleared or rotated away — re-read \`roost status --json\` and start again without --since." >&2
      return 3
    fi
    roost_record_scan "$dir"
    roost_events_seg "$dir" "$s"
    if [ "$s" -lt "$ROOST_RECORD_MIN" ] || [ ! -f "$ROOST_EVENTS_FILE" ] \
       || ! roost_events__boundary "$ROOST_EVENTS_FILE" "$off"; then
      echo "roost events: cursor $since has been rotated away — re-read \`roost status --json\` and start again without --since." >&2
      return 3
    fi
  fi

  # The backlog: every segment from the cursor's (or the oldest) to the newest.
  roost_events_gen "$dir" || true
  gen="$ROOST_EVENTS_GEN"
  roost_record_scan "$dir"
  if [ "$ROOST_RECORD_COUNT" -gt 0 ]; then
    [ "$s" -ge "$ROOST_RECORD_MIN" ] || { s="$ROOST_RECORD_MIN"; off=0; }
    while :; do
      roost_events_seg "$dir" "$s"
      if [ -f "$ROOST_EVENTS_FILE" ]; then
        roost_events__drain "$ROOST_EVENTS_FILE" "$off" "$gen" "$s" "$boot" "$pane"
        off="$ROOST_EVENTS_OFF"
      fi
      [ "$s" -lt "$ROOST_RECORD_MAX" ] || break
      s=$((s + 1)); off=0
    done
  fi
  [ "$follow" = 1 ] || return 0

  # --follow. One poll every half second: a tmux read to ask whether the
  # server is still the one being followed, a `wc -c` of the newest segment,
  # and a read only when it grew. It exits when the server goes, after one last
  # read, so a line written as the server stopped is not lost.
  while :; do
    now_boot="$(t display-message -p '#{start_time}-#{pid}' 2>/dev/null || true)"
    if [ -z "$gen" ]; then
      # No log yet, or it was cleared under a follower that had not printed
      # anything: start at the first segment of whatever appears.
      roost_events_gen "$dir" && { gen="$ROOST_EVENTS_GEN"; s=1; off=0; }
    else
      roost_events_gen "$dir" || true
      if [ "$ROOST_EVENTS_GEN" != "$gen" ]; then
        echo "roost events: the log was cleared or rotated away under --follow — re-read \`roost status --json\` and start again." >&2
        return 3
      fi
    fi
    if [ -n "$gen" ]; then
      roost_record_scan "$dir"
      [ "$ROOST_RECORD_COUNT" -eq 0 ] || [ "$s" -ge "$ROOST_RECORD_MIN" ] || {
        echo "roost events: --follow fell behind and its place was rotated away — re-read \`roost status --json\` and start again." >&2
        return 3
      }
      roost_events_seg "$dir" "$s"
      if [ -f "$ROOST_EVENTS_FILE" ]; then
        sz="$(wc -c < "$ROOST_EVENTS_FILE" 2>/dev/null || echo 0)"
        sz="${sz//[!0-9]/}"
        if [ "${sz:-0}" -gt "$off" ]; then
          roost_events__drain "$ROOST_EVENTS_FILE" "$off" "$gen" "$s" "$boot" "$pane"
          off="$ROOST_EVENTS_OFF"
        fi
      fi
      # Move to the next segment only once it has existed for a whole poll,
      # and after reading this one again: a writer that listed the segments
      # just before the next was made still appends here, a moment later.
      if [ "$ROOST_RECORD_MAX" -gt "$s" ]; then
        if [ "$pending" = "$s" ]; then
          s=$((s + 1)); off=0; pending=""
          continue
        fi
        pending="$s"
      fi
    fi
    if [ "$now_boot" != "$boot" ]; then
      echo "roost events: the server stopped — no more events will come from it." >&2
      return 0
    fi
    sleep 0.5 2>/dev/null || sleep 1
  done
}

# roost_events__cursor CURSOR -> ROOST_EVENTS_C_GEN, _SEG, _OFF; 1 when it is
# not the shape `GEN:SEGMENT:OFFSET` this file prints.
roost_events__cursor() {
  local LC_ALL=C c="$1" g s o
  case "$c" in *:*:*) ;; *) return 1 ;; esac
  g="${c%%:*}"; c="${c#*:}"
  s="${c%%:*}"; o="${c#*:}"
  case "$g" in [0-9]*-[0-9]*) ;; *) return 1 ;; esac
  case "${g%%-*}${g#*-}" in ''|*[!0-9]*) return 1 ;; esac
  case "$s" in ''|*[!0-9]*) return 1 ;; esac
  case "$o" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#s}" -le 15 ] && [ "${#o}" -le 15 ] || return 1
  ROOST_EVENTS_C_GEN="$g" ROOST_EVENTS_C_SEG=$((10#$s)) ROOST_EVENTS_C_OFF=$((10#$o))
}

# roost_events__boundary FILE OFFSET -> 0 when OFFSET is 0, or the byte before
# it is a newline: a place a line starts. A cursor names only such places, so
# anything else was not printed by this reader. `dd` rather than `tail -c | head
# -c`: `head -c` is not POSIX.
roost_events__boundary() {
  local c
  [ "$2" -eq 0 ] && return 0
  c="$(dd if="$1" bs=1 skip=$(($2 - 1)) count=1 2>/dev/null; printf x)"
  [ "$c" = $'\nx' ]
}

# roost_events__drain FILE OFF GEN SEG BOOT PANE — print every COMPLETE line of
# FILE from byte OFF on that BOOT wrote (and PANE, when given), each with its
# cursor, and set ROOST_EVENTS_OFF to the byte after the last complete line.
#
# A last line with no newline is a write still in flight — or a torn one — and
# is neither printed nor passed: `read` returns non-zero on it and the loop
# ends, so the next drain starts at its first byte. Under LC_ALL=C so ${#line}
# counts bytes; nothing here runs tmux.
roost_events__drain() {
  local LC_ALL=C f="$1" off="$2" gen="$3" seg="$4" boot="$5" pane="$6" line
  while IFS= read -r line; do
    off=$((off + ${#line} + 1))
    case "$line" in
      "{"*"}") ;;
      *) continue ;;
    esac
    case "$line" in *"\"server\":\"$boot\""*) ;; *) continue ;; esac
    if [ -n "$pane" ]; then
      case "$line" in *"\"pane\":\"$pane\""*) ;; *) continue ;; esac
    fi
    printf '%s,"cursor":"%s:%s:%s"}\n' "${line%\}}" "$gen" "$seg" "$off"
  done < <(if [ "$off" -eq 0 ]; then cat "$f" 2>/dev/null; else tail -c +$((off + 1)) "$f" 2>/dev/null; fi)
  ROOST_EVENTS_OFF="$off"
}

# roost_events_clear -> removes the log (for `forget --all`); prints nothing.
# ROOST_EVENTS_CLEARED is 1 when there was one. Only a directory holding a
# valid gen file is a log, and only the files this lib writes are removed from
# it — gen, digit-named segments and its own .tmp.* files — then the directory
# if that left it empty, so a ROOST_EVENTS pointed at a directory that holds
# anything else keeps it.
roost_events_clear() {
  local LC_ALL=C dir f b
  ROOST_EVENTS_CLEARED=0
  roost_events_dir
  dir="$ROOST_EVENTS_DIR"
  [ -n "$dir" ] && [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  # A directory with no valid gen file is not a log roost wrote — the gen file
  # is the first thing a writer makes — so nothing in it is touched, however
  # much of it looks like segments. `.tmp.XXXXXX` is also what mktemp names
  # other programs' files, and a ROOST_EVENTS pointed at a shared directory
  # once lost them here (review round 1, reproduced).
  roost_events_gen "$dir" || return 0
  # gen first: a follower that sees it gone knows the log was cleared rather
  # than finding a segment missing and guessing.
  if [ -f "$dir/gen" ]; then rm -f "$dir/gen"; ROOST_EVENTS_CLEARED=1; fi
  for f in "$dir"/[0-9]* "$dir"/.tmp.*; do
    [ -f "$f" ] || continue
    b="${f##*/}"
    case "$b" in
      .tmp.*) ;;
      *[!0-9]*) continue ;;
    esac
    rm -f "$f"
    ROOST_EVENTS_CLEARED=1
  done
  rmdir "$dir" 2>/dev/null || true
}
