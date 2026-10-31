# roost-resume.sh — bringing a conversation back (#57, #191): the per-harness
# resume command, the directory a resume runs in, and the check that the
# harness still holds the conversation before anything is killed or launched.
#
# Sourced by bin/roost's `revive` arm (and, from Part 3, by restore's resume
# engine). The design, and every measurement these rules rest on, is
# docs/airig/specs/2026-10-24-persistent-sessions-design.md: §2.8 the resume
# table, §5.1 which directory, §5.1a the store check, §4.1 `revive`. The plan's
# "Names this plan fixes" table says what else lands here: `claims/` and
# `revive`'s core (Part 2), the printed store listings (Part 6).
#
# NOTHING HERE EVALUATES A VALUE. A session id, a transcript path and a
# directory come from pane options, the pane record or (Part 3) a saved shape —
# files a person may have edited or copied from another machine. So a harness
# is looked up in the table below or refused; an id must pass its adapter's
# shape before it goes anywhere; a command is an argv, one word per line,
# never a string a shell will read; a directory is passed as an argument.
#
# Every function is bash 3.2 safe and `set -u` clean: bin/roost runs on macOS
# /bin/bash.

# The harness homes, each read the way the harness reads it, so a store check
# looks where the harness itself would. scripts/lib/roost-adapters.sh has the
# same defaults for the install side; these are the store side.
roost_resume__claude_home() { printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; }
roost_resume__codex_home()  { printf '%s' "${CODEX_HOME:-$HOME/.codex}"; }
roost_resume__copilot_home() { printf '%s' "${COPILOT_HOME:-$HOME/.copilot}"; }
roost_resume__pi_home()     { printf '%s' "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"; }

# roost_resume__uuid ID — a UUID, 8-4-4-4-12 hex digits. Four harnesses use
# one (§2.1–2.4: Claude's session id, codex's rollout uuid, copilot's session,
# pi's UUIDv7). Checked letter by letter: a glob below is built from the id, so
# an id holding `*`, `?`, `[` or `/` must never get that far, and this shape
# admits none of them.
roost_resume__uuid() {
  local id="$1"
  [ "${#id}" -eq 36 ] || return 1
  case "$id" in
    ????????-????-????-????-????????????) ;;
    *) return 1 ;;
  esac
  case "${id//-/}" in
    *[!0-9a-fA-F]*) return 1 ;;
  esac
  return 0
}

# roost_resume__id_ok HARNESS ID — the adapter's own shape for an id.
# opencode's ids are `ses_…`; it gets identity's general rule (letters, digits,
# `. _ : -`, not starting with `-`, at most 128), since its command is only
# ever printed (§2.8: its store check is not measured).
roost_resume__id_ok() {
  case "$1" in
    claude|codex|copilot|pi) roost_resume__uuid "$2" ;;
    opencode)
      [ -n "$2" ] && [ "${#2}" -le 128 ] || return 1
      case "$2" in -*|*[!A-Za-z0-9._:-]*) return 1 ;; esac
      return 0 ;;
    *) return 1 ;;
  esac
}

