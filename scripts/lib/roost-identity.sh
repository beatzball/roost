# roost-identity.sh — who the agent in a pane is (#141): the harness's own
# session id, the directory it runs in, which harness it is, and the path of
# its transcript. roost keys everything on the pane; a program that wants to
# show a conversation, link a pane to its transcript or bring a conversation
# back needs these four as well.
#
# Sourced, not executed, `roost_identity_*` prefix. Three callers, one writer:
#
#   bin/roost `identify`              the public command, for opencode, copilot,
#                                     pi and anything else
#   scripts/roost-session-context     Claude Code's SessionStart hook
#   adapters/codex/roost-codex-hook   codex's UserPromptSubmit
#
# WHAT IT WRITES, in one tmux command:
#
#   @roost-session          the harness's session id
#   @roost-cwd              the agent's working directory, absolute
#   @roost-harness          claude | codex | opencode | copilot | pi | <other>
#   @roost-transcript-path  the transcript, absolute; unset when unknown
#
# and, when pane records are on, `session_id`, `cwd` and `harness` in the pane's
# record directory — the names scripts/lib/roost-record.sh reserves — so a pane
# that has closed can still be identified.
#
# WHY NOT @roost-transcript. That option already exists and means something
# else: "<@agent_since> <path>", written by scripts/roost-agent-state when a
# Claude dialog opens, removed when a dialog hook cannot produce one, and
# removed again by scripts/lib/roost-unblock.sh after a declined dialog. Its
# first word is the stamp roost-unblock.sh checks before it trusts the path.
# Writing a bare path into it would break that check, and every one of those
# removals would take the identity's transcript with it — a pane that declined
# one dialog would read `"transcript": null` for the rest of its session.
#
# THE RULES, and each is here for a reason:
#
#   ONE READ, THEN BAIL. The four options are read back in one tmux call and
#   compared with what would be written; equal means nothing is written at all.
#   A SessionStart or a prompt in a session that is already recorded costs one
#   tmux round trip.
#
#   ONE WRITE. All four options go in one tmux command, so no reader ever sees
#   a new session id beside the old session's transcript.
#
#   WHAT THE HARNESS SAYS NOW. A changed session id replaces the old one. Claude
#   and codex both give a /clear'd conversation a new id in the same process,
#   and a resumed one its old id in a new process — measured on Claude Code
#   2.1.283 and codex-cli 0.157.1, and written up where each is read:
#   scripts/roost-session-context and adapters/codex/roost-codex-hook. Nothing
#   here links the two.
#
#   NO STATE. Identity is not a badge; @agent_state is never touched (#76 is the
#   change that stamps a state at session start).
#
#   VALIDATE BEFORE IT BECOMES AN OPTION OR A PATH. Every value becomes a tmux
#   option value, `roost status` renders pane options into tab-delimited rows,
#   and the session id is a file's contents today and a file NAME the day a
#   per-turn sidecar (`replies/NNNNNN.session_id`) is written. So:
#
#     session id   1-128 bytes of letters, digits and `. _ : -`, not starting
#                  with `-`. Every harness roost has an adapter for uses a UUID
#                  or an `ses_...`-style id, which this admits.
#     cwd          absolute, 1-1024 bytes, no control character, not ending in
#                  `;` — tmux's command parser eats a trailing `;` from an
#                  option value (lib/roost-reply.sh has the measurement), so
#                  such a path would be stored one character short.
#     harness      1-32 bytes of lower-case letters, digits, `_` and `-`, not
#                  starting with `-`.
#     transcript   empty (unknown), or the same rules as cwd.
#
#   1024 is macOS's PATH_MAX. A deeper path is refused rather than cut: a cut
#   path names a different directory.
#
# Everything here is bash 3.2 and runs under a caller's `set -euo pipefail`:
# every command that may fail carries its own `|| ...`.

ROOST_IDENTITY_LIB_DIR="${BASH_SOURCE[0]%/*}"

# roost_identity__line VALUE MAX -> 0 when VALUE is 1..MAX bytes with no control
# character. Byte length and the character class both need the C locale: in a
# UTF-8 locale ${#v} counts characters, and [[:cntrl:]] can grow to include C1.
roost_identity__line() {
  local LC_ALL=C
  [ -n "$1" ] || return 1
  [ "${#1}" -le "$2" ] || return 1
  case "$1" in *[[:cntrl:]]*) return 1 ;; esac
  return 0
}

# roost_identity__path VALUE -> 0 when VALUE is an absolute path the rules above
# accept.
roost_identity__path() {
  roost_identity__line "$1" 1024 || return 1
  case "$1" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$1" in *';') return 1 ;; esac
  return 0
}

