# roost-pending.sh — the resume record between placement and launch (#191
# Part 3): the `pending/<boot>/` files, the renames that move them between
# the states of the placeholder table, the `origin` rule, and (Task 3.5) the
# resume engine.
#
# The design is docs/airig/specs/2026-10-24-persistent-sessions-design.md
# §4.6 (the pending record: what is in it and who writes it) and §4.7 (who
# owns a pane: every state, and the arrows T1–T19 between them). The arrows
# each function serves are named in its comment, so a reader can go from a
# line here to the row of the table it implements.
#
# THE FILE'S NAME IS THE PROOF. A pane a launcher may replace is in exactly
# one state, and the state is read from the name of its file under
# `pending/<boot>/` — `%N` (waiting), `%N.launching`, `%N.failed`,
# `%N.taken` — and, for `.failed`, from its first line. Every change of
# state is ONE rename(2), which is atomic, so when a launcher's `mv` and a
# placeholder's `mv … .taken` race on one file exactly one wins (§4.7, "the
# proof").
#
# THE FILE'S LINES. `pending_write` writes `was` first, always, then the
# other keys one per line. A `.failed` file has a REASON line before `was`
# (§4.6 step 2: "the reason written in"); a reason never starts with `was `,
# so the first line alone says whether there is one. A later failed check on
# a `died` file is a `note REASON` line after the keys (T7 from a dead pane,
# revision 5, C B2(a)). The one line a launcher adds is `origin STATE`
# (T5), and it never outlives the claim that wrote it (revision 10, C B1;
# roost_pending_leave_launching).
#
# Every function is bash 3.2 safe and `set -u` clean: bin/roost runs on macOS
# /bin/bash. The placeholder side of these renames is scripts/roost-placeholder
# (POSIX sh), which cannot source this file and makes its own two renames.

# roost_pending_dir SHAPE-DIR BOOT -> prints pending/<boot>/ under the shape
# directory (§3.1's tree). Creates nothing.
roost_pending_dir() { printf '%s/pending/%s\n' "$1" "$2"; }

# roost_pending_write SHAPE-DIR BOOT %N WAS HARNESS SESSION-ID TRANSCRIPT CWD
#                     SESSION-CWD SESSION WINDOW ORDER
#   -> prints the file's path; exit 0 written, 1 refused (nothing written).
#
# T3's first half: placement writes this BEFORE it starts the pane's waiting
# placeholder (§4.6), so a placeholder never runs without its file. Named by
# the NEW %N; `was` is the saved pane's id. `order` is the pane's place in the
# shape's pane order, which the resume loop walks (§4.6). An empty TRANSCRIPT
# or SESSION-CWD is no line, as in the shape.
#
# Written to a temp file in the same directory and renamed into place, so the
# name `%N` never exists half-written: a placeholder or a launcher that sees
# the name sees the whole block. 0600 under a 0700 directory, the shape
# directory's rule (§3.1): a session id is enough to resume a conversation.
#
# A value holding a newline is refused, not cleaned: one key per line is the
# whole format, and the shape's reader has already refused such a value, so
# reaching here with one is a fault, never data.
roost_pending_write() {
  local sd="$1" boot="$2" pane="$3" d f tmp v
  case "$pane" in %[0-9]*) ;; *) echo "roost: pending: '$pane' is not a pane id" >&2; return 1 ;; esac
  case "${pane#%}" in *[!0-9]*) echo "roost: pending: '$pane' is not a pane id" >&2; return 1 ;; esac
  for v in "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}"; do
    case "$v" in *$'\n'*|*$'\r'*) echo "roost: pending: a value for $pane holds a line break; not written" >&2; return 1 ;; esac
  done
  d="$(roost_pending_dir "$sd" "$boot")"
  # 0700 from the start (umask in a subshell), not chmod after: a directory
  # made 0755 and then narrowed is readable in between.
  ( umask 077 && mkdir -p "$d" ) || return 1
  f="$d/$pane"
  tmp="$(umask 077 && mktemp "$d/.$pane.XXXXXX")" || return 1
  {
    printf 'was %s\n' "$4"
    printf 'harness %s\n' "$5"
    printf 'session_id %s\n' "$6"
    [ -n "$7" ] && printf 'transcript %s\n' "$7"
    printf 'cwd %s\n' "$8"
    [ -n "$9" ] && printf 'session_cwd %s\n' "$9"
    printf 'session %s\n' "${10}"
    printf 'window %s\n' "${11}"
    printf 'order %s\n' "${12}"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  if ! mv -f "$tmp" "$f" 2>/dev/null; then rm -f "$tmp"; return 1; fi
  printf '%s\n' "$f"
}

# roost_pending_take FROM TO ORIGIN -> exit 0 when this rename won, else 1.
#
# T5, T14, T16, T17 and T8c: every claim of a file into `%N.launching`. The
# rename is the claim — a placeholder's key races it on the same FROM, and
# exactly one wins. Only the winner appends `origin ORIGIN` (`waiting`,
# `failed REASON` — the old first line — or `taken`), AFTER its rename, so no
# placeholder can race the append: the file is already this launcher's. That
# line is the one record of whose pane it was that outlives the launcher, and
# T8b reads it if this run dies (§4.7 T5, revision 5, C B1).
#
# A lost rename touches nothing: the pane is the person's or another
# launcher's, and the caller moves on (§4.6 step 1).
#
# THE LAUNCHER'S RECORD, written BEFORE the rename (review round 1, Opus N1).
# A `.launching` file says the pane is claimed, but not by whom until the
# conversation's claim names the pane — and `revive` renames first and claims
# after (the pane first, then the conversation: §4.1 step 5a, revision 4).
# In that window the worker's T8b saw no claim, judged the launcher gone, and
# put the file back while the revive went on to launch: the pane ran the
# agent with a `.failed` file, and `send` refused it. So each launcher first
# writes `.<%N>.by.<pid>` beside the file, holding its owner record (pid and
# start time, §3.5's rule, never age), and T8b leaves a pane alone while any
# such record is alive (roost_pending__launcher_live). It is never removed by
# its writer: it is alive exactly as long as the launcher is, and T8b clears
# the dead ones it meets. Dot-named, so no `%*` listing sees it.
roost_pending_take() {
  [ -e "$1" ] || return 1
  roost_pending__mark "$2"
  # `mv` without -f or -i, and nothing between the check above and it but
  # the rename itself: whoever renames FROM first wins, and the loser's mv
  # finds no FROM.
  mv "$1" "$2" 2>/dev/null || return 1
  # A test seam between the rename and the append, named by the caller in
  # ROOST_PENDING_SEAM (revive passes ROOST_TEST_REVIVE_HOLD_BEFORE_ORIGIN):
  # a launcher killed here leaves a `.launching` file with no origin line,
  # which T8b must read as interrupted.
  [ -n "${ROOST_PENDING_SEAM:-}" ] && roost_shape__seam "$ROOST_PENDING_SEAM"
  [ -n "${3:-}" ] && printf 'origin %s\n' "$3" >> "$2"
  return 0
}