# roost_resume__path_ok PATH — an absolute path with no control character. A
# transcript is printed one word per line below and read back the same way,
# so a newline would split it into two words.
roost_resume__path_ok() {
  case "$1" in /*) ;; *) return 1 ;; esac
  case "$1" in *[[:cntrl:]]*) return 1 ;; esac
  return 0
}

# roost_resume_command HARNESS ID TRANSCRIPT -> prints the resume argv, one
# word per line (§2.8's "resume by id" column).
#   0  a command to run
#   3  opencode: printed, NOT to be run. `opencode -s ID` creates the session
#      when the id is unknown (§2.5, from its own --help), and its store check
#      is not measured, so a resume of a lost id would "succeed" into an empty
#      conversation. The caller prints it for a person and launches nothing.
#   1  refused, ROOST_RESUME_WHY says why: a harness with no row, or an id that
#      fails its adapter's shape
#
#   claude    claude --resume ID
#   codex     codex resume ID
#   copilot   copilot --resume=ID   (one word: the flag takes `=`)
#   pi        pi --session PATH     when the session file is known — measured
#                                   to resume with no dialog from any directory
#                                   (§2.4) — else pi --session ID
#   opencode  opencode -s ID        (return 3)
roost_resume_command() {
  local h="$1" id="$2" tr="${3:-}"
  ROOST_RESUME_WHY=""
  if ! roost_resume__id_ok "$h" "$id"; then
    case "$h" in
      claude|codex|copilot|pi|opencode) ROOST_RESUME_WHY="'$id' is not a $h session id" ;;
      *) ROOST_RESUME_WHY="no resume command for harness '$h'" ;;
    esac
    return 1
  fi
  case "$h" in
    claude)   printf '%s\n' claude --resume "$id" ;;
    codex)    printf '%s\n' codex resume "$id" ;;
    copilot)  printf '%s\n' copilot "--resume=$id" ;;
    pi)
      if [ -n "$tr" ] && roost_resume__path_ok "$tr"; then
        printf '%s\n' pi --session "$tr"
      else
        printf '%s\n' pi --session "$id"
      fi ;;
    opencode) printf '%s\n' opencode -s "$id"; return 3 ;;
  esac
  return 0
}

# roost_resume_first_cwd FILE -> prints the first `"cwd":"…"` value in a Claude
# transcript; 1 when there is none or it cannot be used.
#
# The spec's read, exactly (§5.1): `grep -m1 -o` stops at the first MATCHING
# LINE but prints every match on it, so `head -n 1` takes the first of two on
# one line. No JSON parser. A value holding a backslash is a JSON escape (`\"`,
# `\\`, `\u…`), and is refused rather than decoded: a decoder written here
# would be a second, untested JSON reader, and a wrong decode resumes in the
# wrong directory, which is what §5.1 exists to stop. The pattern stops at the
# first `"`, so an escaped quote leaves a trailing `\` and is refused too.
roost_resume_first_cwd() {
  local v
  [ -f "$1" ] || return 1
  v="$(grep -m1 -o '"cwd":"[^"]*"' "$1" 2>/dev/null | head -n 1)"
  [ -n "$v" ] || return 1
  v="${v#\"cwd\":\"}"
  v="${v%\"}"
  case "$v" in *\\*) return 1 ;; esac
  roost_resume__path_ok "$v" || return 1
  printf '%s\n' "$v"
}

# roost_resume_dir HARNESS TRANSCRIPT SESSION_CWD CWD -> prints the directory a
# resume runs in (§5.1); 1, ROOST_RESUME_WHY set, when there is none to use.
# It CHOOSES; it does not ask whether the directory exists — that is the
# caller's exit 15, said in the caller's words.
#
#   SESSION_CWD  the identity's cwd (@roost-cwd, the record's `cwd`)
#   CWD          the pane's own #{pane_current_path}; empty for a gone pane
#
#   claude   the transcript's own first `cwd`. Never a folder name derived
#            from a path (§2.1: the `.` of `.claude` is written `-` too), and
#            NOT required to equal SESSION_CWD or CWD: the transcript is the
#            conversation's own file, so its cwd is the project by definition,
#            and requiring a match refused §2.6's live case — an identity cwd
#            in a removed worktree, the transcript filed under the root.
#            Probe 2.2 (docs/airig/probes/persist-2-refiled-cwd.md): a resume
#            elsewhere leaves the first line as it was. No transcript, or no
#            usable cwd line: refused, never a guess.
#   pi       SESSION_CWD, else CWD: `pi --session PATH` returns to the
#            session's own directory from anywhere (§2.4), so this is only
#            where the process starts.
#   codex, copilot, opencode
#            SESSION_CWD, else CWD.
roost_resume_dir() {
  local h="$1" tr="${2:-}" scwd="${3:-}" cwd="${4:-}" d
  ROOST_RESUME_WHY=""
  case "$h" in
    claude)
      if [ -z "$tr" ]; then
        ROOST_RESUME_WHY="no transcript to read its directory from"; return 1
      fi
      if ! d="$(roost_resume_first_cwd "$tr")"; then
        ROOST_RESUME_WHY="the transcript $tr names no usable directory"; return 1
      fi
      printf '%s\n' "$d" ;;
    pi|codex|copilot|opencode)
      d="$scwd"; [ -n "$d" ] || d="$cwd"
      if [ -z "$d" ] || ! roost_resume__path_ok "$d"; then
        ROOST_RESUME_WHY="no directory recorded"; return 1
      fi
      printf '%s\n' "$d" ;;
    *) ROOST_RESUME_WHY="no resume rule for harness '$h'"; return 1 ;;
  esac
}

# roost_resume__one_file GLOB — set ROOST_RESUME_FILE to the one existing path
# GLOB matches; 1 when it matches none, or more than one. Exactly one, never
# "the newest": a key is a conversation's own id, so two files carrying it are
# two conversations roost cannot tell apart, and picking one is a guess.
# The glob is the caller's, built from a checked UUID, so it holds no
# metacharacter of the id's making.
roost_resume__one_file() {
  local f n=0
  ROOST_RESUME_FILE=""
  # Unquoted on purpose: this is the one place a glob expands.
  for f in $1; do
    [ -e "$f" ] || continue
    n=$((n + 1))
    ROOST_RESUME_FILE="$f"
  done
  [ "$n" -eq 1 ] && return 0
  ROOST_RESUME_FILE=""
  return 1
}

# roost_resume_exact_id HARNESS ID -> prints the one store file whose NAME
# carries ID; 1 when there are none or more than one (§4.1 step 1). For a
# pane record written before the record kept `transcript` (Task 2.3): that is
# the key's own file, not the newest file in a directory, so it is not a guess.
#   claude  ${CLAUDE_CONFIG_DIR:-~/.claude}/projects/*/<id>.jsonl
#   pi      ${PI_CODING_AGENT_DIR:-~/.pi/agent}/sessions/*/*_<id>.jsonl
# No folder name is derived from a directory: the `*` stands for it.
roost_resume_exact_id() {
  roost_resume__uuid "$2" || return 1
  case "$1" in
    claude) roost_resume__one_file "$(roost_resume__claude_home)/projects/*/$2.jsonl" || return 1 ;;
    pi)     roost_resume__one_file "$(roost_resume__pi_home)/sessions/*/*_$2.jsonl" || return 1 ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$ROOST_RESUME_FILE"
}

