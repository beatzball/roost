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
roost_pending_take() {
  [ -e "$1" ] || return 1
  # `mv` without -f or -i, and nothing between the check above and it but
  # the rename itself: whoever renames FROM first wins, and the loser's mv
  # finds no FROM.
  mv "$1" "$2" 2>/dev/null || return 1
  [ -n "${3:-}" ] && printf 'origin %s\n' "$3" >> "$2"
  return 0
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
        "harness missing"|"directory gone"|"store miss"|"duplicate of %"[0-9]*) printf 'failed-waiting\n' ;;
        *) printf 'failed-interrupted\n' ;;
      esac ;;
    %*)
      case "${b#%}" in ''|*[!0-9]*) return 1 ;; esac
      printf 'waiting\n' ;;
    *) return 1 ;;
  esac
}