# roost_pending__mark %N-FILE — write this process's launcher record for the
# pane the pending file names (roost_pending_take says why). Best effort: a
# record that cannot be written leaves the old behaviour, a window T8b may
# misjudge, never a failed launch.
roost_pending__mark() {
  local pane="${1##*/}" d="${1%/*}" me
  pane="${pane%%.*}"
  me="$$ $(roost_shape__lstart "$$" 2>/dev/null || true)"
  ( umask 077 && printf '%s\n' "$me" > "$d/.$pane.by.$$" ) 2>/dev/null || true
}

# roost_pending__launcher_live DIR %N -> exit 0 when a launcher record for %N
# names a live process other than this one; removes the dead ones it reads.
roost_pending__launcher_live() {
  local f rec live=1
  for f in "$1"/."$2".by.*; do
    [ -f "$f" ] || continue
    [ "${f##*.by.}" = "$$" ] && continue
    IFS= read -r rec < "$f" 2>/dev/null || rec=""
    if [ -n "$rec" ] && roost_shape__alive "$rec"; then live=0; else rm -f "$f"; fi
  done
  return "$live"
}

# roost_pending_leave_launching FILE NEWNAME [REASON [NOTE]] -> exit 0 when
# FILE was moved to NEWNAME, else 1.
#
# Every arrow OUT of `%N.launching` that is a rename (T7, T8, T8b, T9, T12,
# T13, T13a, T13b) goes through here, so the `origin` rule holds in one place
# (revision 10, C B1): AN ORIGIN LINE BELONGS TO ONE CLAIM ONLY. First the
# file is rewritten without any `origin` line — to a temp file beside it,
# renamed over FILE while this caller still holds the claim — and only then
# renamed to NEWNAME. So a `%N`, `%N.failed` or `%N.taken` this produces never
# carries an `origin` line, and a newly claimable file never has one. Without
# the rule an older attempt's `origin waiting` survived a later claim, and T8b
# read it as waiting and handed a person's shell to the worker (§4.7 T5's
# example).
#
# REASON, when given, becomes the first line (a `.failed` file's reason,
# §4.6 step 2); any old reason line is dropped. With no REASON the file
# starts with its `was` line again — a `%N` or `%N.taken` has no reason.
# NOTE, when given, is added after the keys as `note NOTE`: T7 from a dead
# pane keeps `died` first and adds the failed check as extra text, so the
# file stays failed, dead and is never relabelled failed, waiting
# (revision 5, C B2(a)). Old note lines are kept.
#
# Called only by the holder of FILE (the launcher whose rename made it, or
# the worker holding `resuming/` for T8b): no other process renames a
# `.launching` file it did not make (§4.6, interrupted halfway).
roost_pending_leave_launching() {
  local f="$1" to="$2" reason="${3:-}" note="${4:-}" tmp line seen=0
  [ -f "$f" ] || return 1
  tmp="$(umask 077 && mktemp "${f%/*}/.leave.XXXXXX")" || return 1
  {
    [ -n "$reason" ] && printf '%s\n' "$reason"
    while IFS= read -r line || [ -n "$line" ]; do
      # Lines before `was` are an old reason: dropped, REASON replaces it.
      if [ "$seen" = 0 ]; then
        case "$line" in "was "*) seen=1 ;; *) continue ;; esac
      fi
      case "$line" in "origin "*|origin) continue ;; esac
      printf '%s\n' "$line"
    done < "$f"
    # An `if`, not `&&`: a false test as the group's last command would be
    # its exit status, and the write would read as failed.
    if [ -n "$note" ]; then printf 'note %s\n' "$note"; fi
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  if ! mv -f "$tmp" "$f" 2>/dev/null; then rm -f "$tmp"; return 1; fi
  mv "$f" "$to" 2>/dev/null
}

# roost_pending_state FILE -> prints §4.7's row for a pending file, from its
# NAME and (for `.failed`) its first line; exit 1 when the name is no state
# or the file is not there.
#
#   %N             waiting
#   %N.launching   launching (the file alone cannot tell launching from
#                  launched: that is the pane's start command, read by the
#                  caller — roost_pane_owner_state)
#   %N.taken       taken (a T15 file keeps its old reason line: still taken)
#   %N.failed      by the first line (§4.7 T14, revision 5, F N6):
#                    died                         failed-dead
#                    exited                       failed-exited
#                    interrupted                  failed-interrupted
#                    pane changed                 failed-changed
#                    replaced                     failed-replaced
#                    harness missing, directory gone, store miss,
#                    duplicate of %M              failed-waiting
#
# A `.failed` file whose first line is none of these — no reason line, or
# text a person wrote — proves nothing about its pane, so it is
# failed-interrupted: never retried automatically, reachable only by a
# person's `revive` with its shell checks. That is T8b's own answer for a
# claim that left no record (§4.7), and the safe side: failed-waiting would
# let `--retry` replace the pane.
roost_pending_state() {
  local f="$1" b first=""
  [ -f "$f" ] || return 1
  b="${f##*/}"
  case "$b" in
    %*.launching) printf 'launching\n' ;;
    %*.taken) printf 'taken\n' ;;
    %*.failed)
      IFS= read -r first < "$f" || true
      case "$first" in
        died) printf 'failed-dead\n' ;;
        exited) printf 'failed-exited\n' ;;
        interrupted) printf 'failed-interrupted\n' ;;
        "pane changed") printf 'failed-changed\n' ;;
        replaced) printf 'failed-replaced\n' ;;
        # `duplicate of` names the holder: `%M`, or `pid N` / `another
        # launcher` when the holder had named no pane yet.
        "harness missing"|"directory gone"|"store miss"|"duplicate of "?*) printf 'failed-waiting\n' ;;
        *) printf 'failed-interrupted\n' ;;
      esac ;;
    %*)
      case "${b#%}" in ''|*[!0-9]*) return 1 ;; esac
      printf 'waiting\n' ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# The pane side (Task 3.4): who owns a pane now, what `send` and `answer` may
