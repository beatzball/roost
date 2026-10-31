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

# roost_resume_env_argv HARNESS -> prints, one word per line, the `env` words
# that go in front of the resume argv so the harness reads the SAME store the
# check read (review round 1, Codex B5). The store check reads the harness's
# home variable in revive's own environment; the respawned process takes its
# environment from the tmux server, which may have been started with another
# home, or none. So the launch says it outright: the home variable as revive
# saw it — `VAR=value` when set, `-u VAR` when not, since then the check read
# the default under HOME and the server's value must not win — and HOME
# itself, which every default is built on.
#
# `env` in the argv rather than tmux's `-e`: `-e` can only SET a variable,
# and the unset case is the one a server-wide value would otherwise win.
roost_resume_env_argv() {
  local v
  case "$1" in
    claude) v=CLAUDE_CONFIG_DIR ;;
    codex) v=CODEX_HOME ;;
    copilot) v=COPILOT_HOME ;;
    pi) v=PI_CODING_AGENT_DIR ;;
    *) return 0 ;;
  esac
  printf '%s\n' env
  # `-u` first: `env` reads options only before the first NAME=value, and
  # takes a later `-u` as the command to run (measured on macOS).
  [ -n "${!v+set}" ] || printf -- '-u\n%s\n' "$v"
  [ -n "${HOME:-}" ] && printf 'HOME=%s\n' "$HOME"
  if [ -n "${!v+set}" ]; then printf '%s=%s\n' "$v" "${!v}"; fi
  return 0
}

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
# resume runs in (§5.1), and sets ROOST_RESUME_DIR to it, so a caller that
# needs ROOST_RESUME_WHY can call it without a $(...) subshell, which would
# lose the reason; 1, ROOST_RESUME_WHY set, when there is none to use.
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
  ROOST_RESUME_WHY="" ROOST_RESUME_DIR=""
  case "$h" in
    claude)
      if [ -z "$tr" ]; then
        ROOST_RESUME_WHY="no transcript to read its directory from"; return 1
      fi
      if ! d="$(roost_resume_first_cwd "$tr")"; then
        ROOST_RESUME_WHY="the transcript $tr names no usable directory"; return 1
      fi
      ROOST_RESUME_DIR="$d"; printf '%s\n' "$d" ;;
    pi|codex|copilot|opencode)
      d="$scwd"; [ -n "$d" ] || d="$cwd"
      if [ -z "$d" ] || ! roost_resume__path_ok "$d"; then
        ROOST_RESUME_WHY="no directory recorded"; return 1
      fi
      ROOST_RESUME_DIR="$d"; printf '%s\n' "$d" ;;
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
#     pane    two lines: the pane the launch is aimed at (empty until the
#             launcher knows it: a new window's id exists only once
#             `new-window` has made it), then the owner record it was
#             written under. A reader uses the pane only when that second
#             line is the CURRENT owner link; any other pane file is a
#             previous owner's and names nothing (review round 1, B1)
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
# WHY THE PANE FILE NAMES ITS OWNER (review round 1, B1, both reviewers,
# reproduced: two launches of one conversation). A takeover of a stale claim
# links its owner record first and writes its pane after; in between, the
# PREVIOUS owner's pane file — naming a gone pane — sat beside the new live
# link, and a second launcher read the pair as "stale, take it over", removed
# the new link and launched too. Deleting the old pane file first (the
# reviewer's fix) narrows that but still lets a slow launcher delete the new
# owner's fresh pane file. So the pane file is tagged with the owner record
# it was written under, and a mismatched tag is simply not a pane: the new
# owner reads as "no pane yet", and its liveness refuses the second
# launcher. And every write is checked afterwards: a launcher that no longer
# holds the owner link stops before it launches anything.
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

# roost_resume__put_pane CLAIM %N — the pane file, whole or not at all, tagged
# with this run's owner record; then the claim is checked to be still this
# run's. Exit 1 when the write failed or the owner link is no longer this
# run's — the caller must not launch.
roost_resume__put_pane() {
  local tmp="$1/.pane.$$" me
  me="$(roost_resume__me)"
  ( umask 077; printf '%s\n%s\n' "$2" "$me" > "$tmp" ) 2>/dev/null \
    && mv -f "$tmp" "$1/pane" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  roost_resume_claim_held "$1"
}

# roost_resume__pane_of CLAIM OWNER -> ROOST_RESUME_P, the pane the claim names
# for that owner record; empty when there is no pane file, it names none, or
# it was written under another owner (a previous holder's leftover).
roost_resume__pane_of() {
  local p="" g=""
  ROOST_RESUME_P=""
  [ -f "$1/pane" ] || return 0
  { IFS= read -r p; IFS= read -r g; } < "$1/pane" 2>/dev/null || true
  [ "$g" = "$2" ] && ROOST_RESUME_P="$p"
  return 0
}