# roost_resume_store_check HARNESS ID TRANSCRIPT — does the harness still hold
# this conversation (§5.1a, §2.8's "store check" column)? Asked BEFORE anything
# is killed or launched: every harness measured exits 1 at once on an unknown
# id, and roost-pane-shell `exec`s it, so a resume of a lost conversation
# would kill the pane's shell for nothing. Claude's own 30-day transcript
# cleanup makes that the everyday fate of a pane idle for a month.
#   0  held; ROOST_RESUME_FILE names the file or directory found
#   1  a miss: zero matches, or more than one
#   3  opencode: not checked (its store is a database, the check unmeasured)
#
#   claude   the recorded transcript exists, else exactly one
#            projects/*/<id>.jsonl
#   codex    exactly one $CODEX_HOME/sessions/**/rollout-*-<id>.jsonl, found
#            with `find` (bash 3.2 has no `**`)
#   copilot  $COPILOT_HOME/session-state/<id>/ is a directory
#   pi       the recorded session file exists, else exactly one
#            sessions/*/*_<id>.jsonl
roost_resume_store_check() {
  local h="$1" id="$2" tr="${3:-}" d n
  ROOST_RESUME_FILE=""
  if [ "$h" = opencode ]; then return 3; fi
  roost_resume__uuid "$id" || return 1
  case "$h" in
    claude|pi)
      if [ -n "$tr" ] && roost_resume__path_ok "$tr" && [ -f "$tr" ]; then
        ROOST_RESUME_FILE="$tr"; return 0
      fi
      roost_resume_exact_id "$h" "$id" >/dev/null || return 1 ;;
    codex)
      d="$(roost_resume__codex_home)/sessions"
      [ -d "$d" ] || return 1
      # The id is a checked UUID, so it is safe inside -name's pattern.
      n="$(find "$d" -type f -name "rollout-*-$id.jsonl" 2>/dev/null | head -n 3)"
      case "$n" in
        "") return 1 ;;
        *"