# do to it, and `close`'s cancel. These read the server through bin/roost's
# own `t` (and its _SOCKET_FLAG / SOCKET), so they ask the server every other
# verb asks.

# roost_send_policy STATE FORCE -> prints refuse | allow: §4.7's `roost send`
# column, one function for `send` and `answer` alike. A pane a launcher may
# still replace with its placeholder or its resume — every row that says
# "refused" — refuses, because a coordinator's prompt typed there is a KEY:
# into a placeholder it takes the pane (T4, T6, T15) and the agent is not
# resumed; into a resume's dialog it answers what a person was asked. FORCE 1
# bypasses this refusal, and only this one (§7): each verb then keeps every
# check it has today. The rows that say "as for any pane" — a person's shell
# (placing, taken; taken), a person's command (failed, changed), another
# conversation (failed, replaced), no pane (failed, exited), no file — allow.
roost_send_policy() {
  case "$1" in
    placing|placing-claimed|waiting|launching|launched|failed-waiting|failed-dead|failed-interrupted)
      if [ "${2:-0}" = 1 ]; then printf 'allow\n'; else printf 'refuse\n'; fi ;;
    *) printf 'allow\n' ;;
  esac
}

# roost_pending__words STATE -> prints the state as the refusal says it.
roost_pending__words() {
  case "$1" in
    placing) printf 'placing (roost restore is placing it)' ;;
    placing-claimed) printf 'placing (roost restore has claimed it and is about to replace it)' ;;
    waiting) printf 'waiting (a placeholder waiting for its agent to be resumed)' ;;
    launching) printf 'launching (its agent is being resumed now)' ;;
    launched) printf 'launched (its agent was just resumed, and may be in a dialog)' ;;
    failed-waiting) printf 'failed-waiting (its resume failed; the placeholder shows why)' ;;
    failed-dead) printf 'failed-dead (its resume died; roost restore --resume --retry tries again)' ;;
    failed-interrupted) printf 'failed-interrupted (a resume of it was interrupted)' ;;
    *) printf '%s' "$1" ;;
  esac
}

# roost_pane_owner_state %N -> prints §4.7's row for the pane, one of
#   placing placing-claimed placing-taken waiting launching launched
#   failed-waiting failed-dead failed-interrupted failed-changed
#   failed-replaced failed-exited taken none
# and sets ROOST_PENDING_FILE to the file's current path (empty for none).
# Exit 1 when the pane cannot be read (then it prints `none`).
#
# It reads #{pane_start_command} and #{pane_dead} ONCE (§4.7: the file's name
# is the proof, the start command only tells a placeholder from what else
# runs):
#   1. a PLACING line (`roost-placeholder F --placing`) names its restoring/
#      file F, and F's current name gives the placing rows — F placing, F.used
#      placing-claimed, F.taken placing-taken. A placing line whose F is gone
#      in EVERY name is the `no file` row: restore has finished and removed
#      restoring/, and the start command survived the `exec` that gave a
#      person the shell (§2.10).
#   2. else the pane's pending file: the one a pending placeholder line
#      (`roost-placeholder P HARNESS`) names, when P is this pane's own
#      `%N` — so a hand restore with saving off, whose pending/ is in its
#      own directory, is found too — or else pending/<boot>/%N in this
#      server's shape directory, which is how a LAUNCHED pane (running its
#      resume command, not the placeholder) is found. Its current name and
#      first line give the rest (roost_pending_state); `.launching` is
#      launching while the pane still runs this file's placeholder line, and
#      launched once it runs anything else.
roost_pane_owner_state() {
  roost_pane__owner "$1"; local r=$?
  printf '%s\n' "$ROOST_PENDING_STATE"
  return "$r"
}

# roost_pane__owner %N -> sets ROOST_PENDING_STATE and ROOST_PENDING_FILE,
# prints nothing: the body of roost_pane_owner_state, for a caller that needs
# both variables (a $(...) would lose them in its subshell).
roost_pane__owner() {
  local pane="$1" info dead boot sc path base f root key
  ROOST_PENDING_FILE="" ROOST_PENDING_STATE=none
  info="$(t -u display-message -p -t "$pane" '#{pane_id} #{pane_dead} #{start_time}-#{pid} #{pane_start_command}' 2>/dev/null || true)"
  case "$info" in "$pane "*) ;; *) return 1 ;; esac
  info="${info#"$pane "}"
  dead="${info%% *}"; info="${info#* }"
  boot="${info%% *}"; sc="${info#* }"
  # tmux prints an argv command with double quotes round an argument that
  # holds a space (roost_restore__placing measured it): dropped before the
  # compare, with backslashes.
  sc="${sc//\"/}"; sc="${sc//\\/}"
  case "$sc" in
    *roost-placeholder\ *\ --placing)
      path="${sc#*roost-placeholder }"; path="${path% --placing}"
      if [ -e "$path" ]; then ROOST_PENDING_FILE="$path" ROOST_PENDING_STATE=placing
      elif [ -e "$path.used" ]; then ROOST_PENDING_FILE="$path.used" ROOST_PENDING_STATE=placing-claimed
      elif [ -e "$path.taken" ]; then ROOST_PENDING_FILE="$path.taken" ROOST_PENDING_STATE=placing-taken
      fi
      return 0 ;;
  esac
  f=""
  case "$sc" in
    *roost-placeholder\ *)
      path="${sc#*roost-placeholder }"; path="${path% *}"
      base="${path##*/}"
      [ "$base" = "$pane" ] && f="$path" ;;
  esac
  if [ -z "$f" ] && root="$(roost_shape_saving 2>/dev/null)"; then
    key="$(roost_shape_key "$_SOCKET_FLAG" "$SOCKET")"
    f="$root/$key/pending/$boot/$pane"
  fi
  [ -n "$f" ] || return 0
  if [ -e "$f" ]; then
    ROOST_PENDING_FILE="$f" ROOST_PENDING_STATE=waiting
  elif [ -e "$f.launching" ]; then
    ROOST_PENDING_FILE="$f.launching" ROOST_PENDING_STATE=launched
    case "$sc" in *roost-placeholder\ "$f"\ *) ROOST_PENDING_STATE=launching ;; esac
  elif [ -e "$f.failed" ]; then
    ROOST_PENDING_FILE="$f.failed"
    ROOST_PENDING_STATE="$(roost_pending_state "$f.failed" || printf 'failed-interrupted')"
  elif [ -e "$f.taken" ]; then
    ROOST_PENDING_FILE="$f.taken" ROOST_PENDING_STATE=taken
  fi
  return 0
}