# roost_resume_claims_dir FLAG SOCKET BOOT -> sets ROOST_RESUME_CLAIMS to the
# directory this boot's claims live in, made 0700 (and prints it); exit 1,
# ROOST_RESUME_WHY naming the directory and what failed, when there is none
# to use. Call it without a $(...) so the reason reaches the caller.
#
# CLAIMS DO NOT DEPEND ON SAVING (review round 1, Codex B4 and Fable N2). With
# saving on they live in the shape directory, `<shape dir>/claims/<boot>/`, as
# §3.1 lays out. With saving off (ROOST_SHAPE_DIR empty, or no usable root)
# there is no shape directory, and the first version took no claim at all —
# two revives of one gone record then both launched. §4.1 step 5a and §5.1a
# have no saving-off exemption, so claims move to a directory of their own,
# with the same layout and the same boot key:
#
#   ${XDG_STATE_HOME:-~/.local/state}/roost/launch-claims/<server>/claims/<boot>/
#
# under the state directory beside the pane records, so `rm -rf
# ~/.local/state/roost` still forgets them. When neither can be made or
# secured, the caller REFUSES (exit 1): launching with no claim is what this
# exists to stop, and the message names the storage error, never "saving is
# off".
roost_resume_claims_dir() {
  local base st key d
  ROOST_RESUME_WHY="" ROOST_RESUME_CLAIMS=""
  if roost_shape_saving >/dev/null 2>&1; then
    if ! base="$(roost_shape_dir "$1" "$2" 2>/dev/null)"; then
      ROOST_RESUME_WHY="cannot make or secure the shape directory $(roost_shape_saving)/$(roost_shape_key "$1" "$2")"
      return 1
    fi
  else
    st="${XDG_STATE_HOME:-}"
    case "$st" in
      /*) ;;
      *) case "${HOME:-}" in
           /*) st="$HOME/.local/state" ;;
           *) ROOST_RESUME_WHY="no state directory for launch claims (neither XDG_STATE_HOME nor HOME is an absolute path)"; return 1 ;;
         esac ;;
    esac
    key="$(roost_shape_key "$1" "$2")"
    base="$st/roost/launch-claims/$key"
    if ! ( umask 077; mkdir -p "$base" ) 2>/dev/null || ! chmod go-rwx "$base" 2>/dev/null; then
      ROOST_RESUME_WHY="cannot make or secure $base"
      return 1
    fi
  fi
  d="$base/claims/$3"
  if ! ( umask 077; mkdir -p "$d" ) 2>/dev/null; then
    ROOST_RESUME_WHY="cannot make $d"
    return 1
  fi
  ROOST_RESUME_CLAIMS="$d"
  printf '%s\n' "$d"
}

# roost_resume_claim_held CLAIM — the owner link is this run's.
roost_resume_claim_held() {
  [ -n "${1:-}" ] && [ "$(readlink "$1/owner" 2>/dev/null)" = "$(roost_resume__me)" ]
}

# roost_resume__take_stale CLAIM OWNER — remove the owner link judged stale,
# and only that one. A `readlink`, then an `rm`, removed whatever link was
# there at the rm — a launcher that took the claim over in between lost its
# link to this one. So the link is moved aside in one rename, THEN read: the
# judged record is deleted; any other record is put back with `ln -s`, which
# fails only when yet another launcher linked meanwhile. Exit 1 then, and the
# caller refuses: two launchers holding one claim is the one outcome this
# exists to stop, and refusing is the safe side.
roost_resume__take_stale() {
  local aside="$1/owner.stale.$$" got
  mv "$1/owner" "$aside" 2>/dev/null || return 0
  got="$(readlink "$aside" 2>/dev/null)"
  if [ "$got" = "$2" ]; then rm -f "$aside"; return 0; fi
  if ln -s "$got" "$1/owner" 2>/dev/null; then rm -f "$aside"; return 0; fi
  rm -f "$aside"
  return 1
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
        0|2) roost_shape__seam ROOST_TEST_CLAIM_HOLD_AFTER_LINK
             if roost_resume__put_pane "$c" "$pane"; then ROOST_RESUME_CLAIM="$c"; return 0; fi ;;
        3) ROOST_RESUME_HOLDER="$ROOST_SHAPE_OWNER_FAULT"; return 3 ;;
      esac
      continue
    fi
    if [ "$cur" = "$me" ]; then
      if roost_resume__put_pane "$c" "$pane"; then ROOST_RESUME_CLAIM="$c"; return 0; fi
      continue
    fi
    roost_resume__pane_of "$c" "$cur"; p="$ROOST_RESUME_P"
    if [ -n "$p" ]; then
      if [ -n "$pane" ] && [ "$p" = "$pane" ]; then
        :   # this pane's own earlier launch: take it over
      elif roost_resume__pane_exists "$p"; then
        ROOST_RESUME_HOLDER="$p"; return 1
      fi
      # The same pane, or a gone one: stale whatever its claimer's
      # liveness. Remove that record — only that one, in one rename
      # (roost_resume__take_stale) — and link this run's; a launcher that
      # linked first wins, and this one judges what it left.
      if ! roost_resume__take_stale "$c" "$cur"; then
        ROOST_RESUME_HOLDER="another launcher (the claim $c changed while it was taken over)"
        return 1
      fi
      continue
    fi
    # No pane named: the owner's liveness decides. roost_shape__claim does
    # exactly that — refuses a live owner, takes over a dead or reused one.
    r=0; roost_shape__claim "$c/owner" "$me" || r=$?
    case "$r" in
      0|2) if roost_resume__put_pane "$c" "$pane"; then ROOST_RESUME_CLAIM="$c"; return 0; fi
           continue ;;
      3) ROOST_RESUME_HOLDER="$ROOST_SHAPE_OWNER_FAULT"; return 3 ;;
    esac
    # A live owner. If it has named a pane since, judge that instead.
    cur="$(readlink "$c/owner" 2>/dev/null || true)"
    roost_resume__pane_of "$c" "$cur"
    [ -n "$ROOST_RESUME_P" ] && continue
    ROOST_RESUME_HOLDER="pid ${ROOST_SHAPE_OWNER_PID:-?}"
    return 1
  done
  ROOST_RESUME_HOLDER="the claim $c kept changing"
  return 1
}

# roost_resume_claim_pane CLAIM %N — name the pane once it exists (a new
# window). Only on a claim this run holds; exit 1 when it is not (any more),
# and the caller stops before launching.
roost_resume_claim_pane() {
  roost_resume_claim_held "$1" || return 1
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

# ---------------------------------------------------------------------------
# `roost revive` (§4.1): the verb's core. bin/roost's arm parses the flags and
# calls roost_revive; everything it decides is here.

# roost_resume__opt PANE OPTION -> ROOST_RESUME_V, one PANE-scope option as the
# person set it; exit 1 when it holds a control character (then
# ROOST_RESUME_V is empty). `show-options -p`, never a #{@…} format: a format
# falls back to window and global scope, and a global value is not this pane's
# key. Read the way Part 1's writer reads (roost_shape__clean): ruling R6's
# `\$` undone on a server that prints it, and a control byte refused.
roost_resume__opt() {
  local v
  v="$(roost_resume__t show-options -pqv -t "$1" "$2" 2>/dev/null; printf .)"
  v="${v%.}"; v="${v%$'\n'}"
  ROOST_RESUME_V=""
  roost_shape__clean "$v" octal || return 1
  ROOST_RESUME_V="$ROOST_SHAPE_V"
}

# roost_resume__fmt PANE FORMAT -> ROOST_RESUME_V, a pane format (not an
# option), cleaned the same way.
roost_resume__fmt() {
  roost_shape__d "$1" "$2"
  ROOST_RESUME_V=""
  roost_shape__clean "$ROOST_SHAPE_D" octal || return 1
  ROOST_RESUME_V="$ROOST_SHAPE_V"
}

# roost_resume__row PANE -> 0 when PANE is on the server now. Matched by id
# out of `list-panes -a`, the way `close` does and for its reason: tmux 3.6
# answers display-message for a gone pane with exit 0 and every format empty.
roost_resume__row() {
  local all r
  all="$(roost_resume__t list-panes -a -F '#{pane_id}' 2>/dev/null)" || return 1
  while IFS= read -r r; do [ "$r" = "$1" ] && return 0; done <<< "$all"
  return 1
}

# roost_resume__dup PANE ID -> 0 and ROOST_RESUME_HOLDER=%M when ANOTHER live
# pane on this server carries ID in its own @roost-session (§4.1 step 5): one
# conversation is never open in two panes. PANE is exempt — the in-place
# target, which step 7 ends before the resume starts — and empty for none.
# Pane scope is read per pane with show-options, for roost_resume__opt's
# reason; a pane carrying no id costs one call, so the listing first narrows
# to the panes whose format value (which may fall back) holds the id at all.
roost_resume__dup() {
  local all p v
  ROOST_RESUME_HOLDER=""
  all="$(roost_resume__t list-panes -a -F '#{pane_id} #{@roost-session}' 2>/dev/null)" || return 1
  while read -r p v; do
    [ "$v" = "$2" ] || continue
    [ "$p" = "$1" ] && continue
    roost_resume__opt "$p" @roost-session || continue
    [ "$ROOST_RESUME_V" = "$2" ] || continue
    ROOST_RESUME_HOLDER="$p"
    return 0
  done <<< "$all"
  return 1
}

# The options the old process owned, cleared before a respawn (§4.1 step 7):
# `respawn-pane` keeps pane options (§2.7), and a resume into a trust dialog
# fires no hook that would overwrite an old `done` — so without this the pane
# would read as the old agent's last turn, under the old identity, while the
# new one sits in a dialog. The identity four; @agent_state; the reply, turn,
# dialog and background options roost-agent-state and roost-unblock.sh write
# (the set roost_unblock_pane clears when a turn is abandoned); the job the
# hook recorded. @roost-name is KEPT: it is the person's name for the pane.
# @agent_since and @roost-turn-reserved are kept too: the badge's stamp, and a
# turn number already promised to a `send` (roost-record.sh, line "the release
# writes @roost-turn-reserved"), are not the old process's to take away.
ROOST_RESUME_CLEAR="@roost-session @roost-cwd @roost-harness @roost-transcript-path @agent_state @roost-reply @roost-reply-turn @roost-transcript @roost-blocked-on @roost-stop-swallowed @roost-dialog @roost-answered @roost-answer-nonce @roost-background @roost-background-types @roost-background-session @roost-agent-job"

# roost_resume__record_get FILE -> ROOST_RESUME_V, the first line of one
# record file, cleaned; empty when it is missing or holds a control byte.
roost_resume__record_get() {
  local v=""
  ROOST_RESUME_V=""
  [ -f "$1" ] || return 0
  IFS= read -r v < "$1" 2>/dev/null || true
  roost_shape__clean "$v" octal || return 0
  ROOST_RESUME_V="$ROOST_SHAPE_V"
}

# roost_resume__home_session PANE -> prints the session a gone pane's new
# window goes into (§4.1 step 7): the record's reserved `session` when it is
# written and still exists, else the caller's own session when the caller is
# a pane on this server, else `main` (bin/roost's DEFAULT_SESSION) when it
# exists, else the first session tmux lists. A session that does not exist is
# never made: a revive does not start sessions.
roost_resume__home_session() {
  local s
  s="${1:-}"
  if [ -n "$s" ] && roost_resume__t has-session -t "=$s" 2>/dev/null; then printf '%s
' "$s"; return 0; fi
  if [ -n "${TMUX_PANE:-}" ] && s="$(roost_resume__t display -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)" && [ -n "$s" ]; then
    printf '%s
' "$s"; return 0
  fi
  if roost_resume__t has-session -t "=${DEFAULT_SESSION:-main}" 2>/dev/null; then printf '%s
' "${DEFAULT_SESSION:-main}"; return 0; fi
  roost_resume__t list-sessions -F '#{session_name}' 2>/dev/null | head -n 1
}

# roost_resume__fg_is HARNESS COMMAND — the foreground COMMAND can be this
# harness itself. roost_close_harness's names (Claude's version string, the
# five names), plus the two that table cannot claim because they are not
# distinctive: pi runs as `node` (probe 1.6), and opencode — not measured —
# as `node` or `bun` besides its own name. A shell running one of those for
# this harness is the agent at work, judged by the table; a shell running
# anything else is a person's job.
roost_resume__fg_is() {
  roost_close_harness "" "$2" ""
  [ "$ROOST_CLOSE_HARNESS" = "$1" ] && return 0
  case "$1:$2" in
    pi:node|opencode:node|opencode:bun) return 0 ;;
  esac
  return 1
}

# roost_revive RAW TGT FORCE JSON NEWWIN — the verb. Returns its exit code:
#   0  launched (NOT resumed: §4.1 step 8 — roost does not wait for the
#      harness's prompt and answers nothing it opens)
#   1  refused by step 7's checks (a working or blocked agent, a shell running
#      a person's job), or tmux failed
#   2  the target is gone and nothing records it
#  13  not resumed, the reason printed: no key, a stale key, the store does
#      not hold it, another pane holds it, opencode (printed, not run)
#  14  the harness is not on PATH
#  15  the directory is gone
#
# THREE WAYS IT LAUNCHES (§4.1 step 7):
#   in place     a live pane: its process is ended and the resume respawned
#                in it, the same %N
#   gone         a %N that is gone, on this boot, whose pane record (#74)
#                still names its harness and id: a new window, `@roost-was
#                %OLD` on its pane
#   --new-window a live pane, left running: a new window beside it. With no
#                exemption from step 5 — the target keeps running, so its own
#                key counts as another owner — which is 13 for any pane whose
#                key is its own @roost-session (Part 3's pending record is the
#                case this exists for)
# Needs ROOST_RESUME_TFLAG / ROOST_RESUME_TSOCK and ROOST_HOME; `t`,
# `pane_cmd_wired`, `roost_unblock_pane` and `record_for` come from bin/roost.
roost_revive() {
  local raw="$1" tgt="$2" force="$3" json="$4" newwin="${5:-0}"
  local pane panes n h sid scwd tr pcwd cmd ppid dead state agree dir rc
  local sd boot claim="" kid kids o mode=place rsess="" rname="" exempt new sess
  local -a argv clear
  ROOST_SHAPE_TFLAG="$ROOST_RESUME_TFLAG" ROOST_SHAPE_TSOCK="$ROOST_RESUME_TSOCK"
  if ! roost_shape__read_rules; then
    echo "roost revive: no roost server is running" >&2; return 1
  fi
  # Step 1: one pane. A window with more than one pane is refused, `close`'s
  # rule: guessing its active pane would replace the wrong agent.
  case "$tgt" in
    %*) pane="$tgt" ;;
    *)
      panes="$(roost_resume__t list-panes -t "$tgt" -F '#{pane_id}' 2>/dev/null || true)"
      if [ -z "$panes" ]; then
        echo "roost revive: '$raw' is gone: no such pane or window" >&2; return 2
      fi
      case "$panes" in
        *$'\n'*)
          n="$(printf '%s\n' "$panes" | grep -c .)"
          echo "roost revive: '$raw' names a window with $n panes, and revive takes one — pass the %N of the pane (roost status lists them)" >&2
          return 1 ;;
      esac
      pane="$panes" ;;
  esac
  if ! roost_resume__row "$pane"; then
    # A gone pane: only a %N can name one (a window id or name of a window
    # that is gone names no pane), and only on this boot (pane ids restart at
    # %0, so a %N of an earlier boot is another pane — record_for's rule).
    case "$pane" in %[0-9]*) ;; *)
      echo "roost revive: '$raw' is gone: no such pane or window" >&2; return 2 ;;
    esac
    if ! record_for "$pane" "$pane" || [ "$RF_STATE" != 0 ]; then
      [ "${RF_STATE:-1}" -ge 2 ] && record_warn revive "$raw"
      echo "roost revive: '$raw' is gone, and no record of it is kept on this boot" >&2; return 2
    fi
    mode=gone
    roost_resume__record_get "$RF_DIR/harness"; h="$ROOST_RESUME_V"
    roost_resume__record_get "$RF_DIR/session_id"; sid="$ROOST_RESUME_V"
    roost_resume__record_get "$RF_DIR/cwd"; scwd="$ROOST_RESUME_V"
    roost_resume__record_get "$RF_DIR/transcript"; tr="$ROOST_RESUME_V"
    # The reserved `session` and `name` (§1), read when a later part writes
    # them; today they are absent and the fallbacks below apply.
    roost_resume__record_get "$RF_DIR/session"; rsess="$ROOST_RESUME_V"
    roost_resume__record_get "$RF_DIR/name"; rname="$ROOST_RESUME_V"
    pcwd="" cmd="" ppid="" dead=0 state=""
  fi
  [ "$mode" = place ] && [ "$newwin" = 1 ] && mode=newwin
  if [ "$mode" != gone ]; then
    roost_resume__opt "$pane" @roost-harness; h="$ROOST_RESUME_V"
    roost_resume__opt "$pane" @roost-session; sid="$ROOST_RESUME_V"
    roost_resume__opt "$pane" @roost-cwd; scwd="$ROOST_RESUME_V"
    roost_resume__opt "$pane" @roost-transcript-path; tr="$ROOST_RESUME_V"
    roost_resume__opt "$pane" @agent_state; state="$ROOST_RESUME_V"
    roost_resume__fmt "$pane" '#{pane_current_path}'; pcwd="$ROOST_RESUME_V"
    roost_resume__fmt "$pane" '#{pane_current_command}'; cmd="$ROOST_RESUME_V"
    roost_resume__fmt "$pane" '#{pane_pid}'; ppid="$ROOST_RESUME_V"
    roost_resume__fmt "$pane" '#{pane_dead}'; dead="$ROOST_RESUME_V"
    roost_resume__opt "$pane" @roost-name; rname="$ROOST_RESUME_V"
    rsess="$(roost_resume__t display -p -t "$pane" '#{session_name}' 2>/dev/null || true)"
  fi

  # Step 2: does the identity agree with what the pane runs (§3.2's rule,
  # roost_shape_agree)? A dead pane (remain-on-exit: an earlier revive whose
  # resume exited non-zero) runs nothing, so there is nothing to disagree;
  # its last screen said why, and this revive replaces it.
  #
  # One addition to §3.2's table, for a SHELL pane: #{pane_current_command}
  # names the foreground job, so a shell running `sleep 60` reads `sleep`,
  # which the table calls `other` (13, nothing anyone can do). But the agent
  # has left and a person is using the shell — §4.1 step 7's case, "a shell
  # pane whose shell has a child process", refused with exit 1 and replaced
  # under --force. So when the pane's OWN process (#{pane_pid}) is a shell and
  # the foreground is not a harness, the pane is `exited` and step 7's shell
  # check decides. A harness in the foreground (a person typed `claude` at
  # the prompt) is still judged by the table: ok or nested. `other` is left
  # for a pane whose own process is neither — an editor or a `sleep` started
  # as the pane's command.
  #
  # The pane's own process is asked FIRST, for every harness (review round 1,
  # Codex B2): asked only after the table said `other`, it never ran for pi
  # and opencode, which the table admits on presence alone — a shell left by
  # pi and running `sleep 600` read `ok`, and the person's job was killed
  # without --force. For a shell-owned pane: the foreground is this harness
  # (roost_resume__fg_is) → the table decides (ok); another harness's
  # distinctive command → the table decides (nested); anything else → exited,
  # and step 7's shell check decides.
  agree=dead
  [ "$mode" = gone ] && agree=gone
  if [ "$mode" != gone ] && [ "$dead" != 1 ] && [ -n "$h" ]; then
    o="$(ps -o comm= -p "$ppid" 2>/dev/null || true)"
    o="${o##*/}"; o="${o#-}"; o="${o%% *}"
    case "$o" in
      sh|bash|zsh|fish|dash)
        roost_close_harness "" "$cmd" ""
        if roost_resume__fg_is "$h" "$cmd" || [ -n "$ROOST_CLOSE_HARNESS" ]; then
          agree="$(roost_shape_agree "$h" "$cmd")"
        else
          agree=exited
        fi ;;
      *) agree="$(roost_shape_agree "$h" "$cmd")" ;;
    esac
  fi
  case "$agree" in
    nested|other)
      echo "roost revive: '$raw' runs '$cmd', not $h: its $h key ${sid:-(none)} is stale — nothing resumed" >&2
      return 13 ;;
  esac
  if [ -z "$h" ] || [ -z "$sid" ]; then
    if [ -n "$h" ]; then
      echo "roost revive: '$raw' has no recorded conversation (harness $h, no session id)" >&2
    else
      echo "roost revive: '$raw' has no recorded conversation (no harness, no session id)" >&2
    fi
    return 13
  fi
  rc=0; roost_resume_command "$h" "$sid" "$tr" >/dev/null || rc=$?
  if [ "$rc" != 0 ] && [ "$rc" != 3 ]; then
    echo "roost revive: '$raw': $ROOST_RESUME_WHY — nothing resumed" >&2; return 13
  fi
  # Step 3.
  if ! command -v "$h" >/dev/null 2>&1; then
    echo "roost revive: '$raw' ran $h, and $h is not on PATH — nothing resumed" >&2; return 14
  fi
  # Step 4 (§5.1). A Claude or pi pane whose transcript option is unset gets
  # the exact-id lookup, the one store file whose NAME carries the id (§4.1
  # step 1): the key's own file, not a guess.
  #
  # A recorded transcript that no longer exists gets the same lookup: Claude
  # deletes a transcript after 30 days, and a person may delete one. Found by
  # the live smoke (tests/live/revive-smoke.sh): a deleted transcript reached
  # step 4 as "names no usable directory" instead of the store miss it is.
  if [ -z "$tr" ] || [ ! -f "$tr" ]; then
    case "$h" in claude|pi) tr="$(roost_resume_exact_id "$h" "$sid" || true)" ;; esac
  fi
  # A Claude pane with no transcript recorded and none in the store under its
  # id: that is the store check's miss (step 5) reached early — Claude's
  # directory comes from the transcript, so there is nothing to choose from —
  # and it is said in step 5's words.
  if [ "$h" = claude ] && [ -z "$tr" ]; then
    echo "roost revive: $h no longer holds $sid; the pane is untouched" >&2; return 13
  fi
  if ! roost_resume_dir "$h" "$tr" "$scwd" "$pcwd" >/dev/null; then
    echo "roost revive: '$raw': $ROOST_RESUME_WHY — $h $sid not resumed" >&2; return 13
  fi
  dir="$ROOST_RESUME_DIR"
  if [ ! -d "$dir" ]; then
    echo "roost revive: '$raw': directory $dir no longer exists; not resuming elsewhere" >&2; return 15
  fi
  # Step 5 (§5.1a): the store, then another live pane carrying the key.
  rc=0; roost_resume_store_check "$h" "$sid" "$tr" || rc=$?
  if [ "$rc" = 3 ]; then
    argv=(); while IFS= read -r o; do argv+=("$o"); done < <(roost_resume_command "$h" "$sid" "$tr")
    echo "roost revive: '$raw': opencode resume is not checked (it creates a session it does not find); run: cd $(roost_sq "$dir") && ${argv[*]}" >&2
    return 13
  fi
  if [ "$rc" != 0 ]; then
    echo "roost revive: $h no longer holds $sid; the pane is untouched" >&2; return 13
  fi
  # The target itself is exempt only in place: there step 7 ends its process
  # before the resume starts. With --new-window it keeps running.
  exempt=""; [ "$mode" = place ] && exempt="$pane"
  if roost_resume__dup "$exempt" "$sid"; then
    echo "roost revive: $h $sid is open in $ROOST_RESUME_HOLDER; one conversation is never open in two panes — nothing resumed" >&2
    return 13
  fi
  # Step 5a: claim, before anything is launched — always, saving on or off
  # (roost_resume_claims_dir says where, and why there is no exemption).
  boot="$(roost_resume__t display -p '#{start_time}-#{pid}' 2>/dev/null || true)"
  if [ -z "$boot" ]; then
    echo "roost revive: cannot read the server's boot key, so no launch claim can be taken — nothing resumed" >&2
    return 1
  fi
  if ! roost_resume_claims_dir "$ROOST_RESUME_TFLAG" "$ROOST_RESUME_TSOCK" "$boot" >/dev/null; then
    echo "roost revive: no launch claim can be taken: $ROOST_RESUME_WHY — nothing resumed" >&2
    return 1
  fi
  # In place the claim names the pane now; a new window's pane is named
  # once `new-window` has made it (roost_resume_claim_pane, below).
  sd="$ROOST_RESUME_CLAIMS"
  rc=0; roost_resume_claim "$sd" "$h" "$sid" "$exempt" || rc=$?
  case "$rc" in
    0) claim="$ROOST_RESUME_CLAIM" ;;
    1) echo "roost revive: $h $sid is already being launched in $ROOST_RESUME_HOLDER — nothing resumed" >&2; return 13 ;;
    *) echo "roost revive: cannot claim $h $sid: $ROOST_RESUME_HOLDER" >&2; return 1 ;;
  esac
  # The plan's seam (its table, ROOST_TEST_REVIVE_HOLD): hold here, after the
  # claim and before step 7, so a test can change the pane in between.
  roost_shape__seam ROOST_TEST_REVIVE_HOLD
  # Step 7's checks, from here on every refusal releases this run's claim.
  # Only in place: a gone pane runs nothing, and --new-window leaves the
  # target running.
  #
  # READ AGAIN HERE, not at the start (review round 1, Codex B3): between the
  # first read and this point revive checked the PATH, the store, every other
  # pane and took its claim, and an agent that started a turn meanwhile was
  # replaced without --force on the strength of an `idle` read long before.
  # So the badge, the pane's process and its foreground are read again now;
  # a process or foreground that changed is a pane that is no longer the one
  # judged, refused like a busy one. What remains is the instant between this
  # read and the respawn, which no check can close.
  if [ "$mode" = place ]; then
    o="$dead|$ppid|$cmd"
    roost_resume__opt "$pane" @agent_state; state="$ROOST_RESUME_V"
    roost_resume__fmt "$pane" '#{pane_dead}'; dead="$ROOST_RESUME_V"
    roost_resume__fmt "$pane" '#{pane_pid}'; ppid="$ROOST_RESUME_V"
    roost_resume__fmt "$pane" '#{pane_current_command}'; cmd="$ROOST_RESUME_V"
    if [ "$o" != "$dead|$ppid|$cmd" ] && [ "$force" != 1 ]; then
      roost_resume_release "$claim"
      echo "roost revive: '$raw' changed while revive checked it (now running '$cmd') — nothing resumed; run it again, or pass --force" >&2
      return 1
    fi
  fi
  if [ "$mode" = place ] && [ "$dead" != 1 ]; then
    case "$state" in
      working|blocked)
        if [ "$state" = blocked ] && roost_unblock_pane "$pane"; then
          :
        elif [ "$force" != 1 ]; then
          roost_resume_release "$claim"
          echo "roost revive: '$raw' is $state — replacing it now would end its agent mid-turn; wait for it, or pass --force" >&2
          return 1
        fi ;;
    esac
    # A shell pane whose shell has a child is running a person's job.
    if [ "$agree" = exited ] && [ "$force" != 1 ]; then
      kids="$(pgrep -P "$ppid" 2>/dev/null || true)"
      if [ -n "$kids" ]; then
        kid="$(ps -o comm= -p "${kids%%$'\n'*}" 2>/dev/null | sed 's/^ *//' || true)"
        roost_resume_release "$claim"
        echo "roost revive: '$raw' is a shell running ${kid:-a job}; that is a person's work — pass --force to replace it" >&2
        return 1
      fi
    fi
  fi
  # Step 6: the argv, never a string for a shell; through roost-pane-shell on
  # a wired server, so roost's claude shim is first on PATH (#58).
  # The harness's home goes with it (roost_resume_env_argv): the store just
  # checked is the store it is launched with.
  argv=(); while IFS= read -r o; do argv+=("$o"); done < <(roost_resume_env_argv "$h"; roost_resume_command "$h" "$sid" "$tr")
  if pane_cmd_wired; then argv=("$ROOST_HOME/scripts/roost-pane-shell" "${argv[@]}"); fi
  if [ "$mode" != place ]; then
    # A new window, `new-window -d` so no client's focus moves, in the old
    # pane's session (roost_resume__home_session). Made holding a `sleep`,
    # then given `remain-on-exit failed`, then respawned with the resume: set
    # on a pane already running the resume, the option would come too late
    # for a resume that exits non-zero at once — the case it is the net for.
    sess="$(roost_resume__home_session "$rsess")"
    if [ -z "$sess" ] || ! new="$(roost_resume__t new-window -d -P -F '#{pane_id}' -t "=$sess:" -c "$dir" 'exec sleep 60' 2>/dev/null)" || [ -z "$new" ]; then
      roost_resume_release "$claim"
      echo "roost revive: tmux could not open a window for '$raw'" >&2
      return 1
    fi
    if [ -n "$claim" ] && ! roost_resume_claim_pane "$claim" "$new"; then
      # Another launcher took the claim over: it launches, this one does not.
      roost_resume__t kill-pane -t "$new" 2>/dev/null || true
      echo "roost revive: $h $sid was claimed by another launcher meanwhile — nothing resumed" >&2
      return 13
    fi
    roost_resume__t set-option -p -t "$new" remain-on-exit failed 2>/dev/null || true
    roost_resume__t set-option -p -t "$new" @roost-was "$pane" 2>/dev/null || true
    [ -n "$rname" ] && { roost_resume__t set-option -p -t "$new" @roost-name "$rname" 2>/dev/null || true; }
    if ! roost_resume__t respawn-pane -k -t "$new" -c "$dir" "${argv[@]}" 2>/dev/null; then
      roost_resume__t kill-pane -t "$new" 2>/dev/null || true
      roost_resume_release "$claim"
      echo "roost revive: tmux could not start the resume for '$raw'" >&2
      return 1
    fi
  else
    # Step 7: clear, keep the pane on a failed exit, respawn with the command
    # always passed (a bare respawn-pane re-runs the pane's creation command,
    # §1). `-k` ends what runs there; the pane keeps its %N (§2.7).
    new="$pane"
    if [ -n "$claim" ] && ! roost_resume_claim_held "$claim"; then
      echo "roost revive: $h $sid was claimed by another launcher meanwhile — the pane is untouched" >&2
      return 13
    fi
    clear=()
    for o in $ROOST_RESUME_CLEAR; do clear+=(set-option -pu -t "$pane" "$o" ';'); done
    # One tmux call for all of them; the list ends in a no-op so the last `;`
    # has a command after it.
    roost_resume__t "${clear[@]}" display -p -t "$pane" '' >/dev/null 2>&1 || true
    # Its own call, as restore sets it: a tmux that refuses `failed`
    # refuses only this, and the resume still runs, without the net.
    roost_resume__t set-option -p -t "$pane" remain-on-exit failed 2>/dev/null || true
    if ! roost_resume__t respawn-pane -k -t "$pane" -c "$dir" "${argv[@]}" 2>/dev/null; then
      roost_resume_release "$claim"
      echo "roost revive: tmux could not respawn '$raw'" >&2
      return 1
    fi
  fi
  # Step 8.
  argv=(); while IFS= read -r o; do argv+=("$o"); done < <(roost_resume_command "$h" "$sid" "$tr")
  if [ "$json" = 1 ]; then
    . "$ROOST_HOME/scripts/lib/roost-jsonout.sh"
    roost_jsonout_emit revive pane s "$new" was s "$pane" harness s "$h" \
      session_id s "$sid" command s "${argv[*]}" cwd s "$dir" || roost_jsonout_fail revive
  else
    printf '%s\n' "$new"
  fi
  if [ "$new" = "$pane" ]; then
    echo "roost revive: $new: launched ${argv[*]} in $dir" >&2
  else
    echo "roost revive: $new (was $pane): launched ${argv[*]} in $dir" >&2
  fi
  return 0
}