# roost_identity_valid SESSION CWD HARNESS TRANSCRIPT -> 0, or 1 with
# ROOST_IDENTITY_BAD naming the first field that failed: session, cwd, harness
# or transcript. The letter sets are spelled out rather than written as ranges:
# bash 3.2 matches a range by the locale's collation, where a-z can include
# capitals (the StopFailure reader in scripts/roost-agent-state says the same).
roost_identity_valid() {
  ROOST_IDENTITY_BAD=""
  if ! roost_identity__line "$1" 128; then ROOST_IDENTITY_BAD=session; return 1; fi
  case "$1" in
    -*|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-]*)
      ROOST_IDENTITY_BAD=session; return 1 ;;
  esac
  if ! roost_identity__path "$2"; then ROOST_IDENTITY_BAD=cwd; return 1; fi
  if ! roost_identity__line "$3" 32; then ROOST_IDENTITY_BAD=harness; return 1; fi
  case "$3" in
    -*|*[!abcdefghijklmnopqrstuvwxyz0123456789_-]*)
      ROOST_IDENTITY_BAD=harness; return 1 ;;
  esac
  if [ -n "$4" ] && ! roost_identity__path "$4"; then ROOST_IDENTITY_BAD=transcript; return 1; fi
  return 0
}

# roost_identity__record BOOT PANE SOCK SESSION CWD HARNESS — write the three
# reserved names into the pane's record. Fails soft: a record that cannot be
# written leaves the pane options to do their job, as every record write does.
#
# The directory is created the way roost_record_append creates it — 0700 on the
# root when this makes it, on the boot directory and on the pane directory; the
# schema and socket files backfilled; a record with a schema this roost does not
# understand never written into. It is a copy of those lines rather than a call
# because roost_record_append also writes a turn, and a pane is identified
# before its first turn. Keep the two in step.
#
# THAT INCLUDES THE SWEEP. roost_record_append runs roost_record_sweep — the
# ROOST_RECORD_DAYS rule — only when IT made the pane directory, once per pane.
# Identity now makes that directory first, at session start, so without the
# sweep here no identified pane would ever run it and the rule would do nothing
# on a machine whose harnesses are all identified (found in review, reproduced
# by tests/test-identity.sh with a planted record).
roost_identity__record() {
  local boot="$1" pane="$2" sock="$3" dir st=0 created=0
  # The same file roost-agent-state sources; its functions are used below.
  . "$ROOST_IDENTITY_LIB_DIR/roost-record.sh"
  roost_record_root
  [ -n "$ROOST_RECORD_ROOT" ] || return 0
  roost_record_pane_dir "$boot" "$pane" || return 1
  dir="$ROOST_RECORD_PANE_DIR"
  if [ ! -d "$dir" ]; then
    if [ ! -d "$ROOST_RECORD_ROOT" ]; then
      mkdir -p "$ROOST_RECORD_ROOT" 2>/dev/null || return 1
      chmod 700 "$ROOST_RECORD_ROOT" 2>/dev/null || true
    fi
    mkdir -p "${dir%/*}" 2>/dev/null || return 1
    chmod 700 "${dir%/*}" 2>/dev/null || true
    if mkdir -m 700 "$dir" 2>/dev/null; then
      created=1
    else
      [ -d "$dir" ] || return 1
    fi
  fi
  if [ ! -f "$dir/schema" ]; then
    roost_record__put "$dir/schema" "$ROOST_RECORD_SCHEMA
" || return 1
  fi
  roost_record_schema "$dir" || st=$?
  [ "$st" -eq 0 ] || return 1
  if [ ! -f "$dir/socket" ] && [ -n "$sock" ]; then
    roost_record__put "$dir/socket" "$sock
" || return 1
  fi
  roost_record__put "$dir/session_id" "$4
" || return 1
  roost_record__put "$dir/cwd" "$5
" || return 1
  roost_record__put "$dir/harness" "$6
" || return 1
  if [ "$created" = 1 ]; then
    roost_record_sweep
  fi
  return 0
}