# roost_pending_refuse VERB TARGET %N FORCE -> exit 0 when VERB may go on;
# else prints the ownership refusal on stderr and exits 1, and the caller
# exits 3 — the blocked-target refusal's code, §4.7 ("the way it refuses a
# blocked target"): the target is right, and retrying later, or --force, is
# the answer.
roost_pending_refuse() {
  local st
  roost_pane__owner "$3" 2>/dev/null || true
  st="$ROOST_PENDING_STATE"
  [ "$(roost_send_policy "${st:-none}" "$4")" = refuse ] || return 0
  printf "roost %s: target '%s' is %s — roost may still replace this pane, and text typed into it would %s\n" \
    "$1" "$2" "$(roost_pending__words "$st")" \
    "$( [ "$st" = launched ] && printf 'answer its dialog' || printf 'be taken as a key that keeps the agent from being resumed' )" >&2
  printf 'roost %s: wait for it, or pass --force to send anyway\n' "$1" >&2
  return 1
}

# roost_pending__release FILE %N FLAG SOCKET — release the launch claim a
# pending FILE's key holds for THIS pane (§4.1 step 5a's
# claims/<boot>/<harness>-<id>). Dropped only when the claim's pane file
# names this pane: a claim another launcher took for another pane is never
# touched. The boot is the file's own directory name, pending/<boot>/.
roost_pending__release() {
  local f="$1" pane="$2" h="" id="" line c boot
  [ -n "$f" ] && [ -f "$f" ] || return 0
  roost_pending__get "$f" harness; h="$ROOST_PENDING_V"
  roost_pending__get "$f" session_id; id="$ROOST_PENDING_V"
  [ -n "$h" ] && [ -n "$id" ] || return 0
  boot="${f%/*}"; boot="${boot##*/}"
  roost_resume_claims_dir "$3" "$4" "$boot" >/dev/null 2>&1 || return 0
  c="$ROOST_RESUME_CLAIMS/$h-$id"
  [ -f "$c/pane" ] || return 0
  IFS= read -r line < "$c/pane" 2>/dev/null || return 0
  [ "$line" = "$pane" ] && roost_shape_owner_drop "$c"
  return 0
}

# roost_pending_cancel FILE %N — T19 for `roost close`: the pending file is
# removed and any launch claim it holds for this pane released (§4.6
# Cancel: a person who closed the pane did not want the agent). Uses
# bin/roost's _SOCKET_FLAG / SOCKET.
roost_pending_cancel() {
  [ -n "$1" ] && [ -f "$1" ] || return 0
  ROOST_RESUME_TFLAG="$_SOCKET_FLAG" ROOST_RESUME_TSOCK="$SOCKET"
  roost_pending__release "$1" "$2" "$_SOCKET_FLAG" "$SOCKET"
  rm -f "$1"
  return 0
}

# ---------------------------------------------------------------------------
# The resume engine (Task 3.5, spec §4.6 and §4.3 Resumes): ONE loop, run by
# a hand `roost restore` in the foreground after placement and by `roost
# restore --resume` (the first-attach worker's form, Part 5's hook; called
# directly until then), so the placeholder, the rename race, the store check
# and the claim per conversation are one code path, and no id is launched
# twice by this run or by any other launcher (§5.1a). Needs bin/roost's `t`,
# `pane_cmd_wired`, _SOCKET_FLAG / SOCKET and ROOST_HOME, and
# scripts/lib/roost-resume.sh (the checks, the claim, the resume command)
# with ROOST_RESUME_TFLAG / ROOST_RESUME_TSOCK set.

# roost_pending__get FILE KEY -> ROOST_PENDING_V, the value of KEY in a
# pending file (the first such line), or empty. Always exit 0: bin/roost runs
# under `set -e`, and a key that is simply absent (a codex file has no
# transcript) must not end a caller that is not in an `||` (found by Task
# 3.11's `--list`). An empty value is "not there". Lines before `was` are a
# `.failed` file's reason and are never a key: `harness missing` is a reason,
# not a harness named "missing" (Task 3.6, a retried file keeps its reason
# line until it leaves `.launching`).
roost_pending__get() {
  local line seen=0
  ROOST_PENDING_V=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$seen" = 0 ]; then
      case "$line" in "was "*) seen=1 ;; *) continue ;; esac
    fi
    case "$line" in "$2 "*) ROOST_PENDING_V="${line#"$2 "}"; return 0 ;; esac
  done < "$1"
  return 0
}