"*) return 1 ;;
      esac
      ROOST_RESUME_FILE="$n" ;;
    copilot)
      d="$(roost_resume__copilot_home)/session-state/$id"
      [ -d "$d" ] || return 1
      ROOST_RESUME_FILE="$d" ;;
    *) return 1 ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Claims (§4.1 step 5a, §4.6): one per conversation being launched, by ANY
# launcher — `revive` in place, `revive` of a gone pane or into a new window,
# and from Part 3 a hand restore and the first-attach worker. A store check
# only LOOKS for another owner; revision 2 stopped there, and two revives of
# one gone record — the second while the first sat in a trust dialog with no
# identity yet — both launched. So every launcher takes this claim before it
# launches, and releases only a claim it took itself.
#
#   <shape dir>/claims/<boot>/<harness>-<session_id>/
#     owner   a symbolic link to "PID LSTART": the launcher's pid and start
#             time, exactly Part 1's owner record (roost-shape.sh,
#             roost_shape__claim)
#     pane    the pane the launch is aimed at, one line; empty until the
#             launcher knows it (a new window's id exists only once
#             `new-window` has made it)
#
# WHY A LINK AND NOT `pid` AND `lstart` FILES. The plan names two files, and
# that is mkdir-then-write: between the two a second launcher finds a claim
# with no owner in it, and has to guess whether it is being written or was
# left by a launcher that died between the steps. Part 1 met exactly this in
# its owner record and replaced it with one `ln -s`, which exists with its
# content or not at all (review round 1, Codex B2). The claim reuses that
# record and its takeover of a dead holder, which nine review rounds tested,
# rather than writing a second one. The `pane` file is written after the link,
# so a reader that sees a link with no pane yet judges by the owner's
# liveness — and that owner is live, which is the right answer.
#
# Needs roost-shape.sh (the owner record) and ROOST_RESUME_TFLAG /
# ROOST_RESUME_TSOCK, bin/roost's own pair, for the server the panes are on.
. "$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/roost-shape.sh"

roost_resume__t() { tmux -u "$ROOST_RESUME_TFLAG" "$ROOST_RESUME_TSOCK" "$@"; }

# roost_resume__me -> this run's owner record, "PID LSTART".
roost_resume__me() { printf '%s %s' "$$" "$(roost_shape__lstart "$$")"; }

# roost_resume__pane_exists %N — the pane is on this server now. Asked of tmux,
# never of a record: a claim's pane is judged by whether it still exists.
roost_resume__pane_exists() {
  case "$1" in %[0-9]*) ;; *) return 1 ;; esac
  case "${1#%}" in *[!0-9]*) return 1 ;; esac
  [ "$(roost_resume__t display -p -t "$1" '#{pane_id}' 2>/dev/null)" = "$1" ]
}

# roost_resume__put_pane CLAIM %N — the pane file, whole or not at all.
roost_resume__put_pane() {
  local tmp="$1/.pane.$$"
  ( umask 077; printf '%s\n' "$2" > "$tmp" ) 2>/dev/null && mv -f "$tmp" "$1/pane" 2>/dev/null
}