# roost_identity_stamp SOCK PANE SESSION CWD HARNESS TRANSCRIPT
#   0  written, or already exactly this (ROOST_IDENTITY_WROTE says which)
#   1  tmux could not be asked or could not write: a dead server, a pane gone
#   2  a value was refused; ROOST_IDENTITY_BAD names it, and nothing was written
roost_identity_stamp() {
  local sock="$1" pane="$2" sid="$3" cwd="$4" harness="$5" tr="$6"
  local tab=$'\t' want got boot
  local -a wr
  ROOST_IDENTITY_WROTE=0
  roost_identity_valid "$sid" "$cwd" "$harness" "$tr" || return 2
  # ONE read: the four options and the server's boot key, which the record
  # needs and which costs nothing extra here. Tab-separated: a validated value
  # holds no control character, so a tab can only be a separator — and a value
  # someone wrote with plain `tmux set-option` that does hold one simply fails
  # to compare, which costs one rewrite, never a skipped one.
  #
  # `-u`: a tmux client that is not UTF-8 PRINTS tab and every non-ASCII byte as
  # `_` (measured on tmux 3.3a and 3.4; lib/roost-jsonout.sh's header), which
  # would make a path with an accented letter compare unequal on every call.
  #
  # The format lookup falls back to window and global scope, which is exactly
  # what `roost status --json` reads: the comparison is against what a reader
  # would be shown.
  got="$(tmux -u -S "$sock" display-message -p -t "$pane" \
    "#{@roost-session}$tab#{@roost-cwd}$tab#{@roost-harness}$tab#{@roost-transcript-path}$tab#{start_time}-#{pid}" \
    2>/dev/null)" || return 1
  boot="${got##*$tab}"
  got="${got%$tab*}"
  want="$sid$tab$cwd$tab$harness$tab$tr"
  [ "$got" = "$want" ] && return 0
  # The record first, for the reason the reply is recorded before its pane
  # option: a reader that sees the new option should find the record that goes
  # with it.
  roost_identity__record "$boot" "$pane" "$sock" "$sid" "$cwd" "$harness" || true
  # `;` as its own argument is tmux's command separator in argv form — the
  # shape roost_stamp_blocked in scripts/roost-agent-state uses.
  wr=(set-option -p -t "$pane" @roost-session "$sid"
      ';' set-option -p -t "$pane" @roost-cwd "$cwd"
      ';' set-option -p -t "$pane" @roost-harness "$harness")
  if [ -n "$tr" ]; then
    wr+=(';' set-option -p -t "$pane" @roost-transcript-path "$tr")
  else
    # Unknown now means unknown: a transcript left from the previous session
    # would name a conversation this pane is no longer having.
    wr+=(';' set-option -pu -t "$pane" @roost-transcript-path)
  fi
  tmux -S "$sock" "${wr[@]}" 2>/dev/null || return 1
  ROOST_IDENTITY_WROTE=1
  return 0
}

# roost_identity_from_payload SOCK PANE HARNESS PAYLOAD — a Claude Code or codex
# hook payload in, roost_identity_stamp out. Both harnesses name the fields the
# same way: session_id, cwd, transcript_path.
#
# Never fails the caller: it returns 0 whatever happened, because both callers
# are hooks whose non-zero exit a harness reads as a veto (codex) or reports as
# a hook error (Claude).
#
# A payload that names an `agent_id` belongs to a SUBAGENT, and changes nothing:
# the pane's identity is its main conversation's. Claude adds that field only
# for a subagent's loop (the StopFailure branch of scripts/roost-agent-state
# relies on the same rule).
#
# The transcript is the one field that may be dropped on its own. A session id
# or cwd that fails the rules means the payload is not one this understands, so
# nothing is written; a transcript that fails them is only a transcript roost
# cannot point at, so the other three still land and the path reads unknown.
#
# One reader process, three fields. python3 first, then jq, then nothing: a
# machine with neither records no identity, and every other part of the hook
# works as before — the rule scripts/roost-doctor records for python3.
roost_identity_from_payload() {
  local sock="$1" pane="$2" harness="$3" payload="$4" fields="" sid cwd tr rc=0
  if command -v python3 >/dev/null 2>&1; then
    fields="$(printf '%s' "$payload" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = None
if not isinstance(d, dict):
    sys.exit(0)
a = d.get("agent_id")
if isinstance(a, str) and a:
    sys.exit(0)
out = []
for k in ("session_id", "cwd", "transcript_path"):
    v = d.get(k)
    ok = isinstance(v, str) and all(31 < ord(c) != 127 for c in v)
    out.append(v if ok else "")
sys.stdout.write("\n".join(out) + "\nx")' 2>/dev/null || true)"
  elif command -v jq >/dev/null 2>&1; then
    fields="$(printf '%s' "$payload" | jq -j 'if type == "object"
        and ((.agent_id | type) != "string" or .agent_id == "") then
          ([.session_id, .cwd, .transcript_path]
           | map(if type == "string" and (test("[[:cntrl:]]") | not) then . else "" end)
           | join("\n")) + "\nx"
        else "" end' 2>/dev/null || true)"
  fi
  # The trailing `x` keeps $( ) from eating the newline after an empty last
  # field; without it an absent transcript would shift nothing but a present
  # one followed by nothing could not be told from a missing line.
  case "$fields" in *$'\n'*$'\n'*$'\n'x) ;; *) return 0 ;; esac
  sid="${fields%%$'\n'*}"; fields="${fields#*$'\n'}"
  cwd="${fields%%$'\n'*}"; fields="${fields#*$'\n'}"
  tr="${fields%%$'\n'*}"
  roost_identity_stamp "$sock" "$pane" "$sid" "$cwd" "$harness" "$tr" || rc=$?
  if [ "$rc" -eq 2 ] && [ "$ROOST_IDENTITY_BAD" = transcript ]; then
    roost_identity_stamp "$sock" "$pane" "$sid" "$cwd" "$harness" "" || true
  fi
  return 0
}