# roost_pending__selected FILE -> exit 0 when ROOST_RESTORE_ONLY is empty or
# one of its selectors names this file's pane: its saved `session`, its
# `session:window`, or its old `%N` (`was`) — §4.3's --only, which restricts
# both placement and resume.
roost_pending__selected() {
  local sel s w was
  [ "${#ROOST_RESTORE_ONLY[@]}" -gt 0 ] || return 0
  roost_pending__get "$1" session; s="$ROOST_PENDING_V"
  roost_pending__get "$1" window; w="$ROOST_PENDING_V"
  roost_pending__get "$1" was; was="$ROOST_PENDING_V"
  for sel in "${ROOST_RESTORE_ONLY[@]}"; do
    case "$sel" in
      %*) [ "$sel" = "$was" ] && return 0 ;;
      *:*) [ "$sel" = "$s:$w" ] && return 0 ;;
      *) [ "$sel" = "$s" ] && return 0 ;;
    esac
  done
  return 1
}

# roost_pending__is_placeholder STARTCOMMAND FILE HARNESS -> exit 0 when the
# start command is the waiting placeholder line written for FILE: by path,
# `<checkout>/scripts/roost-placeholder FILE HARNESS`, quotes and
# backslashes dropped as tmux prints them (roost_restore__placing's rule).
# A bare `respawn-pane` restarts the same line and passes; a person who
# respawned the pane with another command fails (§4.6 step 4).
roost_pending__is_placeholder() {
  local sc="$1" f="$2"
  sc="${sc//\"/}"; sc="${sc//\\/}"
  f="${f//\"/}"; f="${f//\\/}"
  case "$sc" in *roost-placeholder\ "$f"\ "$3") return 0 ;; esac
  return 1
}

# roost_pending__fail LAUNCHING PLAIN REASON [NOTE] [CLAIM] -> T7 (or T9 for
# `pane changed`): the claim this run took is released, the file leaves
# `.launching` for `.failed` with REASON first (origin removed first,
# roost_pending_leave_launching), and the PANE IS NOT TOUCHED — it is still
# the placeholder, which shows the reason itself at its next wake (§4.7 step
# 1; revision 4 item 2: no respawn, so no gap a key could fall into). Then
# the ROOST_TEST_RESUME_HOLD_AFTER_FAILED seam. Prints the reason line.
#
# From a FAILED, DEAD pane (a --retry by T16, ROOST_PENDING_FROMDEAD=1) a
# failed check is T7's other half: the first line STAYS `died` and the new
# reason is added as a note, so the file stays failed, dead and is never
# relabelled failed, waiting, whose row needs a live placeholder (§4.7 T7,
# revision 5, C B2(a)). `pane changed` is T9, not T7, and is written as
# itself.
roost_pending__fail() {
  local l="$1" p="$2" reason="$3" note="${4:-}" claim="${5:-}" pane
  pane="${p##*/}"
  roost_resume_release "$claim"
  if [ "${ROOST_PENDING_FROMDEAD:-0}" = 1 ] && [ "$reason" != "pane changed" ]; then
    note="$reason${note:+: $note}"; reason=died
  fi
  roost_pending_leave_launching "$l" "$p.failed" "$reason" "$note" || true
  roost_shape__seam ROOST_TEST_RESUME_HOLD_AFTER_FAILED
  printf 'roost restore: %s (was %s): %s %s not resumed: %s%s\n' "$pane" "$ROOST_PENDING_WAS" \
    "$ROOST_PENDING_H" "$ROOST_PENDING_ID" "$reason" "${note:+ ($note)}" >&2
}