# roost_resume_claim DIR HARNESS ID PANE — claim the conversation.
#   DIR    <shape dir>/claims/<boot>, made 0700 when missing
#   PANE   the target pane, or empty when it does not exist yet
#   0  claimed: fresh, or a stale claim taken over. ROOST_RESUME_CLAIM is its
#      path, for roost_resume_claim_pane and roost_resume_release
#   1  refused: ROOST_RESUME_HOLDER is the other pane (`%M`), or `pid N` for a
#      claimer that names no pane yet. The claim found is not touched
#   3  cannot claim at all: ROOST_RESUME_HOLDER says why
#
# A claim found is judged in TWO STAGES (§4.1 step 5a):
#   it names a pane   the same pane as this claim -> taken over (an in-place
#                     revive of a pane whose earlier launch never identified);
#                     another pane that EXISTS -> refused, whatever the
#                     claimer's liveness: the claimer is usually a short-lived
#                     `revive` that has already exited while its pane sits in
#                     a dialog; a pane that is gone -> stale, taken over
#   it names none     the claimer's liveness decides: a live owner (pid
#                     running with its recorded start time) -> refused; a dead
#                     one, or its pid reused -> taken over
roost_resume_claim() {
  local dir="$1" h="$2" id="$3" pane="${4:-}" c me cur p r try=0
  ROOST_RESUME_CLAIM="" ROOST_RESUME_HOLDER=""
  if ! roost_resume__id_ok "$h" "$id"; then
    ROOST_RESUME_HOLDER="'$id' is not a $h session id"; return 3
  fi
  c="$dir/$h-$id"
  if ! ( umask 077; mkdir -p "$c" ) 2>/dev/null; then
    ROOST_RESUME_HOLDER="cannot create $c"; return 3
  fi
  me="$(roost_resume__me)"
  # Bounded: each turn either claims, refuses, or saw the claim change under
  # it (another launcher linked or released in between) and judges again.
  while [ "$try" -lt 5 ]; do
    try=$((try + 1))
    if ! cur="$(readlink "$c/owner" 2>/dev/null)"; then
      # No claim, or a fault roost_shape__claim names (a plain file there).
      r=0; roost_shape__claim "$c/owner" "$me" || r=$?
      case "$r" in
        0|2) roost_resume__put_pane "$c" "$pane"; ROOST_RESUME_CLAIM="$c"; return 0 ;;
        3) ROOST_RESUME_HOLDER="$ROOST_SHAPE_OWNER_FAULT"; return 3 ;;
      esac
      continue
    fi
    [ "$cur" = "$me" ] && { roost_resume__put_pane "$c" "$pane"; ROOST_RESUME_CLAIM="$c"; return 0; }
    p=""
    [ -f "$c/pane" ] && IFS= read -r p < "$c/pane" 2>/dev/null
    if [ -n "$p" ]; then
      if [ -n "$pane" ] && [ "$p" = "$pane" ]; then
        :   # this pane's own earlier launch: take it over
      elif roost_resume__pane_exists "$p"; then
        ROOST_RESUME_HOLDER="$p"; return 1
      fi
      # The same pane, or a gone one: stale whatever its claimer's
      # liveness. Remove that record — only if it is still the one judged —
      # and link this run's; a launcher that linked first wins, and this one
      # judges what it left.
      [ "$(readlink "$c/owner" 2>/dev/null)" = "$cur" ] && rm -f "$c/owner"
      continue
    fi
    # No pane named: the owner's liveness decides. roost_shape__claim does
    # exactly that — refuses a live owner, takes over a dead or reused one.
    r=0; roost_shape__claim "$c/owner" "$me" || r=$?
    case "$r" in
      0|2) roost_resume__put_pane "$c" "$pane"; ROOST_RESUME_CLAIM="$c"; return 0 ;;
      3) ROOST_RESUME_HOLDER="$ROOST_SHAPE_OWNER_FAULT"; return 3 ;;
    esac
    # A live owner. If it has named a pane since, judge that instead.
    p=""
    [ -f "$c/pane" ] && IFS= read -r p < "$c/pane" 2>/dev/null
    [ -n "$p" ] && continue
    ROOST_RESUME_HOLDER="pid ${ROOST_SHAPE_OWNER_PID:-?}"
    return 1
  done
  ROOST_RESUME_HOLDER="the claim $c kept changing"
  return 1
}

# roost_resume_claim_pane CLAIM %N — name the pane once it exists (a new
# window). Only on a claim this run holds.
roost_resume_claim_pane() {
  [ "$(readlink "$1/owner" 2>/dev/null)" = "$(roost_resume__me)" ] || return 1
  roost_resume__put_pane "$1" "$2"
}

# roost_resume_release CLAIM — remove a claim, only when its owner record is
# this run's (§4.1 step 5a, "release only what this run took"). A claim found
# and refused is never touched; neither is one another launcher took over
# after this run's pane went away. Renamed aside first (roost_shape_owner_drop),
# so a reader never finds half of it.
roost_resume_release() {
  [ -n "${1:-}" ] || return 0
  [ "$(readlink "$1/owner" 2>/dev/null)" = "$(roost_resume__me)" ] || return 0
  roost_shape_owner_drop "$1"
}