# roost_pending__one PLAIN-FILE BOOT [FROM] -> one pane through §4.6's steps.
# FROM is the state the file is claimed from: `waiting` (the plain %N, T5),
# or with --retry `failed-waiting` (T14) or `failed-dead` (T16), both claimed
# from %N.failed; it decides step 4's check (§4.7's last column).
#   0   launched (T10). Launched, not resumed: roost does not wait for the
#       harness and answers nothing it opens (§4.1 step 8, §5.2)
#   2   not this run's: a key won the rename first (the pane is the
#       person's), or the pane is gone (its file removed, T19)
#   13  not resumed, the reason written into %N.failed (T7, T9)
#   1   no launch claim can be taken at all: the file is put back to %N and
#       the loop stops — launching with no claim is what claims exist to stop
roost_pending__one() {
  local p="$1" boot="$2" from="${3:-waiting}" pane l h id tr cwd scwd rc dir claim="" info sc dead o first=""
  local -a argv clear
  pane="${p##*/}"
  ROOST_PENDING_FROMDEAD=0
  # Step 1, claim the pane: the rename the placeholder's key races. Lost:
  # the pane is the person's, or another launcher's — move on, nothing
  # touched. From waiting it is T5 with `origin waiting`; from a failed file
  # (--retry) T14 or T16 with `origin failed REASON`, REASON its first line
  # (§4.6 step 1).
  if [ "$from" = waiting ]; then
    roost_pending_take "$p" "$p.launching" waiting || return 2
  else
    [ -f "$p.failed" ] && IFS= read -r first < "$p.failed" || true
    roost_pending_take "$p.failed" "$p.launching" "failed $first" || return 2
    [ "$from" = failed-dead ] && ROOST_PENDING_FROMDEAD=1
  fi
  l="$p.launching"
  roost_pending__get "$l" was; ROOST_PENDING_WAS="$ROOST_PENDING_V"
  roost_pending__get "$l" harness; h="$ROOST_PENDING_V"; ROOST_PENDING_H="$h"
  roost_pending__get "$l" session_id; id="$ROOST_PENDING_V"; ROOST_PENDING_ID="$id"
  roost_pending__get "$l" transcript; tr="$ROOST_PENDING_V"
  roost_pending__get "$l" cwd; cwd="$ROOST_PENDING_V"
  roost_pending__get "$l" session_cwd; scwd="$ROOST_PENDING_V"
  # Step 2, the read-only checks of §4.1 steps 3 to 5, in revive's order and
  # words. Any failure is T7 and the pane is not touched. The four reasons
  # are §4.7's failed, waiting reasons (`harness missing`, `directory gone`,
  # `store miss`, `duplicate of %M`), the ones `--retry` may try again; a
  # finer cause rides along as a note.
  rc=0; roost_resume_command "$h" "$id" "$tr" >/dev/null 2>&1 || rc=$?
  if [ "$rc" != 0 ] && [ "$rc" != 3 ]; then
    roost_pending__fail "$l" "$p" "store miss" "$ROOST_RESUME_WHY"; return 13
  fi
  if ! command -v "$h" >/dev/null 2>&1; then
    roost_pending__fail "$l" "$p" "harness missing" "$h is not on PATH"; return 13
  fi
  # A Claude or pi key whose transcript is unrecorded, or gone, gets the
  # exact-id lookup (revive's step 4): the key's own file, not a guess.
  if [ -z "$tr" ] || [ ! -f "$tr" ]; then
    case "$h" in claude|pi) tr="$(roost_resume_exact_id "$h" "$id" || true)" ;; esac
  fi
  if [ "$h" = claude ] && [ -z "$tr" ]; then
    roost_pending__fail "$l" "$p" "store miss"; return 13
  fi
  # §5.1: the conversation's own directory, or not at all. A rule that names
  # no usable directory (a JSON escape, two keys, none) is a directory this
  # resume cannot have: `directory gone`, with the rule's own words.
  if ! roost_resume_dir "$h" "$tr" "$scwd" "$cwd" >/dev/null; then
    roost_pending__fail "$l" "$p" "directory gone" "$ROOST_RESUME_WHY"; return 13
  fi
  dir="$ROOST_RESUME_DIR"
  if [ ! -d "$dir" ]; then
    roost_pending__fail "$l" "$p" "directory gone" "$dir no longer exists"; return 13
  fi
  rc=0; roost_resume_store_check "$h" "$id" "$tr" || rc=$?
  if [ "$rc" = 3 ]; then
    roost_pending__fail "$l" "$p" "store miss" "opencode resume is not checked; run it by hand in $dir"; return 13
  fi
  if [ "$rc" != 0 ]; then
    roost_pending__fail "$l" "$p" "store miss"; return 13
  fi
  if roost_resume__dup "$pane" "$id"; then
    roost_pending__fail "$l" "$p" "duplicate of $ROOST_RESUME_HOLDER"; return 13
  fi
  # Step 3, claim the conversation (§4.1 step 5a): the ONE claim every
  # launcher takes. Held for another pane: T7, `duplicate of %M`, the pane
  # untouched, so it shows its reason and is not left waiting for ever (F N4).
  if ! roost_resume_claims_dir "$_SOCKET_FLAG" "$SOCKET" "$boot" >/dev/null; then
    roost_pending_leave_launching "$l" "$p" || true
    printf 'roost restore: no launch claim can be taken: %s — nothing more resumed\n' "$ROOST_RESUME_WHY" >&2
    return 1
  fi
  rc=0; roost_resume_claim "$ROOST_RESUME_CLAIMS" "$h" "$id" "$pane" || rc=$?
  case "$rc" in
    0) claim="$ROOST_RESUME_CLAIM" ;;
    1) roost_pending__fail "$l" "$p" "duplicate of ${ROOST_RESUME_HOLDER:-another launcher}" "$ROOST_RESUME_BUSY"
       return 13 ;;
    *) roost_pending_leave_launching "$l" "$p" || true
       printf 'roost restore: cannot claim %s %s: %s — nothing more resumed\n' "$h" "$id" "$ROOST_RESUME_HOLDER" >&2
       return 1 ;;
  esac
  # The plan's seam: after the rename to .launching and the claim, before
  # anything is checked or replaced, so a test can press a key in between.
  roost_shape__seam ROOST_TEST_RESUME_HOLD
  # Step 4, the pane is what its state says (§4.7's last column, for the
  # state step 1 renamed from) — from waiting or failed, waiting: its start
  # command is the placeholder line written for THIS file, and it is alive;
  # from failed, dead: pane_dead is 1, whatever the start command (a dead
  # pane holds no person's work). A pane that is gone was closed (T19): its
  # file goes, its claim with it.
  info="$(t -u display-message -p -t "$pane" '#{pane_id} #{pane_dead} #{pane_start_command}' 2>/dev/null || true)"
  case "$info" in
    "$pane "*) ;;
    *) roost_resume_release "$claim"; rm -f "$l"
       printf 'roost restore: %s (was %s) is gone; its resume is cancelled\n' "$pane" "$ROOST_PENDING_WAS" >&2
       return 2 ;;
  esac
  info="${info#"$pane "}"; dead="${info%% *}"; sc="${info#* }"
  if [ "$from" = failed-dead ]; then
    if [ "$dead" != 1 ]; then
      roost_pending__fail "$l" "$p" "pane changed" "" "$claim"; return 13
    fi
  elif [ "$dead" != 0 ] || ! roost_pending__is_placeholder "$sc" "$p" "$h"; then
    roost_pending__fail "$l" "$p" "pane changed" "" "$claim"; return 13
  fi
  if ! roost_resume_claim_held "$claim"; then
    roost_pending__fail "$l" "$p" "duplicate of another launcher" "its claim was taken over meanwhile"; return 13
  fi
  # Step 5, launch (T10): §4.1 steps 6 to 8. The argv, never a string for a
  # shell, with the harness's home so it reads the store just checked, and
  # through roost-pane-shell on a wired server (#58).
  argv=(); while IFS= read -r o; do argv+=("$o"); done < <(roost_resume_env_argv "$h"; roost_resume_command "$h" "$id" "$tr")
  if pane_cmd_wired; then argv=("$ROOST_HOME/scripts/roost-pane-shell" "${argv[@]}"); fi
  clear=()
  for o in $ROOST_RESUME_CLEAR; do clear+=(set-option -pu -t "$pane" "$o" ';'); done
  t "${clear[@]}" display -p -t "$pane" '' >/dev/null 2>&1 || true
  # remain-on-exit failed: a resume that exits non-zero leaves a dead pane
  # saying why (T13), never a vanished one.
  t set-option -p -t "$pane" remain-on-exit failed 2>/dev/null || true
  if ! t respawn-pane -k -t "$pane" -c "$dir" "${argv[@]}" 2>/dev/null; then
    roost_pending__fail "$l" "$p" "pane changed" "tmux could not respawn it" "$claim"; return 13
  fi
  # T10 also says "then save (--trigger respawn)". Not yet: a save today
  # writes only live identity options, so every pane still WAITING would be
  # written without its key and the newest shape would lose them. The
  # overlay that writes a pending pane's keys from its file is Part 4's
  # (§4.6 Overlay); the save after a launch comes with it.
  argv=(); while IFS= read -r o; do argv+=("$o"); done < <(roost_resume_command "$h" "$id" "$tr")
  printf 'roost restore: %s (was %s): launched %s in %s\n' "$pane" "$ROOST_PENDING_WAS" "${argv[*]}" "$dir" >&2
  return 0
}

# roost_pending__recover DIR BOOT — T8b, run by the worker that holds
# `resuming/`, before its loop: a `.launching` file whose pane still runs its
# placeholder line and whose LAUNCHER IS GONE goes back by its `origin`
# line, read into memory first and removed before the rename (T5's rule,
# revision 10): `origin waiting` → %N; `origin taken` → %N.taken; `origin
# failed REASON` → %N.failed with REASON first; no origin line (the launcher
# died between its rename and its append) proves nothing → %N.failed
# interrupted. The dead claim is released. No other process renames a
# `.launching` file it did not make (§4.6).
#
# The launcher is judged by its own record (roost_pending_take writes it
# before its rename) and by the conversation's claim (§4.1 step 5a): a live
# record for this pane, or a claim for this pane whose owner is alive (pid
# and start time, never age), is a live launcher, and its file is left
# alone. Round 1 judged by the claim alone, and a `revive` between its
# rename and its claim was taken for dead (review round 1, Opus N1). A pane
# running anything but its placeholder line (a launched resume) is never
# touched: identity or its exit settles it.
roost_pending__recover() {
  local d="$1" boot="$2" f p pane info sc h id c rec line orig
  for f in "$d"/%*.launching; do
    [ -f "$f" ] || continue
    p="${f%.launching}"; pane="${p##*/}"
    info="$(t -u display-message -p -t "$pane" '#{pane_id} #{pane_start_command}' 2>/dev/null || true)"
    case "$info" in "$pane "*) sc="${info#"$pane "}" ;; *) continue ;; esac
    roost_pending__get "$f" harness; h="$ROOST_PENDING_V"
    roost_pending__get "$f" session_id; id="$ROOST_PENDING_V"
    roost_pending__is_placeholder "$sc" "$p" "$h" || continue
    # A launcher that is still running — a `revive` between its rename and
    # its claim — is not gone, whatever the claim says yet (review round 1,
    # Opus N1): its record was written before its rename.
    roost_pending__launcher_live "$d" "$pane" && continue
    c=""
    if [ -n "$h" ] && [ -n "$id" ] && roost_resume_claims_dir "$_SOCKET_FLAG" "$SOCKET" "$boot" >/dev/null 2>&1; then
      c="$ROOST_RESUME_CLAIMS/$h-$id"
      rec="$(readlink "$c/owner" 2>/dev/null || true)"
      line=""; [ -f "$c/pane" ] && IFS= read -r line < "$c/pane"
      if [ -n "$rec" ] && [ "$line" = "$pane" ] && roost_shape__alive "$rec"; then continue; fi
      if [ -n "$rec" ] && [ "$line" = "$pane" ]; then roost_shape_owner_drop "$c"; fi
    fi
    orig=""
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in "origin "*) orig="${line#origin }" ;; esac
    done < "$f"
    case "$orig" in
      waiting) roost_pending_leave_launching "$f" "$p" || continue ;;
      taken) roost_pending_leave_launching "$f" "$p.taken" || continue ;;
      "failed "?*) roost_pending_leave_launching "$f" "$p.failed" "${orig#failed }" || continue ;;
      *) roost_pending_leave_launching "$f" "$p.failed" interrupted || continue ;;
    esac
    printf 'roost restore: %s: its launcher is gone; put back (%s)\n' "$pane" "${orig:-no origin: interrupted}" >&2
  done
}

# roost_pending_resume SHAPE-DIR BOOT PACE [RETRY] -> the loop over pending/<boot>/.
#   0   every waiting pane taken was launched, or nothing was waiting
#   13  at least one pane was not resumed, its reason in its .failed file
#   1   another worker holds `resuming/` (nothing done), or no launch claim
#       can be taken at all
#
# Holds `resuming/` under §3.5's owner rule (pid and start time, never age),
# the worker's own lock, not the saver's `lock/`, so saves go on while it
# paces (§4.6, revision 2 item 3). Walks the PLAIN `%N` files only, by their
# `order` line (the shape's pane order), `--pace` seconds between LAUNCHES:
# the wait is before the next claim, so a key pressed in a waiting pane
# during it wins that pane's rename (§8.1 test 11 (a)). Shells come first by
# construction: placement made them before this loop starts.
#
# RETRY 1 (`--retry`) also takes the `%N.failed` files that have a retry
# arrow: failed, waiting (T14) and failed, dead (T16), told apart by the
# first line (§4.7 T14, revision 5, F N6). Taken, changed, replaced,
# exited and interrupted have none, so a retry never meets a person's shell
# or job.
roost_pending_resume() {
  local sd="$1" boot="$2" pace="${3:-2}" retry="${4:-0}" d own rc=0 r f n launched=0 st b first
  d="$sd/pending/$boot"
  [ -d "$d" ] || return 0
  own=0; roost_shape_owner_take "$sd/resuming" || own=$?
  case "$own" in
    1) printf 'roost restore: another resume (pid %s) is resuming this server'"'"'s agents; nothing done\n' "${ROOST_SHAPE_OWNER_PID:-?}" >&2
       return 1 ;;
    3) printf 'roost restore: %s; nothing resumed\n' "${ROOST_SHAPE_OWNER_FAULT:-cannot own $sd/resuming}" >&2
       return 1 ;;
  esac
  # The plain files, by order. A name with a dot is another state; a file
  # with no order sorts last. Read into a list first: the loop renames files
  # in this directory as it goes.
  # T8b first, while this run holds resuming/: a dead launcher's claims are
  # put back so this loop can take them.
  roost_pending__recover "$d" "$boot"
  local list=""
  for f in "$d"/%*; do
    [ -f "$f" ] || continue
    b="${f##*/}"; st=waiting
    case "$b" in
      *.failed)
        [ "$retry" = 1 ] || continue
        st="$(roost_pending_state "$f" || true)"
        case "$st" in failed-waiting|failed-dead) ;; *) continue ;; esac
        b="${b%.failed}"; f="${f%.failed}" ;;
      *.*) continue ;;
    esac
    case "$b" in %|%*[!0-9]*) continue ;; esac
    if [ "$st" = waiting ]; then roost_pending__selected "$f" || continue
    else roost_pending__selected "$f.failed" || continue; fi
    if [ "$st" = waiting ]; then roost_pending__get "$f" order; else roost_pending__get "$f.failed" order; fi
    n="$ROOST_PENDING_V"
    case "$n" in ''|*[!0-9]*) n=999999999 ;; esac
    list="$list$n $st $f"$'\n'
  done
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    f="${f#* }"; st="${f%% *}"; f="${f#* }"
    if [ "$st" = waiting ]; then [ -e "$f" ] || continue; else [ -e "$f.failed" ] || continue; fi
    if [ "$launched" = 1 ] && [ "$pace" != 0 ]; then sleep "$pace"; fi
    r=0; roost_pending__one "$f" "$boot" "$st" || r=$?
    # The result per pane, for restore's report (roost_restore_report):
    # `pane|launched|reason|harness`.
    b="${f##*/}"
    case "$r" in
      0) launched=1; ROOST_PENDING_RESULTS="${ROOST_PENDING_RESULTS:-}$b|1||${ROOST_PENDING_H:-}"$'\n' ;;
      13) rc=13
          first=""; [ -f "$f.failed" ] && IFS= read -r first < "$f.failed"
          ROOST_PENDING_RESULTS="${ROOST_PENDING_RESULTS:-}$b|0|${first:-not resumed}|${ROOST_PENDING_H:-}"$'\n' ;;
      2) if [ -e "$f.taken" ]; then first="taken by a key"; else first="pane gone"; fi
         ROOST_PENDING_RESULTS="${ROOST_PENDING_RESULTS:-}$b|0|$first|"$'\n' ;;
      1) rc=1; break ;;
    esac
  done <<< "$(printf '%s' "$list" | sort -n)"
  roost_shape_owner_drop "$sd/resuming"
  return "$rc"
}

# ---------------------------------------------------------------------------
# Identity lands (Task 3.7, §4.7 T11, T12, T18). Called by `roost identify`
# and roost_identity_from_payload ONLY when the stamp really wrote
# (ROOST_IDENTITY_WROTE=1): an identify that changes nothing keeps its one
# read and its bail, and never reaches here.

# roost_pending__server SOCK -> sets ROOST_PENDING_FLAG / ROOST_PENDING_SOCK,
# the pair bin/roost would hold for the server at socket path SOCK, so the
# shape key (roost_shape_key) and the claims directory are the ones `restore`
# used. A socket in tmux's own directory for this user —
# ${TMUX_TMPDIR:-/tmp}/tmux-<uid>/NAME — is the `-L NAME` server; any other
# path is a `-S PATH` server. Both directories are compared resolved, because
# macOS's /tmp is a link to /private/tmp and $TMUX carries the resolved one.
roost_pending__server() {
  local d own
  d="$(cd -P "$(dirname -- "$1")" 2>/dev/null && pwd)" || d=""
  own="$(cd -P "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)" 2>/dev/null && pwd)" || own=""
  if [ -n "$d" ] && [ "$d" = "$own" ]; then
    ROOST_PENDING_FLAG=-L ROOST_PENDING_SOCK="${1##*/}"
  else
    ROOST_PENDING_FLAG=-S ROOST_PENDING_SOCK="$1"
  fi
}

# roost_pending_identified SOCK %N ID BOOT — identity just landed on %N with ID:
#   %N.launching, same id      T11: the file and the claim are removed; from
#                              now on the live @roost-session is the owner
#                              §5.1a checks
#   %N.launching, another id   T12: a person answered "No, exit" and started a
#                              fresh agent: %N.failed replaced (origin removed
#                              first), the claim released
#   %N.taken                   T18: the person started an agent in the shell
#                              they took: the file is removed
# Any other state is left as it is. Never fails its caller: identify is called
# from adapters, which discard its exit and stderr.
#
# NO TMUX CALL. BOOT is the boot key the stamp's own single read returned
# (ROOST_IDENTITY_BOOT): tests/test-identity.sh pins a changed identity at one
# read and one write, and this runs on that path. The file is found where
# `restore` writes it with saving on, pending/<boot>/%N in this server's shape
# directory. A hand restore with saving off keeps its pending files in its
# own temporary directory, which this cannot see: such a file is never
# released here and simply goes with that directory.
roost_pending_identified() {
  local sock="$1" pane="$2" id="$3" boot="${4:-}" f root got
  [ -n "$boot" ] || return 0
  case "$pane" in %[0-9]*) ;; *) return 0 ;; esac
  root="$(roost_shape_saving 2>/dev/null)" || return 0
  roost_pending__server "$sock"
  f="$root/$(roost_shape_key "$ROOST_PENDING_FLAG" "$ROOST_PENDING_SOCK")/pending/$boot/$pane"
  if [ -f "$f.launching" ]; then
    roost_pending__get "$f.launching" session_id; got="$ROOST_PENDING_V"
    roost_pending__release "$f.launching" "$pane" "$ROOST_PENDING_FLAG" "$ROOST_PENDING_SOCK"
    if [ "$got" = "$id" ]; then
      rm -f "$f.launching"
    else
      roost_pending_leave_launching "$f.launching" "$f.failed" replaced || true
    fi
  elif [ -f "$f.taken" ]; then
    rm -f "$f.taken"
  fi
  return 0
}
