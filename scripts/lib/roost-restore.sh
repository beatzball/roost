# roost-restore.sh — putting a saved shape back (#51, #191): `roost restore`.
#
# Sourced by bin/roost's `restore` arm, after scripts/lib/roost-shape.sh. It
# uses bin/roost's own `t`, `server_running`, `server_init`, `CONF`,
# `ROOST_HOME`, `_SOCKET_FLAG` and `SOCKET`, so restore drives exactly the
# server every other verb drives and starts it exactly as ensure_session does.
# The design is docs/airig/specs/2026-10-24-persistent-sessions-design.md §4.3
# (placement), §4.7 (the placeholder and who owns a pane), §3.5 (the owner
# rule); every rule below names its section.
#
# Every tmux READ here passes `-u` (`t -u display-message`, `t -u list-*`,
# `t -u show-options`): the client otherwise prints control and non-ASCII
# bytes as `_` under a C or unset locale, and a session name, a start command
# or default-command would compare wrong (scripts/lib/roost-shape.sh,
# roost_shape__t, says what was measured).
#
# In Part 1 restore PLACED ONLY: every pane came back as a shell in its saved
# directory, and a pane's agent key stayed in the shape for Part 3. From Part
# 3 (Task 3.3) a pane that will be resumed gets its pending record
# (scripts/lib/roost-pending.sh, §4.6) and waits in a placeholder instead of
# a shell (roost_restore__respawn).
#
# roost-pending.sh is sourced by path, relative to this file, the way
# roost-shape.sh sources roost-close.sh: it only defines functions.
. "$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/roost-pending.sh"
#
# HOW A PANE IS PLACED (§4.3, §4.7 arrows T1–T4). Restore never creates a
# shell it might later have to replace: a person may attach with a bare
# `tmux attach` while restore works and start a build in it. So it writes a
# file F under `restoring/` FIRST, then creates the pane running
# scripts/roost-placeholder F --placing (T1). Then the per-pane step races the
# placeholder for F with one rename: restore's `mv F F.used` (T2) against a
# person's first key, `mv F F.taken` (T4). The winner owns the pane.

# roost_restore__unvis NAME -> prints NAME with tmux's own escaping of a
# session name undone, so `new-session -s` stores it back exactly.
#
# Ruling R8.3, measured on tmux 3.2a, 3.4 and 3.6 (Task 1.12): tmux rewrites a
# session name it is given — a backslash becomes `\\`, a `$` becomes `\$` on
# 3.2a and 3.4, a tab `\t`, ESC `\033` — and the saved name is that stored
# form. Handed back unchanged it would be escaped again and grow at every
# save and restore (`a\b` → `a\\b` → `a\\\\b`). Undoing exactly that
# escaping (`\\` `\$` `\t` `\n` `\NNN`) gave the same stored name over two
# cycles on all three builds, for every name tried.
#
# A WINDOW name was the opposite case up to tmux 3.6: `new-window -n` stores
# what it is given (3.4 escapes only a raw control byte, which a saved name
# cannot hold), so the saved name is passed as it is — measured exact on all
# three builds; undoing it there made it drift. From tmux 3.7 (CHANGES; measured
# on 3.8, docs/airig/probes/persist-1-tmux38.md) a window name is escaped
# like a session name, and passed as saved it grew at every cycle.
# roost_restore__window_name tells the two apart on the window itself.
# roost_restore__window_name WID SAVED — a window made with `-n SAVED` is
# read back. The same name: this tmux stores a window name as given, and it
# is left. Another name: this tmux escaped it (3.7 on), so the window is
# renamed with that escaping undone, which this tmux stores as SAVED. Asked
# of each named window rather than of the version, because it is one read
# and it measures the thing itself. The read gets R6's correction, as every
# read does.
roost_restore__window_name() {
  local u
  roost_shape__clean "$(t -u display-message -p -t "$1" '#{window_name}' 2>/dev/null || true)" || true
  [ "$ROOST_SHAPE_V" = "$2" ] && return 0
  u="$(roost_restore__unvis "$2")"
  [ "$u" != "$2" ] || return 0
  t rename-window -t "$1" "$u" 2>/dev/null || true
}

roost_restore__unvis() {
  local s="$1" out="" d o
  while [ -n "$s" ]; do
    case "$s" in
      \\*)
        d="${s:1:1}"
        case "$d" in
          \\) out="$out\\"; s="${s:2}" ;;
          \$) out="$out\$"; s="${s:2}" ;;
          t) out="$out"$'\t'; s="${s:2}" ;;
          n) out="$out"$'\n'; s="${s:2}" ;;
          [0-7])
            o="${s:1:3}"
            case "$o" in
              [0-7][0-7][0-7]) out="$out$(printf "\\$o")"; s="${s:4}" ;;
              *) out="$out\\"; s="${s:1}" ;;
            esac ;;
          *) out="$out\\"; s="${s:1}" ;;
        esac ;;
      *) out="$out${s:0:1}"; s="${s:1}" ;;
    esac
  done
  printf '%s' "$out"
}

# roost_restore__hold VAR — a test seam: while the file the variable names
# does not exist, wait. Read only when set (the plan's seams table). Bounded,
# so a test that forgot to release it cannot hang a run for ever.
roost_restore__hold() {
  local f i=0
  eval "f=\${$1:-}"
  [ -n "$f" ] || return 0
  while [ ! -e "$f" ] && [ "$i" -lt 1200 ]; do sleep 0.1; i=$((i + 1)); done
}

# roost_restore__names -> ROOST_RESTORE_NAMES, the server's session names as
# tmux stores them, one per line between newlines, R6-corrected (tmux 3.4
# prints `$` as `\$`), so a saved name compares byte for byte.
roost_restore__names() {
  local n
  ROOST_RESTORE_NAMES=$'\n'
  while IFS= read -r n; do
    roost_shape__clean "$n" || true
    ROOST_RESTORE_NAMES="$ROOST_RESTORE_NAMES$ROOST_SHAPE_V"$'\n'
  done <<< "$(t -u list-sessions -F '#{session_name}' 2>/dev/null || true)"
  # The names are this server's, and so is the rule for reading them: learned
  # again with each listing, so a server the bootstrap started is asked too.
  roost_restore__learn_dots
}

# roost_restore__stored NAME -> prints the name tmux stores for a saved
# session NAME. Up to tmux 3.6, `.` and `:` are stored as `_` (probe 1.4),
# so a hand-edited `v3.69-x` is the session `v3_69-x`. tmux 3.7 refuses
# them: `new-session -s v3.69-x` fails, "invalid session name" (measured on
# 3.7 built from its release tarball, review round 6). From 3.7a both are
# kept (CHANGES 3.7 -> 3.7a; 3.7a measured in review round 5, 3.8 here,
# docs/airig/probes/persist-1-tmux38.md),
# and `v3.69-x` and `v3_69-x` are two sessions. On every build that does
# not keep them, restore makes the session under this `_` form
# (roost_restore__made), so 3.7 makes it too. The rule is the server's
# version, read once: a test session made only to see how its name is stored
# would run a person's session-created hooks. Learned by
# roost_restore__learn_dots, in the caller's own shell: this one runs inside
# $(...), where a value it set would be lost.
roost_restore__stored() {
  [ -n "${ROOST_RESTORE_MAPDOTS:-}" ] || roost_restore__learn_dots
  if [ "$ROOST_RESTORE_MAPDOTS" = 1 ]; then
    local m="${1//./_}"
    printf '%s' "${m//:/_}"
  else
    printf '%s' "$1"
  fi
}

# roost_restore__learn_dots -> ROOST_RESTORE_MAPDOTS, 1 when this server
# stores `.` and `:` in a session name as `_` (roost_restore__stored).
#
# Only a version known to be 3.7a or later keeps them: a release (`3.7a`,
# `3.8`, `3.8-rc2`, `3.10`, `4.0`) or a git build after 3.7 (`next-3.8`,
# `master`). A release up to 3.7, `next-3.7` and older, and anything else
# keep the old rule, which held for every build before the change: OpenBSD's
# own tmux prints `openbsd-` and the OS release, and its 7.6 maps the dots
# (review round 5, Codex B2); roost does not support such a build (doctor
# refuses it). A server not yet running prints nothing: then the version is
# the tmux binary's own (`tmux -V`), which is the one the bootstrap starts the
# server with, so the bootstrap session is made under the right name too. It
# is asked again after the bootstrap starts it (roost_restore__names).
roost_restore__learn_dots() {
  local v
  v="$(t -u display-message -p '#{version}' 2>/dev/null || true)"
  [ -n "$v" ] || { v="$(t -V 2>/dev/null || true)"; v="${v#tmux }"; }
  case "$v" in
    3.7[a-z]*|3.[89]*|3.[1-9][0-9]*|[4-9].*|[1-9][0-9]*.*|next-3.[89]*|next-3.[1-9][0-9]*|next-[4-9].*|next-[1-9][0-9]*.*|master)
      ROOST_RESTORE_MAPDOTS=0 ;;
    *) ROOST_RESTORE_MAPDOTS=1 ;;
  esac
}

# roost_restore__made NAME -> prints the name `new-session -s` is given for
# a saved session NAME: tmux's escaping undone (roost_restore__unvis), and
# `.` and `:` as `_` where this tmux does not keep them
# (roost_restore__stored): 3.7 refuses a dotted name, and up to 3.6 tmux
# stores the `_` form anyway (review round 6, Fable N1).
roost_restore__made() {
  roost_restore__stored "$(roost_restore__unvis "$1")"
}

# roost_restore__exists NAME -> exit 0 when a session of that saved name is on
# the server: by the name itself, and by the name tmux would store for it
# (roost_restore__stored), so a dotted name is never made a second time.
roost_restore__exists() {
  local m
  m="$(roost_restore__stored "$1")"
  case "$ROOST_RESTORE_NAMES" in *$'\n'"$1"$'\n'*|*$'\n'"$m"$'\n'*) return 0 ;; esac
  return 1
}

# roost_restore__sid NAME -> prints the id of the session of that saved name.
# A target is never built from a saved name (probe 1.4: `=NAME:INDEX` falls
# back to a window NAMED like the index when the index is missing); every
# target after this is the id.
roost_restore__sid() {
  local id n m
  m="$(roost_restore__stored "$1")"
  # Split at the FIRST space by hand: `read id n` would trim a name's own
  # leading and trailing spaces, and a group's first member named ` lead `
  # was then never found (review round 1, Codex B6).
  local line
  while IFS= read -r line; do
    id="${line%% *}" n="${line#* }"
    roost_shape__clean "$n" || true
    if [ "$ROOST_SHAPE_V" = "$1" ] || [ "$ROOST_SHAPE_V" = "$m" ]; then printf '%s\n' "$id"; return 0; fi
  done <<< "$(t -u list-sessions -F '#{session_id} #{session_name}' 2>/dev/null || true)"
  return 1
}

# roost_restore__addr BLOCKFILE -> the address on the block's first line.
roost_restore__addr() { local l; IFS= read -r l < "$1"; printf '%s\n' "${l#* }"; }

# roost_restore__windows SESSION -> the session's window block files, in file
# order (the order save wrote: by index).
roost_restore__windows() {
  local f a
  for f in "$ROOST_RESTORE_PD"/*.window; do
    [ -e "$f" ] || continue
    a="$(roost_restore__addr "$f")"
    [ "${a%:*}" = "$1" ] && printf '%s\n' "$f"
  done
}

# roost_restore__panes SESSION:INDEX -> the window's pane block files, in order.
roost_restore__panes() {
  local f a
  for f in "$ROOST_RESTORE_PD"/*.pane; do
    [ -e "$f" ] || continue
    a="$(roost_restore__addr "$f")"
    [ "${a%.*}" = "$1" ] && printf '%s\n' "$f"
  done
}

# roost_restore__size SESSION -> "W H", the largest root cell of the
# session's saved layouts. A detached server is otherwise 80x24, and a window
# of six stacked panes cannot be built in 24 lines (§2.7).
#
# A layout is in one of two forms, the one its tmux prints
# (docs/airig/probes/persist-1-tmux38.md): `CSUM,WxH,X,Y...` up to 3.7, and
# from 3.8 JSON, `{"V":2,"L":{"t":"h","w":200,"h":50,...}}`, whose first
# "w" and "h" are the root cell's (tmux writes t, w, h, x, y first). Read
# only as the old form, a 3.8 layout gave no size and the session was made
# 80x24. select-layout still widens each window it builds to the saved
# size, and roost_restore__build_window's split rule fits 288 panes in
# 80x24, so that showed only in the session's default-size, which tmux
# takes from -x/-y: a window the person made before a client attached was
# 80x24 (measured on 3.6 and 3.8).
roost_restore__size() {
  local f l c w=0 h=0 cw ch
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    l="$(roost_shape_get "$f" layout)" || continue
    case "$l" in
      '{'*)
        cw="${l#*\"w\":}"; cw="${cw%%[!0-9]*}"
        ch="${l#*\"h\":}"; ch="${ch%%[!0-9]*}" ;;
      *)
        c="${l#*,}"; c="${c%%,*}"
        cw="${c%x*}" ch="${c#*x}" ;;
    esac
    case "$cw$ch" in ''|*[!0-9]*) continue ;; esac
    [ "$cw" -gt "$w" ] && w="$cw"
    [ "$ch" -gt "$h" ] && h="$ch"
  done <<< "$(roost_restore__windows "$1")"
  # No readable layout at all: tmux's own detached default.
  [ "$w" -gt 0 ] && [ "$h" -gt 0 ] || { w=80 h=24; }
  printf '%s %s\n' "$w" "$h"
}

# roost_restore__cwd BLOCKFILE -> the pane's saved directory, or the home
# directory with one stderr line when it is gone (§4.3 Directories; §8.1 test
# 3a). Such a pane is never resumed (Part 3).
roost_restore__cwd() {
  local d
  d="$(roost_shape_get "$1" cwd)"
  if [ -d "$d" ]; then printf '%s\n' "$d"; return 0; fi
  printf 'roost restore: pane %s: directory %s is gone; a shell in the home directory\n' \
    "$(roost_restore__addr "$1")" "$d" >&2
  printf '%s\n' "${HOME:-/}"
}

# roost_restore__new_file -> ROOST_RESTORE_F, a fresh
# restoring/place.<run>.<n>, made. SETS rather than prints: the counter has
# to move in the caller's shell, and a $(...) would count in a subshell and
# hand every pane the same file (measured: every split pane got place.1, and
# only one could win it).
#
# <run> is this run's token (ROOST_RESTORE_RUN). A shell a key took keeps the
# placeholder's start command, which names its file, for as long as the pane
# lives; every run counted from place.1 again, so the next run's own place.1
# made its sweep take that old pane for one of its own and respawn it,
# killing what the person ran there (review round 2, Codex R2-B1). With the
# token, a pane's placing line can only ever match a file of the run that
# made it.
roost_restore__new_file() {
  ROOST_RESTORE_N=$((ROOST_RESTORE_N + 1))
  ROOST_RESTORE_F="$ROOST_RESTORE_RD/place.$ROOST_RESTORE_RUN.$ROOST_RESTORE_N"
  : > "$ROOST_RESTORE_F"
}

# roost_restore__shell_cmd -> sets ROOST_RESTORE_SHELL_ARGS (an array): the
# command a SHELL pane is respawned with. default-command's value as ONE
# string, ensure_session's form, read once after `roost wiring apply`: a bare
# `respawn-pane` re-runs the pane's creation command — the placeholder — and
# ignores default-command (measured on tmux 3.6). Empty (wiring off) →
# default-shell and `-l` as argv, what tmux runs for an empty default-command.
roost_restore__shell_cmd() {
  local dc ds bad=0
  dc="$(t -u show-options -gqv default-command 2>/dev/null || true)"
  # R6 for the person's own command too: tmux 3.4 prints `$` as `\$`, and a
  # `"$HOME/x"` read back raw stopped expanding (review round 1, Codex B7).
  # Needs this server's read rules (roost_shape__read_rules), which every
  # caller has learned by now. A control byte in it is kept: it is run, not
  # written to a file.
  roost_shape__clean "$dc" || true
  dc="$ROOST_SHAPE_V"
  # And for default-shell: read raw on 3.4, a path holding `$` named a file
  # that does not exist, and the respawned pane died at once (review round
  # 2, Codex R2-B3).
  ds="$(t -u show-options -gqv default-shell 2>/dev/null || true)"
  roost_shape__clean "$ds" || true
  ds="$ROOST_SHAPE_V"
  # A shell that cannot be run loses every pane restore respawns into it,
  # with nothing said: tmux checks default-shell only when it is set, and
  # the file can be gone since. Said once, and $SHELL (or /bin/sh) instead,
  # so the panes are kept (Codex R2-B3).
  if [ -n "$ds" ] && [ ! -x "$ds" ]; then
    printf 'roost restore: default-shell %s cannot be run; panes get %s instead\n' \
      "$ds" "$(roost_restore__fallback_shell)" >&2
    ds="" bad=1
  fi
  [ -n "$ds" ] || ds="$(roost_restore__fallback_shell)"
  if [ -n "$dc" ]; then
    # tmux runs a one-string command through default-shell -c: with that
    # shell unrunnable, the replacement runs it instead.
    if [ "$bad" = 1 ]; then ROOST_RESTORE_SHELL_ARGS=("$ds" -c "$dc")
    else ROOST_RESTORE_SHELL_ARGS=("$dc"); fi
    return 0
  fi
  ROOST_RESTORE_SHELL_ARGS=("$ds" -l)
}

# roost_restore__fallback_shell -> $SHELL when it can be run, else /bin/sh.
roost_restore__fallback_shell() {
  if [ -n "${SHELL:-}" ] && [ -x "$SHELL" ]; then printf '%s\n' "$SHELL"; else printf '/bin/sh\n'; fi
}

# roost_restore__placing STARTCOMMAND BASE -> exit 0 when a pane's start
# command is the placing placeholder for the file named BASE (`place.<run>.3`,
# `bootstrap.<run>`). tmux prints an argv command with double quotes round an
# argument that holds a space (measured, tmux 3.6), so quotes and backslashes
# are dropped before the compare, and the name must be followed by exactly
# ` --placing` at the end: `place.<run>.1` never matches `place.<run>.10`.
roost_restore__placing() {
  local sc="$1"
  sc="${sc//\"/}"; sc="${sc//\\/}"
  case "$sc" in *roost-placeholder*"/$2 --placing") return 0 ;; esac
  return 1
}

# roost_restore_place_pane PANE FILE CWD -> 0 placed; 1 lost the rename (a key
# took the pane: §4.7 placing, taken); 2 won but the pane had been changed by
# hand (T2, the person-owned row). In this order (§4.3 step 1, Task 1.12):
#   (i)   claim it: mv FILE FILE.used;
#   (ii)  the ROOST_TEST_PLACE_HOLD_AFTER_USED seam, right after the rename
#         and before any check, so a test can change the pane in the gap;
#   (iii) the pane must still run its placing line — a person who respawned
#         it with another command owns it: FILE.used → FILE.taken, no respawn;
#   (iv)  respawn it as a shell in CWD. remain-on-exit, set so a crashed
#         placeholder stays as a dead pane, is cleared first: a shell should
#         behave like any other.
#
# BLOCKFILE (a 4th argument) is the saved pane block placed into the pane:
# with it, a pane that will be resumed waits in a placeholder instead of a
# shell (roost_restore__respawn, T3).
roost_restore_place_pane() {
  roost_restore__claim "$1" "$2" || return $?
  roost_restore__respawn "$1" "$3" "${4:-}"
}

# roost_restore__claim PANE FILE -> steps (i)-(iii) of the per-pane step
# above: 0 claimed (FILE is FILE.used and the pane still runs its placing
# line), 1 lost, 2 changed by hand (now FILE.taken). The bootstrap pane is
# claimed on its own, before its window is built, because whether its
# session is replaceable rests on this rename (§4.3).
roost_restore__claim() {
  local sc
  mv "$2" "$2.used" 2>/dev/null || return 1
  roost_restore__hold ROOST_TEST_PLACE_HOLD_AFTER_USED
  sc="$(t -u display-message -p -t "$1" '#{pane_start_command}' 2>/dev/null || true)"
  if ! roost_restore__placing "$sc" "${2##*/}"; then
    mv "$2.used" "$2.taken" 2>/dev/null || true
    return 2
  fi
  return 0
}

# roost_restore__respawn_claimed PANE FILE CWD -> the respawn of a pane this
# run claimed EARLIER (FILE is FILE.used), with the claim's step (iii) done
# again right before it: 0 respawned; 2 the pane no longer runs its placing
# line — a person replaced it since — so FILE.used becomes FILE.taken and the
# pane is left. The bootstrap is claimed long before its respawn (before its
# window is built, and before its session's panes are counted), and both of
# its respawns go through here: without the second look, restore killed the
# person's process (review round 1, Codex B1; review round 2, Codex R2-B2,
# the split-session fallback).
#
# The bootstrap's first window name is put right here too, and only here:
# the one moment restore has just seen the pane still runs its placing line
# and is about to respawn it. ROOST_RESTORE_BOOT_NAME_PANE names that pane,
# set only once the bootstrap's claim won and its recheck passed; anywhere
# earlier, a person could have taken the pane since and named the window
# (review round 6, Codex R6-B1, before the claim; review round 7, Codex
# R7-B1, after it).
roost_restore__respawn_claimed() {
  if roost_restore__placing "$(t -u display-message -p -t "$1" '#{pane_start_command}' 2>/dev/null || true)" "${2##*/}"; then
    if [ -n "${ROOST_RESTORE_BOOT_NAME_PANE:-}" ] && [ "$1" = "$ROOST_RESTORE_BOOT_NAME_PANE" ]; then
      roost_restore__window_name "$ROOST_RESTORE_BOOT_NAME_WID" "$ROOST_RESTORE_BOOT_NAME"
    fi
    ROOST_RESTORE_BOOT_NAME_PANE=""
    roost_restore__respawn "$1" "$3" "${4:-}"
    return 0
  fi
  [ "$1" = "${ROOST_RESTORE_BOOT_NAME_PANE:-}" ] && ROOST_RESTORE_BOOT_NAME_PANE=""
  mv "$2.used" "$2.taken" 2>/dev/null || true
  return 2
}

# roost_restore__respawn PANE CWD [BLOCKFILE] -> step (iv): a shell in CWD,
# or — for a block that will be resumed — the waiting placeholder (T3).
#
# T3 (§4.7), the pending half (Task 3.3): a pane that will be resumed
# (roost_restore__will_resume: a key, not stale, its directory present, not
# --no-resume, not left out by --recent) gets its pending file written FIRST
# (§4.6), then `respawn-pane -k -c CWD <checkout>/scripts/roost-placeholder
# pending/<boot>/%N HARNESS` — by its own path, as argv, never through
# default-command (§2.10, revision 4 item 5) — so it waits in a placeholder,
# not a shell, until the resume loop or a person's key. remain-on-exit stays
# `failed` for it, as for every placeholder: one that crashes leaves a dead
# pane saying why (T13a), not a vanished one.
#
# A pending file that cannot be written leaves the pane a shell, with one
# stderr line: a placeholder with no file could never be freed by a key, and
# a resume with no record would be a launch nobody can see or stop.
roost_restore__respawn() {
  local f st
  # A pane whose agent was mid-turn at the save is named in the report: its
  # resume brings back the conversation, not the turn, so a person re-prompts
  # it (§4.3 Report). Collected here, printed by roost_restore_report_busy.
  if [ -n "${3:-}" ] && roost_shape_get "$3" harness >/dev/null 2>&1; then
    st="$(roost_shape_get "$3" state 2>/dev/null || true)"
    case "$st" in working|blocked) ROOST_RESTORE_BUSY="${ROOST_RESTORE_BUSY:-}${ROOST_RESTORE_BUSY:+ }$1" ;; esac
  fi
  [ -n "${3:-}" ] && roost_restore__rec "$1" "$3"
  if [ -n "${3:-}" ] && roost_restore__will_resume "$3"; then
    # The boot key is read HERE, in this shell: inside the $(...) below it
    # would be read and lost with the subshell, and the loop after placement
    # would not know there was anything to resume.
    roost_restore__pending_root || true
    if f="$(roost_restore__pending_write "$1" "$3")"; then
      t set-option -p -t "$1" remain-on-exit failed 2>/dev/null || true
      t respawn-pane -k -t "$1" -c "$2" "$ROOST_HOME/scripts/roost-placeholder" "$f" "$ROOST_RESTORE_WR_H" 2>/dev/null || true
      return 0
    fi
    printf 'roost restore: pane %s (%s): its pending record could not be written; a shell, not resumed\n' \
      "$(roost_restore__addr "$3")" "$1" >&2
    ROOST_RESTORE_NOTRES=1
  elif [ -n "${3:-}" ] && [ "${ROOST_RESTORE_NORESUME:-0}" != 1 ]; then
    roost_restore__not_resumed "$1" "$3"
  fi
  t set-option -pu -t "$1" remain-on-exit 2>/dev/null || true
  t respawn-pane -k -t "$1" -c "$2" "${ROOST_RESTORE_SHELL_ARGS[@]}" 2>/dev/null || true
}

# roost_restore__not_resumed PANE BLOCKFILE — a pane that gets a shell
# although its block names a conversation, said on stderr with §5.6's words
# (§4.3 Report: "one line per pane not resumed"). A live key whose directory
# is gone is §8.1 test 3b's case and makes the run exit 13
# (ROOST_RESTORE_NOTRES): it could not be resumed for a reason listed. A
# stale key is named by the report instead, in §5.6's words
# (roost_restore_report): the save already judged it not the pane's agent,
# so there was nothing to resume. --recent's choice is the person's, and is
# not named here.
#
# A pane that ran an agent with NO key — a `harness` with no `session_id`, or
# no identity and a `command` naming a harness (roost_restore__cmd_harness) —
# whose directory is gone gets the same words (fix round 1) but NOT the 13
# (fix round 2, the jury's ruling): §8.1 test 3 gives 13 only to a pane that
# had a key, and the same no-key pane with its directory present exits 0 —
# there was never anything to resume, so a gone directory loses nothing.
# --dry-run's action says the same and sets no 13 either. It gets no §5.6
# listing (roost_restore__listing_of): every line would name a directory
# that is gone.
roost_restore__not_resumed() {
  local h i d
  d="$(roost_shape_get "$2" cwd)"
  if h="$(roost_shape_get "$2" harness)" && i="$(roost_shape_get "$2" session_id)"; then
    if [ ! -d "$d" ]; then
      printf 'roost restore: pane %s (%s): %s %s not resumed: directory gone (%s)\n' \
        "$(roost_restore__addr "$2")" "$1" "$h" "$i" "$d" >&2
      ROOST_RESTORE_NOTRES=1
    fi
  elif [ ! -d "$d" ] && ! roost_shape_get "$2" stale_reason >/dev/null 2>&1 \
       && { h="$(roost_shape_get "$2" harness)" || h="$(roost_restore__cmd_harness "$2")"; }; then
    printf 'roost restore: pane %s (%s): %s with no recorded conversation, not resumed: directory gone (%s)\n' \
      "$(roost_restore__addr "$2")" "$1" "$h" "$d" >&2
  fi
  return 0
}

# roost_restore__was PANE BLOCKFILE — §5.4: `@roost-was %OLD` on the pane,
# and `%OLD OLDBOOT %NEW` appended to aliases/<this boot> in the server's
# shape directory (0600, the shape directory's rule), so `was:%OLD` resolves
# and `status` says what the pane was. Every pane matched to a saved block,
# a pane a key took during placement included: it IS the saved pane's place,
# and its old id must still find it. No map with saving off: there is no
# shape directory for it, and `resolve_was` reads only that one.
roost_restore__was() {
  local old
  old="$(roost_shape_get "$2" id 2>/dev/null || true)"
  case "$old" in %[0-9]*) ;; *) return 0 ;; esac
  t set-option -p -t "$1" @roost-was "$old" 2>/dev/null || true
  [ -n "${ROOST_RESTORE_MAPDIR:-}" ] || return 0
  roost_restore__pending_root || return 0
  ( umask 077 && mkdir -p "$ROOST_RESTORE_MAPDIR" \
      && printf '%s %s %s\n' "$old" "${ROOST_RESTORE_OLDBOOT:-unknown}" "$1" >> "$ROOST_RESTORE_MAPDIR/$ROOST_RESTORE_BOOT" ) 2>/dev/null || true
}

# roost_restore__rec PANE BLOCKFILE [REASON] — one placed pane, for the
# report (§4.3 Report) and --json. Appends to ROOST_RESTORE_RECS one line:
#   was|pane|session|window|harness|reason|stale-id|listing|launch hint
# the launch hint LAST, since it is the one field that may hold a `|`.
# REASON, when not given, is what placement decided: `pending` (a waiting
# placeholder, settled by the loop's result), `directory gone`, `--no-resume`,
# `older than --recent`, `stale <why>`, `no key` (a harness with no session
# id, or no identity at all on a pane whose command names a harness — the
# 13 Claude panes of §2.6, a codex pane under #145), or empty for a pane that
# names no conversation.
#
# LISTING is empty, or `N:HARNESS:STALE-ID` when the report prints §5.6's
# store listing under this pane (roost_restore__listing_of): HARNESS and
# STALE-ID are a name from a fixed set and a checked UUID, so neither holds a
# `|`; the directory may, so it is kept in ROOST_RESTORE_LDIRS[N] instead.
roost_restore__rec() {
  local b="$2" r="${3:-}" h="" i="" sid="" addr sess win hint lst=""
  if roost_restore__listing_of "$b"; then
    ROOST_RESTORE_NL="${ROOST_RESTORE_NL:-0}"
    ROOST_RESTORE_LDIRS[$ROOST_RESTORE_NL]="$ROOST_RESTORE_LD"
    lst="$ROOST_RESTORE_NL:$ROOST_RESTORE_LH:$ROOST_RESTORE_LS"
    ROOST_RESTORE_NL=$((ROOST_RESTORE_NL + 1))
  fi
  if h="$(roost_shape_get "$b" harness)"; then
    i="$(roost_shape_get "$b" session_id 2>/dev/null || true)"
    if [ -z "$r" ]; then
      # `directory gone` before `no key` (fix round 1): --dry-run's action
      # decides in that order, and the report must say what it said.
      if [ ! -d "$(roost_shape_get "$b" cwd)" ]; then r="directory gone"
      elif [ -z "$i" ]; then r="no key"
      elif [ "${ROOST_RESTORE_NORESUME:-0}" = 1 ]; then r="--no-resume"
      elif roost_restore__will_resume "$b"; then r=pending
      else r="older than --recent"; fi
    fi
  elif h="$(roost_shape_get "$b" stale_harness)"; then
    [ -n "$r" ] || r="stale $(roost_shape_get "$b" stale_reason 2>/dev/null || true)"
    sid="$(roost_shape_get "$b" stale_session_id 2>/dev/null || true)"
  elif h="$(roost_restore__cmd_harness "$b")"; then
    if [ -z "$r" ]; then
      if [ ! -d "$(roost_shape_get "$b" cwd)" ]; then r="directory gone"; else r="no key"; fi
    fi
  else
    h=""
  fi
  addr="$(roost_restore__addr "$b")"
  sess="${addr%:*}"; win="${addr##*:}"; win="${win%%.*}"
  hint="$(roost_shape_get "$b" launch 2>/dev/null || true)"
  ROOST_RESTORE_RECS="${ROOST_RESTORE_RECS:-}$(roost_shape_get "$b" id)|$1|$sess|$win|$h|$r|$sid|$lst|$hint"$'\n'
}

# roost_restore__cmd_harness BLOCKFILE -> prints the harness the saved pane's
# `command` names, by roost-close.sh's table (roost_close_harness: the five
# names, and Claude's version string, which is what a Claude pane's
# #{pane_current_command} reads); 1 when it names none. A pane with no
# identity is saved with no `harness` line (the writer writes one only with a
# session id, §3.2), so this is the only place a restore can see that such a
# pane ran an agent at all (§5.6: "%34 ran claude with no recorded
# conversation").
roost_restore__cmd_harness() {
  local c
  c="$(roost_shape_get "$1" command 2>/dev/null)" || return 1
  roost_close_harness "" "$c" ""
  [ -n "$ROOST_CLOSE_HARNESS" ] || return 1
  printf '%s\n' "$ROOST_CLOSE_HARNESS"
}

# roost_restore__listing_of BLOCKFILE -> exit 0 when §5.6's store listing goes
# under this pane, and then ROOST_RESTORE_LH is the harness to list, _LS the
# stale id to list first (or empty), _LD the directory (#191 Part 6). A pane
# "with a harness and no usable key":
#   - a `harness` with no `session_id`: that harness;
#   - no identity at all, a `command` naming a harness: that harness;
#   - a stale key (§3.2): the harness the pane's own `command` names when it
#     names one — a Claude pane carrying a NESTED codex key lists Claude's
#     store, since the key was the nested agent's — else the stale
#     harness. Only `stale_reason exited` puts its own stale id first (§5.6:
#     the agent that exited was the pane's own, and its id is the one a
#     person most likely wants back).
# A live key (`harness` and `session_id`) gets no listing: it is resumed, or
# named by the loop's own reason. Only Claude and codex have a listing. The
# directory is the block's `cwd`, the pane's own: §5.6 lists "every
# transcript whose own first `cwd` is the pane's directory".
roost_restore__listing_of() {
  local h r sh
  ROOST_RESTORE_LH="" ROOST_RESTORE_LS="" ROOST_RESTORE_LD=""
  if h="$(roost_shape_get "$1" harness)"; then
    roost_shape_get "$1" session_id >/dev/null 2>&1 && return 1
  elif r="$(roost_shape_get "$1" stale_reason)"; then
    sh="$(roost_shape_get "$1" stale_harness 2>/dev/null || true)"
    h="$(roost_restore__cmd_harness "$1")" || h="$sh"
    # The stale id goes first only in its OWN harness's list (fix round 1):
    # an id of codex's store is no `claude --resume` line.
    [ "$r" = exited ] && [ "$h" = "$sh" ] && ROOST_RESTORE_LS="$(roost_shape_get "$1" stale_session_id 2>/dev/null || true)"
  else
    h="$(roost_restore__cmd_harness "$1")" || return 1
  fi
  case "$h" in claude|codex) ;; *) return 1 ;; esac
  ROOST_RESTORE_LH="$h"
  ROOST_RESTORE_LD="$(roost_shape_get "$1" cwd)" || return 1
  # A directory that is gone has nothing to list, and a line naming it would
  # be one a person cannot run (fix round 1): the pane is "directory gone".
  [ -d "$ROOST_RESTORE_LD" ] || return 1
  return 0
}

# roost_restore_report FROM-STAMPGEN JSON — the report (§4.3), on stderr,
# after placement and the loop: one line per pane not resumed that no
# earlier line named — a launch hint (`%34 was started as '…'`), §5.6's line
# for a stale or missing key — then the codex note of §5.7 when more than
# one codex pane was launched, then the summary:
#   restored S sessions, W windows, P panes; launched A agents; skipped K
#   (existing); R not resumed (reasons listed above)[; M were working or
#   blocked at the save — re-prompt by hand: %a %b]
# "Launched" is the honest word (§4.1 step 8). The loop's results
# (ROOST_PENDING_RESULTS, `pane|launched|reason|harness`) settle each
# `pending` pane. JSON 1 also prints one document on stdout:
# {"restored":[{"was","pane","session","window","launched","reason"}],
#  "skipped":[…],"from":"STAMP-GEN"}.
roost_restore_report() {
  local from="$1" json="${2:-0}" line was pane sess win h r sid lst hint res l a=0 nr=0 nb=0
  local codex="" ncodex=0 first_codex="" j="" sk="" n
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS='|' read -r was pane sess win h r sid lst hint <<< "$line"
    l=0
    if [ "$r" = pending ]; then
      res="$(printf '%s' "${ROOST_PENDING_RESULTS:-}" | grep -- "^$pane|" | tail -1 || true)"
      if [ -n "$res" ]; then
        l="$(printf '%s' "$res" | cut -d'|' -f2)"; r="$(printf '%s' "$res" | cut -d'|' -f3)"
      else
        r="not reached"
      fi
    fi
    if [ "$l" = 1 ]; then
      a=$((a + 1))
      if [ "$h" = codex ]; then
        ncodex=$((ncodex + 1)); [ -n "$first_codex" ] || first_codex="$pane"
      fi
    elif [ -n "$h" ] && [ "$r" != "taken by another launcher" ]; then
      # A pane another launcher (a `revive`) took during the loop was
      # resumed, by that launcher: not counted here (review round 1, N3).
      nr=$((nr + 1))
    fi
    case "$r" in
      "stale "*)
        case "${r#stale }" in
          nested) n="from a nested agent" ;;
          exited) n="from an agent that exited" ;;
          *) n="from another program" ;;
        esac
        printf 'roost restore: %s carries a stale %s key (%s…) %s; not resumed\n' "$pane" "$h" "${sid:0:8}" "$n" >&2 ;;
      "no key")
        printf 'roost restore: %s ran %s with no recorded conversation; roost revive %s cannot resume it\n' "$pane" "$h" "$pane" >&2 ;;
    esac
    # §5.6's store listing under the line that named the pane, printed and
    # never run (#191 Part 6). Only for the two reasons above: a pane that was
    # resumed, or that the loop named for its own reason, has a key.
    case "$r:$lst" in
      "stale "*:?*|"no key":?*)
        roost_resume_print_listing "roost restore: $pane" "$(printf '%s' "$lst" | cut -d: -f2)" \
          "${ROOST_RESTORE_LDIRS[${lst%%:*}]}" "${lst##*:}" >&2 ;;
    esac
    [ -n "$hint" ] && printf "roost restore: %s was started as '%s'\n" "$pane" "$hint" >&2
    if [ "$json" = 1 ]; then
      [ "$l" = 1 ] && r=""
      roost_jsonout_encode "$was" "$pane" "$sess" "$r" || return 1
      case "$win" in ''|*[!0-9]*) win=null ;; esac
      j="$j${j:+,}{\"was\":${ROOST_JSONOUT_STR[0]},\"pane\":${ROOST_JSONOUT_STR[1]},\"session\":${ROOST_JSONOUT_STR[2]},\"window\":$win,\"launched\":$( [ "$l" = 1 ] && echo true || echo false ),\"reason\":${ROOST_JSONOUT_STR[3]}}"
    fi
  done <<< "${ROOST_RESTORE_RECS:-}"
  if [ "$ncodex" -gt 1 ]; then
    printf 'roost restore: %s codex panes resumed; until #145 their badges all land on the first (%s)\n' "$ncodex" "$first_codex" >&2
  fi
  n="$(printf '%s' "${ROOST_RESTORE_SKIPPED:-}" | grep -c . || true)"
  line="restored ${ROOST_RESTORE_SESSIONS:-0} sessions, ${ROOST_RESTORE_WINDOWS:-0} windows, ${ROOST_RESTORE_PANES:-0} panes; launched $a agents; skipped $n (existing); $nr not resumed (reasons listed above)"
  if [ -n "${ROOST_RESTORE_BUSY:-}" ]; then
    nb="$(printf '%s\n' $ROOST_RESTORE_BUSY | grep -c .)"
    line="$line; $nb were working or blocked at the save — re-prompt by hand: $ROOST_RESTORE_BUSY"
  fi
  printf 'roost restore: %s\n' "$line" >&2
  if [ "$json" = 1 ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      roost_jsonout_encode "$line" || return 1
      sk="$sk${sk:+,}${ROOST_JSONOUT_STR[0]}"
    done <<< "${ROOST_RESTORE_SKIPPED:-}"
    roost_jsonout_encode "$from" || return 1
    printf '{"restored":[%s],"skipped":[%s],"from":%s}\n' "$j" "$sk" "${ROOST_JSONOUT_STR[0]}"
  fi
  return 0
}

# roost_restore__will_resume BLOCKFILE -> exit 0 when the saved pane will be
# resumed, and then ROOST_RESTORE_WR_H / _ID / _T hold its harness, id and
# transcript. Decided HERE, at placement, for --no-resume and --recent alike
# (§4.3, revision 10, C B2): a pane left out gets a shell and NO pending
# file, so no later attach's worker — which runs without --recent — can
# launch the agent the person left out. Revision 9 wrote the file and skipped
# the pane only in the loop.
#
#   - a live key: `harness` and `session_id` (never `stale_*`, §5.6);
#   - its saved directory present (§4.3 Directories: a pane whose cwd is gone
#     gets a shell in the home directory and is never resumed);
#   - not --no-resume (ROOST_RESTORE_NORESUME=1);
#   - --recent DAYS (ROOST_RESTORE_RECENT): a transcript that is RECORDED and
#     exists, and whose mtime is more than DAYS days ago, leaves the pane out.
#     A pane with no transcript path is always resumed (§4.3); one whose
#     recorded file is gone is the store check's business, in the loop.
roost_restore__will_resume() {
  local h i tr d m now
  ROOST_RESTORE_WR_H="" ROOST_RESTORE_WR_ID="" ROOST_RESTORE_WR_T=""
  [ "${ROOST_RESTORE_NORESUME:-0}" = 1 ] && return 1
  h="$(roost_shape_get "$1" harness)" || return 1
  i="$(roost_shape_get "$1" session_id)" || return 1
  [ -n "$h" ] && [ -n "$i" ] || return 1
  d="$(roost_shape_get "$1" cwd)" || return 1
  [ -d "$d" ] || return 1
  tr="$(roost_shape_get "$1" transcript 2>/dev/null || true)"
  if [ -n "${ROOST_RESTORE_RECENT:-}" ] && [ -n "$tr" ] && [ -f "$tr" ]; then
    # stat's two dialects: GNU `-c %Y`, BSD (macOS) `-f %m`. GNU first, and
    # each answer must be a number: GNU stat ALSO takes `-f %m` (`-f` is its
    # file-system mode) and prints something that is not an mtime, which
    # left every transcript un-judged on Ubuntu (found in the container). A
    # file whose mtime cannot be read is not judged old.
    m="$(stat -c %Y "$tr" 2>/dev/null || true)"
    case "$m" in ''|*[!0-9]*) m="$(stat -f %m "$tr" 2>/dev/null || true)" ;; esac
    now="${ROOST_TEST_NOW:-$(date +%s)}"
    case "$m" in
      ''|*[!0-9]*) ;;
      *) [ $((now - m)) -gt $((ROOST_RESTORE_RECENT * 86400)) ] && return 1 ;;
    esac
  fi
  ROOST_RESTORE_WR_H="$h" ROOST_RESTORE_WR_ID="$i" ROOST_RESTORE_WR_T="$tr"
  return 0
}

# roost_restore__pending_write PANE BLOCKFILE -> prints the pending file
# written for PANE from the block (roost_pending_write, §4.6), under
# pending/<boot>/ of this run's directory (roost_restore__pending_root).
# Call roost_restore__will_resume first: its ROOST_RESTORE_WR_* are the keys.
#
# `order` is the block file's own number: roost_shape_parse numbers every
# block in file order, so the pane blocks' numbers follow the shape's pane
# order, which the loop walks (§4.6). `session` and `window` are the saved
# address's (SESSION:WINDOW.PANE; a session name may hold `:` or `.`, so the
# LAST `:` splits it).
roost_restore__pending_write() {
  local addr sess win n
  roost_restore__pending_root || return 1
  addr="$(roost_restore__addr "$2")"
  sess="${addr%:*}"; win="${addr##*:}"; win="${win%%.*}"
  n="${2##*/}"; n="${n%%.*}"; n=$((10#$n))
  roost_pending_write "$ROOST_RESTORE_SD" "$ROOST_RESTORE_BOOT" "$1" \
    "$(roost_shape_get "$2" id)" "$ROOST_RESTORE_WR_H" "$ROOST_RESTORE_WR_ID" "$ROOST_RESTORE_WR_T" \
    "$(roost_shape_get "$2" cwd)" "$(roost_shape_get "$2" session_cwd 2>/dev/null || true)" \
    "$sess" "$win" "$n"
}

# roost_restore__pending_root -> sets ROOST_RESTORE_BOOT, read once, after
# the server runs: the boot key `#{start_time}-#{pid}` that names
# pending/<boot>/ (§3.1), the same key `save` and `revive` read. Exit 1 when
# the server cannot say it.
roost_restore__pending_root() {
  [ -n "${ROOST_RESTORE_BOOT:-}" ] && return 0
  ROOST_RESTORE_BOOT="$(t display -p '#{start_time}-#{pid}' 2>/dev/null || true)"
  [ -n "$ROOST_RESTORE_BOOT" ]
}

# roost_restore__pending_taken PANE BLOCKFILE -> for a pane a key took during
# placement (§4.3 step 1, Lost; or T2's changed-by-hand row): when its block
# would have been resumed, its pending file is written as %N.taken — §4.6's
# overlay keeps the key, as for any taken pane — and the caller's line names
# `roost revive %N`. Exit 0 when it wrote one.
roost_restore__pending_taken() {
  local f
  roost_restore__will_resume "$2" || return 1
  roost_restore__pending_root || return 1
  f="$(roost_restore__pending_write "$1" "$2")" || return 1
  mv "$f" "$f.taken" 2>/dev/null
}

# roost_restore__settle_dead -> §4.7 arrow T2b. A restore that takes over a
# dead `restoring/` also takes the dead run's files: each F.used, and each F
# it wins, whose pane still runs its placing line, is respawned into a plain
# shell in that pane's directory (there is no saved block for it), and the
# dead run's files are cleared. The dead run's bootstrap is settled the same
# way, so it holds a shell and is NOT a replaceable session for this run: its
# saved session is skipped as existing (§4.3).
#
# Only panes whose placing line names a file IN restoring/ are touched, and
# every file there is this run's or the dead run's being settled: each run's
# names carry its own token (roost_restore__new_file), and restoring/ goes
# with each run that ends. A pane from an earlier run, a key's shell among
# them, names a file no run will make again (review round 2, Codex R2-B1).
roost_restore__settle_dead() {
  local f base id sc dir
  for f in "$ROOST_RESTORE_RD"/bootstrap* "$ROOST_RESTORE_RD"/place.* ; do
    [ -e "$f" ] || continue
    base="${f##*/}"
    case "$base" in
      *.taken) continue ;;
      *.used) ;;
      *) mv "$f" "$f.used" 2>/dev/null || continue; base="$base.used" ;;
    esac
    base="${base%.used}"
    while IFS=' ' read -r id sc; do
      [ -n "$id" ] || continue
      roost_restore__placing "$sc" "$base" || continue
      dir="$(t -u display-message -p -t "$id" '#{pane_current_path}' 2>/dev/null || true)"
      t set-option -pu -t "$id" remain-on-exit 2>/dev/null || true
      t respawn-pane -k -t "$id" -c "${dir:-${HOME:-/}}" "${ROOST_RESTORE_SHELL_ARGS[@]}" 2>/dev/null || true
    done <<< "$(t -u list-panes -a -F '#{pane_id} #{pane_start_command}' 2>/dev/null || true)"
  done
  find "$ROOST_RESTORE_RD" -mindepth 1 ! -name owner -exec rm -f {} + 2>/dev/null || true
}

# roost_restore__window_first SID WID SAVEDINDEX — the first window of a
# session restore made takes its saved index: new-session puts it at
# base-index, and a sparse set or another base-index must come back as saved
# (§4.3 Windows).
roost_restore__window_first() {
  local cur
  cur="$(t -u display-message -p -t "$2" '#{window_index}' 2>/dev/null || true)"
  [ "$cur" = "$3" ] && return 0
  t move-window -s "$2" -t "$1:$3" 2>/dev/null || true
}

# roost_restore__key BLOCKFILE -> prints "HARNESS ID" for a pane block that
# names a conversation (live or stale keys), or nothing.
roost_restore__key() {
  local h i
  if h="$(roost_shape_get "$1" harness)" && i="$(roost_shape_get "$1" session_id)"; then
    printf '%s %s\n' "$h" "$i"
  elif h="$(roost_shape_get "$1" stale_harness)" && i="$(roost_shape_get "$1" stale_session_id)"; then
    printf '%s %s\n' "$h" "$i"
  fi
}

# roost_restore__build_window WID WINDOWBLOCK FIRSTPANE FIRSTFILE PRECLAIMED
# -> 0, or 13 when the window could not hold every saved pane.
#
# §4.3 Windows. The window exists with its first pane, a placing placeholder
# (FIRSTPANE, watching FIRSTFILE). Then:
#   1. split until the saved pane count exists, each time on THE PANE WHOSE
#      LARGER SIDE IS THE LARGEST, ACROSS THAT SIDE (-h when its width >= its
#      height, else -v). §2.7 measured both halves: splitting the newest pane
#      stops at four on 24 lines, and the largest pane split in tmux's default
#      direction stops at four on a 200x10 window. Every new pane is a placing
#      placeholder after its own restoring/place.<n> (T1).
#   2. a split tmux refuses: the window keeps the K panes it has, tmux's
#      default layout, and every saved block after them is named on stderr
#      with its key, so its conversation is never lost in silence (exit 13).
#   3. select-layout with the saved string (a failure: one line, tmux's
#      default layout), the saved active pane, then `resize-pane -Z` for
#      `zoomed 1` — the layout string does not carry the zoom (probe 1.1).
#   4. the ROOST_TEST_PLACE_HOLD seam, then the per-pane step on EVERY pane in
#      index order against the saved blocks in order (T2, T3): select-layout
#      gives cell i to the pane at index i, which is the saved pane i.
#      PRECLAIMED is a pane already claimed (the bootstrap's): respawned only.
#   5. names re-stamped on the panes restore placed.
roost_restore__build_window() {
  local wid="$1" wf="$2" waddr layout map count k i f out tgt dir best bw bh pw ph id rc=0 act zp
  # Empty, not just declared: on bash 4.4 and later `${#panes[@]}` of an
  # array never set is unbound under `set -u`, and a window whose server
  # died before its panes were listed stopped the whole run (review round 8).
  local -a blocks=() panes=()
  waddr="$(roost_restore__addr "$wf")"
  while IFS= read -r f; do [ -n "$f" ] && blocks+=("$f"); done <<< "$(roost_restore__panes "$waddr")"
  k="${#blocks[@]}"
  map=$'\n'"$3 $4"$'\n'
  count=1
  while [ "$count" -lt "$k" ]; do
    best="" bw=-1
    while IFS=' ' read -r id pw ph; do
      [ -n "$id" ] || continue
      if [ "$pw" -ge "$ph" ]; then bh="$pw"; else bh="$ph"; fi
      if [ "$bh" -gt "$bw" ]; then bw="$bh"; best="$id"; tgt="$pw $ph"; fi
    done <<< "$(t -u list-panes -t "$wid" -F '#{pane_id} #{pane_width} #{pane_height}' 2>/dev/null || true)"
    if [ "${tgt% *}" -ge "${tgt#* }" ]; then dir=-h; else dir=-v; fi
    roost_restore__new_file; f="$ROOST_RESTORE_F"
    out="$(t split-window -d "$dir" -P -F '#{pane_id}' -t "$best" -c "$(roost_restore__cwd "${blocks[$count]}" 2>/dev/null)" \
      "$ROOST_HOME/scripts/roost-placeholder" "$f" --placing 2>/dev/null)" || { rm -f "$f"; break; }
    t set-option -p -t "$out" remain-on-exit failed 2>/dev/null || true
    map="$map$out $f"$'\n'
    count=$((count + 1))
  done
  layout="$(roost_shape_get "$wf" layout)"
  if [ "$count" -lt "$k" ]; then
    rc=13
    i="$count"
    while [ "$i" -lt "$k" ]; do
      id="$(roost_restore__key "${blocks[$i]}")"
      printf 'roost restore: pane %s not placed: no room in the window%s; start it by hand, or with roost revive\n' \
        "$(roost_restore__addr "${blocks[$i]}")" "${id:+ (its conversation: $id)}" >&2
      i=$((i + 1))
    done
  elif [ -n "$layout" ] && ! t select-layout -t "$wid" "$layout" >/dev/null 2>&1; then
    printf "roost restore: window %s: the saved layout did not apply; tmux's default layout instead\n" "$waddr" >&2
  fi
  while IFS= read -r id; do [ -n "$id" ] && panes+=("$id"); done <<< "$(t -u list-panes -t "$wid" -F '#{pane_id}' 2>/dev/null || true)"
  act="" zp=""
  i=0
  while [ "$i" -lt "${#panes[@]}" ] && [ "$i" -lt "$k" ]; do
    [ "$(roost_shape_get "${blocks[$i]}" active 2>/dev/null)" = 1 ] && act="${panes[$i]}"
    i=$((i + 1))
  done
  [ -n "$act" ] && t select-pane -t "$act" 2>/dev/null || true
  if [ "$(roost_shape_get "$wf" zoomed 2>/dev/null)" = 1 ] && [ "${#panes[@]}" -gt 1 ]; then
    t resize-pane -Z -t "${act:-${panes[0]}}" 2>/dev/null || true
  fi
  roost_restore__hold ROOST_TEST_PLACE_HOLD
  i=0
  while [ "$i" -lt "${#panes[@]}" ] && [ "$i" -lt "$k" ]; do
    id="${panes[$i]}"
    f="${map#*$'\n'"$id "}"; f="${f%%$'\n'*}"
    out="$(roost_restore__cwd "${blocks[$i]}")"
    if [ "$id" = "$5" ]; then
      # The bootstrap was claimed before this window was built, so a person
      # had all of that time to respawn it by hand: look again, right before
      # the respawn (roost_restore__respawn_claimed).
      zp=0; roost_restore__respawn_claimed "$id" "$f" "$out" "${blocks[$i]}" || zp=$?
    else
      zp=0; roost_restore_place_pane "$id" "$f" "$out" "${blocks[$i]}" || zp=$?
    fi
    # A keyed pane left to a person keeps its key as %N.taken (§4.3 step 1),
    # and its line says how to bring the agent back — still one line.
    out=""
    case "$zp" in
      1) roost_restore__rec "$id" "${blocks[$i]}" "taken by a key" ;;
      2) roost_restore__rec "$id" "${blocks[$i]}" "changed by hand" ;;
    esac
    if [ "$zp" != 0 ] && roost_restore__pending_taken "$id" "${blocks[$i]}"; then
      out=" — its $ROOST_RESTORE_WR_H conversation was not resumed (roost revive $id to resume it)"
    fi
    # A pane restore leaves to a person is named: restoring/, with each
    # file's .taken rename, is removed when restore ends (§3.5 step 4), so
    # this line is the record of which saved pane went where.
    case "$zp" in
      1) printf 'roost restore: pane %s (%s) was taken by a key during placement; left as it is%s\n' \
           "$(roost_restore__addr "${blocks[$i]}")" "$id" "$out" >&2 ;;
      2) printf 'roost restore: pane %s (%s) was changed by hand during placement; left as it is%s\n' \
           "$(roost_restore__addr "${blocks[$i]}")" "$id" "$out" >&2 ;;
    esac
    roost_restore__was "$id" "${blocks[$i]}"
    if [ "$zp" = 0 ]; then
      ROOST_RESTORE_PANES=$((ROOST_RESTORE_PANES + 1))
      if f="$(roost_shape_get "${blocks[$i]}" name)"; then
        t set-option -p -t "$id" @roost-name "$f" 2>/dev/null || true
      fi
    fi
    i=$((i + 1))
  done
  ROOST_RESTORE_WINDOWS=$((ROOST_RESTORE_WINDOWS + 1))
  return "$rc"
}

# roost_restore__make_session SESSIONBLOCK BOOTSTRAP -> places one full
# session; returns 0 placed, 12 skipped, 13 placed but a window could not
# hold every pane. BOOTSTRAP=1 when the server is not running: the session is
# made with the server, as its bootstrap (§4.3 Server).
roost_restore__make_session() {
  local blk="$1" boot="$2" name wfirst wname pfirst cwd size w h f out sid wid pane npanes rc=0 r
  local wf idx pre="" act=""
  local -a wins=()
  name="$(roost_restore__addr "$blk")"
  while IFS= read -r wf; do [ -n "$wf" ] && wins+=("$wf"); done <<< "$(roost_restore__windows "$name")"
  [ "${#wins[@]}" -gt 0 ] || return 0
  wfirst="${wins[0]}"
  pfirst="$(roost_restore__panes "$(roost_restore__addr "$wfirst")" | head -1)"
  [ -n "$pfirst" ] || return 0
  npanes=0
  for wf in "${wins[@]}"; do
    npanes=$((npanes + $(roost_restore__panes "$(roost_restore__addr "$wf")" | grep -c .)))
  done
  if [ "$boot" != 1 ] && roost_restore__exists "$name"; then
    printf "roost restore: session '%s' exists — skipped, %s panes not restored\n" "$name" "$npanes" >&2
    ROOST_RESTORE_SKIPPED="${ROOST_RESTORE_SKIPPED:-}$name"$'\n'
    return 12
  fi
  cwd="$(roost_restore__cwd "$pfirst" 2>/dev/null)"
  size="$(roost_restore__size "$name")"; w="${size% *}" h="${size#* }"
  local -a nflag=()
  wname="$(roost_shape_get "$wfirst" name)" && nflag=(-n "$wname")
  if [ "$boot" = 1 ]; then
    # A new bootstrap starts with no name record. One left by an earlier
    # bootstrap of this run whose server died before its respawn would
    # otherwise name THIS server's panes: a new server's ids restart at %0
    # and @0, and the split fallback below looks the record up before the
    # record for this bootstrap is set (review round 8, Codex R8-B1).
    ROOST_RESTORE_BOOT_NAME_PANE="" ROOST_RESTORE_BOOT_NAME_WID="" ROOST_RESTORE_BOOT_NAME=""
    f="$ROOST_RESTORE_RD/bootstrap.$ROOST_RESTORE_RUN"; : > "$f"
    # The server's first session, started the way ensure_session starts one
    # (-f CONF), at the saved size, with the placing placeholder by its own
    # path as its one pane (§4.3 Server, §2.10).
    # A failure here returns 1, which stops the WHOLE run (roost_restore_run):
    # no later session may be made on a server that was not started the roost
    # way (review round 1, Fable B1).
    if ! out="$(t -f "$CONF" new-session -d -P -F '#{session_id} #{window_id} #{pane_id}' \
      -s "$(roost_restore__made "$name")" ${nflag[@]+"${nflag[@]}"} -c "$cwd" -x "$w" -y "$h" \
      "$ROOST_HOME/scripts/roost-placeholder" "$f" --placing 2>&1)"; then
      printf "roost restore: could not start the tmux server with session '%s' (%s); nothing restored\n" \
        "$name" "$(printf '%s' "$out" | head -1)" >&2
      return 1
    fi
  else
    roost_restore__new_file; f="$ROOST_RESTORE_F"
    out="$(t new-session -d -P -F '#{session_id} #{window_id} #{pane_id}' \
      -s "$(roost_restore__made "$name")" ${nflag[@]+"${nflag[@]}"} -c "$cwd" -x "$w" -y "$h" \
      "$ROOST_HOME/scripts/roost-placeholder" "$f" --placing 2>/dev/null)" || {
        printf "roost restore: session '%s' could not be made — skipped, %s panes not restored\n" "$name" "$npanes" >&2
        ROOST_RESTORE_SKIPPED="${ROOST_RESTORE_SKIPPED:-}$name"$'\n'
        return 12; }
  fi
  sid="${out%% *}" out="${out#* }" wid="${out%% *}" pane="${out#* }"
  # A bootstrap's first window is read back later, once two things are
  # known: the read rules of a server that was not running when they were
  # learned (review round 5, Fable N1: before them, a `$` that 3.4 prints as
  # `\$` looked grown), and that the bootstrap is still restore's, right
  # before its respawn (roost_restore__respawn_claimed).
  [ "$boot" != 1 ] && [ "${#nflag[@]}" -gt 0 ] && roost_restore__window_name "$wid" "$wname"
  t set-option -p -t "$pane" remain-on-exit failed 2>/dev/null || true
  if [ "$boot" = 1 ]; then
    # The conf's save hooks (#191 Part 4) find bin/roost through
    # @roost-home, which server_init sets. Set here first, at once, so a
    # pane killed while restore is still starting the server is still
    # written to closed/<this boot>/ (§8.1 test 8h): server_init comes after
    # the hold, and every hook before it would run a path with no checkout.
    t set-option -g @roost-home "$ROOST_HOME" 2>/dev/null || true
    roost_restore__hold ROOST_TEST_RESTORE_HOLD
    server_init
    roost_shape__read_rules || true
    roost_restore__shell_cmd
    # Replaceable only when this run made it, wins the rename, and it still
    # holds the one pane restore made (§4.3). Lost: a key took it, the pane
    # is the person's, and the saved session is skipped by name.
    r=0; roost_restore__claim "$pane" "$f" || r=$?
    roost_restore__hold ROOST_TEST_BOOT_HOLD_AFTER_CLAIM
    if [ "$r" = 0 ] && [ "$(t -u list-panes -s -t "$sid" -F x 2>/dev/null | grep -c .)" != 1 ]; then
      # Won, but a person split the session meanwhile: it is not
      # replaceable, and the saved session is skipped. The bootstrap pane is
      # still restore's — it won the rename, so no key reached it — and it
      # becomes a shell now: a placeholder left with its file gone could
      # never be freed by a key (review round 1, Fable N1). Unless the person
      # replaced it too, after the claim looked: then it is theirs, left as
      # it is, and its file becomes .taken (roost_restore__respawn_claimed).
      r=3; roost_restore__respawn_claimed "$pane" "$f" "$cwd" || r=2
    fi
    # Each way the bootstrap is lost has its own line (review round 3,
    # Fable N1): only a key's earns the advice to kill the session and try
    # again. Changed or split by hand, the session holds a person's work, and
    # killing it would lose that.
    #
    # The advice names THIS save (--from), not a plain restore (spec §4.3
    # said `roost restore --only NAME`). Since Part 4 that kill-session writes
    # a kill file for the session's panes on this boot, and this restore's own
    # final save, then the save after the kill, become the newest: a plain
    # restore would find no NAME at all. The save restored here is from an
    # earlier boot (or a file), so its own closed record does not hold this
    # kill, and --from it brings NAME back.
    case "$r" in
      0) ;;
      1) local from_sel
         if [ "${ROOST_RESTORE_BYFILE:-0}" = 1 ]; then from_sel="$ROOST_RESTORE_FILE"
         else from_sel="$(roost_restore__stampgen "$ROOST_RESTORE_FILE")"; fi
         printf "roost restore: session '%s' skipped: the bootstrap pane was taken by a key — %s panes not restored (tmux kill-session -t NAME, then roost restore --from %s --only NAME)\n" "$name" "$npanes" "$from_sel" >&2
         ROOST_RESTORE_SKIPPED="${ROOST_RESTORE_SKIPPED:-}$name"$'\n'
         return 12 ;;
      *) [ "$r" = 2 ] && printf 'roost restore: pane %s (%s) was changed by hand during placement; left as it is\n' \
           "$(roost_restore__addr "$pfirst")" "$pane" >&2
         printf "roost restore: session '%s' skipped: it was changed by hand during placement — %s panes not restored\n" "$name" "$npanes" >&2
         ROOST_RESTORE_SKIPPED="${ROOST_RESTORE_SKIPPED:-}$name"$'\n'
         return 12 ;;
    esac
    # Still restore's: the claim won and the recheck passed. Its name is
    # put right when its respawn's own look passes too.
    ROOST_RESTORE_BOOT_NAME_PANE=""
    if [ "${#nflag[@]}" -gt 0 ]; then
      ROOST_RESTORE_BOOT_NAME_PANE="$pane" ROOST_RESTORE_BOOT_NAME_WID="$wid" ROOST_RESTORE_BOOT_NAME="$wname"
    fi
    pre="$pane"
  fi
  roost_restore__window_first "$sid" "$wid" "$(roost_restore__addr "$wfirst" | sed 's/.*://')"
  for wf in "${wins[@]}"; do
    idx="$(roost_restore__addr "$wf" | sed 's/.*://')"
    if [ "$wf" != "$wfirst" ]; then
      local -a nf=()
      wname="$(roost_shape_get "$wf" name)" && nf=(-n "$wname")
      pfirst="$(roost_restore__panes "$(roost_restore__addr "$wf")" | head -1)"
      [ -n "$pfirst" ] || continue
      roost_restore__new_file; f="$ROOST_RESTORE_F"
      # The window name goes in as saved: `new-window -n` stores it as given
      # up to tmux 3.6, where undoing tmux's escaping would make it drift
      # (R8.3, measured); from 3.7 roost_restore__window_name puts it right.
      out="$(t new-window -d -P -F '#{window_id} #{pane_id}' -t "$sid:$idx" ${nf[@]+"${nf[@]}"} \
        -c "$(roost_restore__cwd "$pfirst" 2>/dev/null)" \
        "$ROOST_HOME/scripts/roost-placeholder" "$f" --placing 2>/dev/null)" || {
          printf 'roost restore: window %s could not be made; its panes are not restored\n' "$(roost_restore__addr "$wf")" >&2
          rc=13; continue; }
      wid="${out%% *}" pane="${out#* }"
      [ "${#nf[@]}" -gt 0 ] && roost_restore__window_name "$wid" "$wname"
      t set-option -p -t "$pane" remain-on-exit failed 2>/dev/null || true
    fi
    r=0; roost_restore__build_window "$wid" "$wf" "$pane" "$f" "$pre" || r=$?
    [ "$r" = 13 ] && rc=13
    [ "$(roost_shape_get "$wf" active 2>/dev/null)" = 1 ] && act="$wid"
    pre=""
  done
  [ -n "$act" ] && t select-window -t "$act" 2>/dev/null || true
  ROOST_RESTORE_SESSIONS=$((ROOST_RESTORE_SESSIONS + 1))
  return "$rc"
}

# roost_restore__make_member SESSIONBLOCK -> a later member of a session
# group (ruling R7): `new-session -t` joins the first member, so it shares
# that session's windows and panes — one copy of each, as tmux had them.
# 0 placed, 12 skipped (exists, or the first member is not on the server).
roost_restore__make_member() {
  local blk="$1" name grp gid out aw
  name="$(roost_restore__addr "$blk")"
  grp="$(roost_shape_get "$blk" group)"
  if roost_restore__exists "$name"; then
    printf "roost restore: session '%s' exists — skipped (it joins %s's group)\n" "$name" "$grp" >&2
    ROOST_RESTORE_SKIPPED="${ROOST_RESTORE_SKIPPED:-}$name"$'\n'
    return 12
  fi
  if ! gid="$(roost_restore__sid "$grp")"; then
    printf "roost restore: session '%s' skipped: %s, whose group it joins, is not on the server\n" "$name" "$grp" >&2
    return 12
  fi
  out="$(t new-session -d -P -F '#{session_id}' -t "$gid" -s "$(roost_restore__made "$name")" 2>/dev/null)" || {
    printf "roost restore: session '%s' could not join %s's group — skipped\n" "$name" "$grp" >&2; return 12; }
  if aw="$(roost_shape_get "$blk" active_window)"; then
    roost_shape__digits "$aw" && t select-window -t "$out:$aw" 2>/dev/null || true
  fi
  ROOST_RESTORE_SESSIONS=$((ROOST_RESTORE_SESSIONS + 1))
  return 0
}

# roost_restore_run FILE SHAPEDIR -> the exit code (§4.3): 0 placed; 12 a
# saved session skipped as existing; 13 a window could not hold every saved
# pane; 1 a live restore holds `restoring/`. Call roost_restore_prepare first.
# roost_restore_prepare FILE -> checks the WHOLE file, parses it into
# $ROOST_RESTORE_PD and applies --only; 0, or the exit code to stop with (16 a
# refused file or selection, 2 a selector that matches nothing). Nothing here
# touches the server but to read it (§4.3 Refuse first: the file is checked
# before the first tmux command).
#
# With SHAPE-DIR (and the save not a --from FILE, ROOST_RESTORE_BYFILE), the
# reading rule's step 4 runs between the parse and --only: every pane the
# save's own boot's closed/ record names is removed first
# (roost_restore_drop_closed), so --only, --dry-run and the run all see the
# fleet that is left. 3 when nothing is left: the caller says so and exits 0.
roost_restore_prepare() {
  local r=0 boot
  if ! roost_shape_check "$1"; then
    printf 'roost restore: %s: %s; nothing done\n' "$1" "$ROOST_SHAPE_FAULT" >&2
    return 16
  fi
  ROOST_RESTORE_PD="$(mktemp -d)"
  roost_shape_parse "$1" "$ROOST_RESTORE_PD" || return 1
  if [ -n "${2:-}" ] && [ "${ROOST_RESTORE_BYFILE:-0}" != 1 ]; then
    boot="$(roost_shape_get "$ROOST_RESTORE_PD/0000.header" boot 2>/dev/null || true)"
    roost_restore_drop_closed "$ROOST_RESTORE_PD" "$2" "$boot" || return 3
  fi
  roost_restore__select || r=$?
  return "$r"
}

# roost_restore_drop_closed PARSEDIR SHAPE-DIR BOOT — §3.6 step 4, the closed
# record (§3.6a) applied to the picked save. Exit 0, or 1 when nothing is
# left to restore.
#
# Read: closed/<BOOT>/ of the SAVE'S OWN boot, and no other boot's, ever. A
# pane id is never reused inside one server (§2.7, measured), so a save of
# boot B that holds %N was listed while %N was alive — before its removal —
# and a save that does not hold it has nothing to remove. NO TIME IS
# COMPARED (revision 3, item 2): revision 2 compared seconds and lost a close
# in the picked save's own second, and ordering by `gen` would lose a save
# listed before a close and published after it.
#
# Removed: every pane a `close.` file names, whatever else names it (a
# `roost close` ends in a death by design, so a closed pane has both); and
# every pane a `kill.` file names that NO `died.` note names. A kill file and
# a death note together keep the pane: the belt for the one ordering the kill
# difference does not prove (a user's own hook holding tmux's global queue,
# §3.6a).
#
# Then: a window that lost panes takes tmux's default layout, with one stderr
# line, because select-layout needs the saved pane count (§2.7); a window left
# with no pane, a session left with no window, and a later member of a group
# whose first member went, are not created.
roost_restore_drop_closed() {
  local pd="$1" d="$2/closed/$3" f id kill=" " died=" " close=" " gone=" " w waddr s saddr n left=0
  [ -n "$3" ] && [ -d "$d" ] || return 0
  for f in "$d"/kill.* "$d"/died.* "$d"/close.*; do
    [ -f "$f" ] || continue
    while IFS= read -r id || [ -n "$id" ]; do
      case "$id" in %[0-9]*) ;; *) continue ;; esac
      case "${id#%}" in *[!0-9]*) continue ;; esac
      case "${f##*/}" in
        kill.*) kill="$kill$id " ;;
        died.*) died="$died$id " ;;
        close.*) close="$close$id " ;;
      esac
    done < "$f"
  done
  for f in "$pd"/*.pane; do
    [ -e "$f" ] || continue
    id="$(roost_shape_get "$f" id 2>/dev/null)" || continue
    case "$close" in *" $id "*) ;; *)
      case "$kill" in *" $id "*) ;; *) continue ;; esac
      case "$died" in *" $id "*) continue ;; esac ;;
    esac
    waddr="$(roost_restore__addr "$f")"; waddr="${waddr%.*}"
    case "$gone" in *" $waddr "*) ;; *) gone="$gone$waddr " ;; esac
    rm -f "$f"
  done
  for w in "$pd"/*.window; do
    [ -e "$w" ] || continue
    waddr="$(roost_restore__addr "$w")"
    case "$gone" in *" $waddr "*) ;; *) continue ;; esac
    n="$(ROOST_RESTORE_PD="$pd" roost_restore__panes "$waddr" | grep -c . || true)"
    if [ "$n" = 0 ]; then
      rm -f "$w"
    else
      # The saved layout needs the saved pane count: without its line the
      # window is built and left in tmux's default layout
      # (roost_restore__build_window skips an absent layout).
      sed '/^layout /d' "$w" > "$w.t" && mv -f "$w.t" "$w"
      printf "roost restore: window %s lost panes closed on purpose; tmux's default layout instead\n" "$waddr" >&2
    fi
  done
  for s in "$pd"/*.session; do
    [ -e "$s" ] || continue
    roost_shape_get "$s" group >/dev/null 2>&1 && continue
    saddr="$(roost_restore__addr "$s")"
    if [ -z "$(ROOST_RESTORE_PD="$pd" roost_restore__windows "$saddr")" ]; then
      rm -f "$s"
    fi
  done
  for s in "$pd"/*.session; do
    [ -e "$s" ] || continue
    saddr="$(roost_shape_get "$s" group 2>/dev/null)" || continue
    ROOST_RESTORE_PD="$pd" roost_restore__block session "$saddr" >/dev/null || rm -f "$s"
  done
  for s in "$pd"/*.session; do [ -e "$s" ] && left=1; done
  if [ "$left" = 0 ]; then
    printf 'roost restore: nothing to restore: every saved pane was closed on purpose\n' >&2
    return 1
  fi
  return 0
}

roost_restore_run() {
  local file="$1" sdir="$2" held="${3:-}" rc=0 r blk boot=0 own
  # restoring/ lives in the server's shape directory, where the saver (Part 4)
  # looks for it; with saving off there is no saver to hold off, and the run's
  # files go to a directory of its own.
  if [ -n "$sdir" ]; then ROOST_RESTORE_RD="$sdir/restoring"
  else ROOST_RESTORE_RD="$(mktemp -d)/restoring"; fi
  # pending/<boot>/ goes beside restoring/ (§3.1): in the shape directory,
  # or, with saving off, in this run's own directory — the loop that reads it
  # runs in this same process, and each placeholder names its file by path.
  ROOST_RESTORE_SD="${ROOST_RESTORE_RD%/restoring}" ROOST_RESTORE_BOOT=""
  ROOST_RESTORE_NOTRES=0 ROOST_RESTORE_BUSY="" ROOST_RESTORE_RECS="" ROOST_RESTORE_SKIPPED="" ROOST_RESTORE_NL=0
  # The alias map (§5.4): in the shape directory only, under the save's own
  # boot as OLDBOOT.
  ROOST_RESTORE_MAPDIR="" ROOST_RESTORE_OLDBOOT="$(roost_restore__hdr "$file" boot 2>/dev/null || true)"
  [ -n "$sdir" ] && ROOST_RESTORE_MAPDIR="$sdir/aliases"
  ROOST_RESTORE_N=0 ROOST_RESTORE_SESSIONS=0 ROOST_RESTORE_WINDOWS=0 ROOST_RESTORE_PANES=0
  # The bootstrap's name record (roost_restore__respawn_claimed) is this
  # run's alone: a value from the environment is never one (review round 8,
  # Fable N1).
  ROOST_RESTORE_BOOT_NAME_PANE="" ROOST_RESTORE_BOOT_NAME_WID="" ROOST_RESTORE_BOOT_NAME=""
  # This run's token for its file names (roost_restore__new_file): pid,
  # clock and a random number, digits and `-` only, so it never holds the
  # `.` the names are split on. Unique enough across runs: a repeat needs the
  # same pid in the same second and the same 15-bit draw.
  ROOST_RESTORE_RUN="$$-$(date +%s)-$RANDOM"
  ROOST_SHAPE_TFLAG="$_SOCKET_FLAG" ROOST_SHAPE_TSOCK="$SOCKET"
  # HELD, the third argument (0 or 2, the owner rule's own answer), means the
  # caller already owns restoring/ and keeps it past this run: `persist
  # --at-login` (scripts/lib/roost-persist.sh) takes it FIRST (§4.4), before
  # its 60 s socket wait, and must still hold it when it writes the
  # login/<os-boot> marker, or a `roost` typed in that gap would find neither
  # a live restore to wait for nor the marker, and run a second login restore
  # (§4.6). So in that mode this run neither takes nor drops it, and leaves
  # its final save to the caller: while restoring/ has a live owner a save
  # only records its want (§3.5 step 4).
  #
  # An ARGUMENT, never a variable (fix round 1): a prefix assignment on a
  # function call is exported for its length, and the `tmux new-session`
  # that starts the server carried it into the server's global environment
  # and every pane, where it made a later `roost restore` skip its lock.
  if [ -n "$held" ]; then own="$held"
  else own=0; roost_shape_owner_take "$ROOST_RESTORE_RD" || own=$?; fi
  if [ "$own" = 3 ]; then
    printf 'roost restore: %s; nothing done\n' "${ROOST_SHAPE_OWNER_FAULT:-cannot own $ROOST_RESTORE_RD}" >&2
    rm -rf "$ROOST_RESTORE_PD"
    return 1
  fi
  if [ "$own" = 1 ]; then
    printf 'roost restore: another restore (pid %s) is placing panes on this server; nothing done\n' \
      "${ROOST_SHAPE_OWNER_PID:-?}" >&2
    rm -rf "$ROOST_RESTORE_PD"
    return 1
  fi
  if server_running; then
    roost_shape__read_rules || true
    roost_restore__shell_cmd
    [ "$own" = 2 ] && roost_restore__settle_dead
  else
    ROOST_SHAPE_DOLLAR=0 ROOST_SHAPE_OCTAL=0
    find "$ROOST_RESTORE_RD" -mindepth 1 ! -name 'owner*' -exec rm -f {} + 2>/dev/null || true
  fi
  roost_restore__names
  # Full sessions first, in file order. Whether a session is the BOOTSTRAP is
  # asked of the server each time, never "the first block seen": a block that
  # placed nothing must not let the next one be made on a server nobody
  # started (review round 1, Fable B1). A bootstrap that fails stops the run.
  # Then the later members of groups, which join them.
  for blk in "$ROOST_RESTORE_PD"/*.session; do
    [ -e "$blk" ] || continue
    roost_shape_get "$blk" group >/dev/null && continue
    if server_running; then boot=0; else boot=1; fi
    r=0; roost_restore__make_session "$blk" "$boot" || r=$?
    if [ "$boot" = 1 ]; then
      if [ "$r" = 1 ]; then
        [ -n "$held" ] || roost_shape_owner_drop "$ROOST_RESTORE_RD"
        rm -rf "$ROOST_RESTORE_PD"
        return 1
      fi
      roost_shape__read_rules || true
    fi
    # 12 wins over 13 when both (§4.3 Report).
    case "$r" in 0) ;; 12) rc=12 ;; 13) [ "$rc" = 12 ] || rc=13 ;; *) [ "$rc" = 0 ] && rc="$r" ;; esac
    roost_restore__names
  done
  for blk in "$ROOST_RESTORE_PD"/*.session; do
    [ -e "$blk" ] || continue
    roost_shape_get "$blk" group >/dev/null || continue
    r=0; roost_restore__make_member "$blk" || r=$?
    [ "$r" = 12 ] && rc=12
    roost_restore__names
  done
  # The safety net before restoring/ goes: a pane of this run still running
  # its placing line (a step that stopped early) would be left with no file
  # its key could win. Each is settled into a shell, the T2b rule for a dead
  # run's panes, applied to this run's own.
  roost_restore__hold ROOST_TEST_HOLD_BEFORE_SWEEP
  server_running && roost_restore__settle_dead
  [ -n "$held" ] || roost_shape_owner_drop "$ROOST_RESTORE_RD"
  rm -rf "$ROOST_RESTORE_PD"
  # Restore's own final save (#51, §3.4, §3.5 step 4): one coherent save of
  # the whole restore instead of sixty. Every hook during placement only
  # recorded its want, held off by restoring/; this save drains them all, so
  # its trigger names them beside `restore`. With saving off (no shape
  # directory) there is nothing to save.
  [ -n "$sdir" ] && [ -z "$held" ] && server_running && roost_shape_save_now "$_SOCKET_FLAG" "$SOCKET" restore
  # The plan's seam (ROOST_TEST_LOOP_HOLD): a hand restore waits here, after
  # placement and before its resume loop, so a test can read the placed
  # state — the pending files and their placeholders — before any launch.
  roost_restore__hold ROOST_TEST_LOOP_HOLD
  # A keyed pane that could not get its pending record (its directory gone,
  # §8.1 test 3b): 13, unless 12 already won (§4.3 Report).
  [ "$ROOST_RESTORE_NOTRES" = 1 ] && [ "$rc" = 0 ] && rc=13
  return "$rc"
}

# roost_restore__epoch UTC-STAMP -> prints the epoch seconds of a `saved`
# value (2026-10-24T20:51:02Z). BSD date's form first, then GNU's.
roost_restore__epoch() {
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null
}

# roost_restore__ago UTC-STAMP -> "saved 2 h ago" and the like. The clock is
# ROOST_TEST_NOW when set (the plan's seam).
roost_restore__ago() {
  local then now d
  then="$(roost_restore__epoch "$1")" || { printf 'saved %s' "$1"; return 0; }
  now="${ROOST_TEST_NOW:-$(date +%s)}"
  d=$((now - then)); [ "$d" -lt 0 ] && d=0
  if [ "$d" -lt 120 ]; then printf 'saved %s s ago' "$d"
  elif [ "$d" -lt 7200 ]; then printf 'saved %s min ago' $((d / 60))
  elif [ "$d" -lt 172800 ]; then printf 'saved %s h ago' $((d / 3600))
  else printf 'saved %s days ago' $((d / 86400)); fi
}

# roost_restore__hdr FILE KEY -> a header value.
roost_restore__hdr() { sed -n "s/^$2 //p;/^\$/q" "$1" 2>/dev/null | head -1; }

# roost_restore__stampgen FILE -> STAMP-GEN, the name a save has in history/
# and in --list: the `saved` stamp without its `-` and `:`, then `gen`.
roost_restore__stampgen() {
  local sv
  sv="$(roost_restore__hdr "$1" saved)"
  printf '%s-%s\n' "${sv//[-:]/}" "$(roost_restore__hdr "$1" gen)"
}

# THE READING RULE, steps 1 to 3 (§3.6): which save a restore with no --from
# picks. Step 4 (the closed record) is roost_restore_drop_closed, run on
# whichever save this picks.
#
# Why steps 1 to 3 exist: when a machine shuts down every process is
# signalled at about the same time, and if tmux ran pane-exited or
# session-closed hooks before it was killed itself, the newest saves are a
# SHRINKING fleet. Probe 4.2 (docs/airig/probes/persist-4-shutdown-hooks.md)
# saw no hook run in a Linux poweroff or reboot, and §2.7 none for a SIGTERM to
# the server, so the chain can come only from panes whose own processes died
# first; the rule is kept for exactly those.

# ROOST_RESTORE_DEATHS — the four triggers that are a process death or a kill
# with no hook of its own (§3.6, revision 4, F N8). A save whose trigger list
# holds ANY of them is a death save, so a coalesced round
# `after-split-window pane-exited` is one too (revision 3, F N10).
ROOST_RESTORE_DEATHS=" pane-exited pane-died session-closed window-unlinked "

# roost_restore__death FILE -> exit 0 when FILE is a death save.
roost_restore__death() {
  local t
  for t in $(roost_restore__hdr "$1" trigger); do
    case "$ROOST_RESTORE_DEATHS" in *" $t "*) return 0 ;; esac
  done
  return 1
}

# roost_restore__iso_epoch STAMP -> epoch seconds of `2026-11-02T01:47:18-06:00`
# (util-linux `last --time-format iso`), GNU date first, then BSD date, whose
# %z wants the offset with no colon.
roost_restore__iso_epoch() {
  local z o
  date -d "$1" +%s 2>/dev/null && return 0
  z="${1%[+-]??:??}"; o="${1#"$z"}"
  date -j -f '%Y-%m-%dT%H:%M:%S%z' "$z${o%:*}${o#*:}" +%s 2>/dev/null
}

# roost_restore__local_epoch "YEAR Mon DD HH:MM" -> epoch seconds, read in the
# machine's own zone, as `last` wrote it. The seconds are given as :00: BSD
# date -j fills every field the format leaves out from the clock now.
roost_restore__local_epoch() {
  date -j -f '%Y %b %d %H:%M:%S' "$1:00" +%s 2>/dev/null \
    || date -d "$(printf '%s' "$1" | awk '{ print $2, $3, $1, $4 }'):00" +%s 2>/dev/null
}

# roost_restore__boot_second -> this boot's start, epoch seconds: macOS
# `sysctl -n kern.boottime` ("{ sec = N, usec = M } ..."), then Linux's
# /proc/stat btime.
roost_restore__boot_second() {
  local b
  b="$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^[{] *sec = \([0-9][0-9]*\).*/\1/p' | head -1)"
  [ -n "$b" ] || b="$(sed -n 's/^btime //p' /proc/stat 2>/dev/null | head -1)"
  case "$b" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$b"
}

# roost_restore__shutdown_at -> the last shutdown's time, epoch seconds, or
# nothing when no record is readable. EVERY comparison is in epoch seconds.
#
#   ROOST_SHUTDOWN_AT=EPOCH   the plan's stub record; set and EMPTY = none
#   Linux                     `last -x --time-format iso shutdown`, the newest
#                             line: second resolution, the zone offset printed
#                             (probe 4.1, docs/airig/probes/
#                             persist-4-linux-shutdown.md)
#   macOS                     `last reboot`'s newest `shutdown time Tue Oct 20
#                             15:05`: minute resolution, local time, NO YEAR.
#                             The year is the boot second's, and a shutdown
#                             month later than the boot month is the year
#                             before (a shutdown on 31 December, a boot on 1
#                             January). Measured on macOS 26.3 (§3.6)
# Tried in that order on every system, so a stub `last` on PATH is read the
# same way on both.
roost_restore__shutdown_at() {
  local line iso mon day hm boot by bm sm y
  if [ "${ROOST_SHUTDOWN_AT+set}" = set ]; then
    case "$ROOST_SHUTDOWN_AT" in ''|*[!0-9]*) return 0 ;; esac
    printf '%s\n' "$ROOST_SHUTDOWN_AT"; return 0
  fi
  iso="$(last -x --time-format iso shutdown 2>/dev/null | grep '^shutdown' | head -1 \
    | grep -o '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9][+-][0-9][0-9]:[0-9][0-9]' | head -1)"
  if [ -n "$iso" ]; then roost_restore__iso_epoch "$iso"; return 0; fi
  line="$(last reboot 2>/dev/null | grep '^shutdown time' | head -1)"
  [ -n "$line" ] || return 0
  # shutdown time Tue Oct 20 15:05
  set -- $line
  mon="${4:-}" day="${5:-}" hm="${6:-}"
  case "$hm" in [0-9]*:[0-9][0-9]) ;; *) return 0 ;; esac
  boot="$(roost_restore__boot_second)" || return 0
  # The boot's year and month in LOCAL time, the clock `last` printed the
  # shutdown in. Read in UTC, the year was one off near New Year in any zone
  # but UTC (fix round 1: a boot at 20:00 on 31 December in Chicago is
  # already the next year in UTC), and the window never matched.
  by="$(date -r "$boot" +%Y 2>/dev/null || date -d "@$boot" +%Y)"
  bm="$(date -r "$boot" +%m 2>/dev/null || date -d "@$boot" +%m)"
  sm="$(roost_restore__local_epoch "2000 $mon 01 00:00" | { read -r e; date -r "$e" +%m 2>/dev/null || date -d "@$e" +%m; })"
  y="$by"
  [ -n "$sm" ] && [ "${sm#0}" -gt "${bm#0}" ] && y=$((by - 1))
  roost_restore__local_epoch "$y $mon $day $hm"
}

# roost_restore__reading_rule SHAPEDIR -> ROOST_RESTORE_FILE, ROOST_RESTORE_WHY
# and ROOST_RESTORE_NOREC (1: no record, step 3, the caller says so). Steps:
#   1. no shutdown evidence: `shape`, the newest save
#   2. evidence — a record, and `shape` a death save inside the window — the
#      newest save, walking back through history/ by gen, that is NOT a death
#      save or is older than the window
#   3. no readable record: `shape`
# The window is the shutdown's minute and the minute before it (macOS records
# only the minute; Linux's second is read the same way, so both agree).
roost_restore__reading_rule() {
  local sdir="$1" sat ws we f t
  ROOST_RESTORE_FILE="$sdir/shape" ROOST_RESTORE_WHY="the newest save" ROOST_RESTORE_NOREC=0
  sat="$(roost_restore__shutdown_at)"
  if [ -z "$sat" ]; then ROOST_RESTORE_NOREC=1; return 0; fi
  ws=$(( (sat / 60) * 60 - 60 )); we=$(( (sat / 60) * 60 + 59 ))
  roost_restore__death "$sdir/shape" || return 0
  t="$(roost_restore__epoch "$(roost_restore__hdr "$sdir/shape" saved)")" || return 0
  [ "$t" -ge "$ws" ] && [ "$t" -le "$we" ] || return 0
  for f in $(ls -1 "$sdir/history" 2>/dev/null | sort -t- -k2,2nr); do
    f="$sdir/history/$f"
    if roost_restore__death "$f"; then
      t="$(roost_restore__epoch "$(roost_restore__hdr "$f" saved)")" || continue
      [ "$t" -lt "$ws" ] || continue
    fi
    ROOST_RESTORE_FILE="$f" ROOST_RESTORE_WHY="the save before a shutdown's teardown"
    return 0
  done
  # Every save in the ring is a death save inside the window: the oldest is
  # the best left, and step 4 still applies to it.
  f="$(ls -1 "$sdir/history" 2>/dev/null | sort -t- -k2,2n | head -1)"
  [ -n "$f" ] && ROOST_RESTORE_FILE="$sdir/history/$f" ROOST_RESTORE_WHY="the oldest save kept (every newer one is a shutdown's teardown)"
  return 0
}

# roost_restore_pick SHAPEDIR FROM -> ROOST_RESTORE_FILE and
# ROOST_RESTORE_WHY; exit 2 when there is nothing to restore.
#
# Which save (§4.3, §3.6). No --from: this server's `shape` (Part 4 adds the
# reading rule). --from STAMP-GEN: looked for in four places, in this order
# (§4.8, revisions 7 and 8), each matched by its own header's STAMP-GEN:
#   1. `shape` — the newest save has no history/ name until the next save
#      lands (§3.5 step 2), and with the server down no next save is coming;
#   2. `history/STAMP-GEN`;
#   3. `offer/save` — the restore offer's pin (scripts/lib/roost-offer.sh),
#      there only while an offer holds offer/. It covers a pinned save the
#      ring has dropped and nobody has declined yet, so the offer's `r` and
#      `p` and a second terminal's `--dry-run --from STAMP-GEN` are one code
#      path, with §3.6 step 4 applied, and the offer needs no private "file
#      plus step 4" way in;
#   4. `declined` — a save a person turned down at the offer: the line the
#      offer printed names it by STAMP-GEN, and it must keep working after
#      the ring has dropped the save.
# --from FILE: that file, the caller's own choice. The SERVER is always the
# caller's (`-L`/`-S`, ROOST_SOCKET), never the file's `socket` line.
roost_restore_pick() {
  local sdir="$1" from="$2"
  ROOST_RESTORE_FILE="" ROOST_RESTORE_WHY="" ROOST_RESTORE_BYFILE=0
  if [ -z "$from" ]; then
    if [ -n "$sdir" ] && [ -f "$sdir/shape" ]; then
      roost_restore__reading_rule "$sdir"
      [ "$ROOST_RESTORE_NOREC" = 1 ] && \
        printf 'roost restore: no shutdown record readable; restoring the newest save — roost restore --list shows the others\n' >&2
      return 0
    fi
    printf 'roost restore: no saved shape for this server; nothing to restore\n' >&2
    return 2
  fi
  case "$from" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z-[0-9]*)
      if [ -n "$sdir" ] && [ -f "$sdir/shape" ] && [ "$(roost_restore__stampgen "$sdir/shape")" = "$from" ]; then
        ROOST_RESTORE_FILE="$sdir/shape"
      elif [ -n "$sdir" ] && [ -f "$sdir/history/$from" ]; then
        ROOST_RESTORE_FILE="$sdir/history/$from"
      elif [ -n "$sdir" ] && [ -f "$sdir/offer/save" ] && [ "$(roost_restore__stampgen "$sdir/offer/save")" = "$from" ]; then
        ROOST_RESTORE_FILE="$sdir/offer/save"
      elif [ -n "$sdir" ] && [ -f "$sdir/declined" ] && [ "$(roost_restore__stampgen "$sdir/declined")" = "$from" ]; then
        ROOST_RESTORE_FILE="$sdir/declined"
      else
        printf 'roost restore: no save %s for this server (roost restore --list shows them)\n' "$from" >&2
        return 2
      fi
      ROOST_RESTORE_WHY="chosen with --from" ;;
    *)
      [ -f "$from" ] || { printf 'roost restore: --from %s: no such file\n' "$from" >&2; return 2; }
      ROOST_RESTORE_FILE="$from" ROOST_RESTORE_WHY="the file given with --from" ROOST_RESTORE_BYFILE=1 ;;
  esac
  return 0
}

# roost_restore__host_line FILE -> one stderr line when a --from FILE was
# saved on another machine (§4.3), then the restore carries on: the file is
# the caller's choice, and it places what it can; it resumes nothing whose
# store was not moved with it (§4.2).
roost_restore__host_line() {
  local h
  h="$(roost_restore__hdr "$1" host)"
  [ -n "$h" ] && [ "$h" != "$(uname -n)" ] || return 0
  printf 'roost restore: %s was saved on %s, not this machine; placing it here (a conversation comes back only where its harness store is)\n' "$1" "$h" >&2
}

# roost_restore__select -> prunes $ROOST_RESTORE_PD to the blocks the
# ROOST_RESTORE_ONLY selectors name (§4.3 --only: SESSION, SESSION:WINDOW, an
# old %N); 0, 2 when a selector matches nothing, 16 when a later member of a
# group is selected without its first member and that member is not on the
# server (ruling R7: an address with no parent, nothing done).
roost_restore__select() {
  local sel f a keep=$'\n' hit g i
  [ "${#ROOST_RESTORE_ONLY[@]}" -gt 0 ] || return 0
  for sel in "${ROOST_RESTORE_ONLY[@]}"; do
    hit=0
    for f in "$ROOST_RESTORE_PD"/*.session "$ROOST_RESTORE_PD"/*.window "$ROOST_RESTORE_PD"/*.pane; do
      [ -e "$f" ] || continue
      a="$(roost_restore__addr "$f")"
      case "$sel" in
        %*)
          [ "${f##*.}" = pane ] && [ "$(roost_shape_get "$f" id)" = "$sel" ] || continue
          keep="$keep$f"$'\n'
          keep="$keep$(roost_restore__block window "${a%.*}")"$'\n'
          keep="$keep$(roost_restore__block session "${a%:*}")"$'\n' ;;
        *:*)
          case "${f##*.}" in
            window) [ "$a" = "$sel" ] || continue ;;
            pane) [ "${a%.*}" = "$sel" ] || continue ;;
            *) continue ;;
          esac
          keep="$keep$f"$'\n'
          keep="$keep$(roost_restore__block session "${sel%:*}")"$'\n' ;;
        *)
          case "${f##*.}" in
            session)
              if [ "$a" != "$sel" ]; then
                # A later member comes with its first member.
                [ "$(roost_shape_get "$f" group 2>/dev/null)" = "$sel" ] || continue
              fi ;;
            *) [ "${a%%:*}" = "$sel" ] || continue ;;
          esac
          keep="$keep$f"$'\n' ;;
      esac
      hit=1
    done
    if [ "$hit" = 0 ]; then
      printf 'roost restore: --only %s matches nothing in the save; nothing done\n' "$sel" >&2
      return 2
    fi
  done
  # A later member kept without its first member joins one already on the
  # server, or the selection is refused whole.
  for f in "$ROOST_RESTORE_PD"/*.session; do
    [ -e "$f" ] || continue
    case "$keep" in *$'\n'"$f"$'\n'*) ;; *) continue ;; esac
    g="$(roost_shape_get "$f" group 2>/dev/null)" || continue
    i="$(roost_restore__block session "$g")"
    case "$keep" in *$'\n'"$i"$'\n'*) continue ;; esac
    if server_running; then
      ROOST_SHAPE_TFLAG="$_SOCKET_FLAG" ROOST_SHAPE_TSOCK="$SOCKET"
      roost_shape__read_rules || true
      roost_restore__names
      roost_restore__exists "$g" && continue
    fi
    printf "roost restore: --only %s: it joins %s's group, and %s is neither selected nor on the server; nothing done\n" \
      "$(roost_restore__addr "$f")" "$g" "$g" >&2
    return 16
  done
  for f in "$ROOST_RESTORE_PD"/*; do
    case "$f" in *.header) continue ;; esac
    case "$keep" in *$'\n'"$f"$'\n'*) ;; *) rm -f "$f" ;; esac
  done
  return 0
}

# roost_restore__block KIND ADDRESS -> the block file of that kind and address.
roost_restore__block() {
  local f
  for f in "$ROOST_RESTORE_PD"/*."$1"; do
    [ -e "$f" ] || continue
    [ "$(roost_restore__addr "$f")" = "$2" ] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

# roost_restore__action BLOCK -> "HARNESS|ACTION", the tree's last two columns
# for a pane (§4.3 --dry-run; §5.6's and §5.1a's words for a reason). In
# Part 1 every pane was placed as a shell. From Part 3 a pane that will be
# resumed says `resume` — decided by the same rule placement uses
# (roost_restore__will_resume: --no-resume and --recent included) — and a
# keyed pane whose directory is gone makes the dry run's exit 13, as the
# real run's (ROOST_RESTORE_NOTRES). The store is not read here: a store
# miss is the loop's, after placement.
roost_restore__action() {
  local h r sh gone=0 d
  d="$(roost_shape_get "$1" cwd)"
  [ -d "$d" ] || gone=1
  if h="$(roost_shape_get "$1" harness)"; then
    if [ "$gone" = 1 ]; then
      printf '%s|shell in ~, not resumed: directory gone\n' "$h"
      # The real run's 13 is for a pane that HAD a key (§8.1 test 3; fix
      # round 2): a harness with no session id in a gone directory exits 0,
      # as it does with its directory present (roost_restore__not_resumed).
      if [ "${ROOST_RESTORE_NORESUME:-0}" != 1 ] && roost_shape_get "$1" session_id >/dev/null 2>&1; then
        ROOST_RESTORE_NOTRES=1
      fi
    elif ! roost_shape_get "$1" session_id >/dev/null 2>&1; then
      # A harness with no session id: §4.3's `no key`. Before Part 6 this
      # fell through to will_resume's refusal and read "older than --recent".
      printf '%s|shell, not resumed: no key\n' "$h"
    elif roost_restore__will_resume "$1"; then printf '%s|resume\n' "$h"
    elif [ "${ROOST_RESTORE_NORESUME:-0}" = 1 ]; then printf '%s|shell, not resumed: --no-resume\n' "$h"
    else printf '%s|shell, not resumed: older than --recent %s days\n' "$h" "${ROOST_RESTORE_RECENT:-}"; fi
  elif r="$(roost_shape_get "$1" stale_reason)"; then
    sh="$(roost_shape_get "$1" stale_harness)"
    if [ "$gone" = 1 ]; then printf -- '-|shell in ~, not resumed: directory gone\n'
    else printf -- '-|shell, not resumed: stale (%s %s)\n' "$r" "$sh"; fi
  elif h="$(roost_restore__cmd_harness "$1")"; then
    # No identity, and a command that names a harness (#191 Part 6, §5.6): the
    # pane ran an agent roost has no key for, which the report names too. A
    # gone directory is said, and is no 13: no key, nothing to resume (fix
    # round 2; roost_restore__not_resumed).
    if [ "$gone" = 1 ]; then printf '%s|shell in ~, not resumed: directory gone\n' "$h"
    else printf '%s|shell, not resumed: no key\n' "$h"; fi
  elif [ "$gone" = 1 ]; then printf -- '-|shell in ~: directory gone\n'
  else printf -- '-|shell\n'; fi
}

# roost_restore__renumbers -> exit 0 when the tmux conf renumbers windows,
# which moves them off their saved indices (§4.3 Windows). Read from the
# running server when there is one, else from the user's roost conf.
roost_restore__renumbers() {
  if server_running; then
    [ "$(t -u show-options -gqv renumber-windows 2>/dev/null || true)" = on ]
    return
  fi
  grep -qs '^[[:space:]]*set[a-z-]*[[:space:]].*renumber-windows[[:space:]]*on' \
    "${XDG_CONFIG_HOME:-$HOME/.config}/roost/roost.conf" "$CONF"
}

# roost_restore_dry_run -> prints the plan as one tree (§4.3 --dry-run,
# revision 6: the one format, so the restore offer reuses it) and returns the
# exit code the real run would give. Reads files only: it never starts a
# server, and with no server running it skips nothing as existing.
#
# ROOST_RESTORE_DRY_S, _W, _P, _K and _R count, as it prints them, the
# sessions it would make (a group's later member included), windows, panes,
# panes with a key, and panes it would resume: the restore offer's summary
# (§4.8) is these counts, so it can never disagree with the tree under it.
roost_restore_dry_run() {
  local f a rc=0 name g wf pf idx wn n pn h act running=0
  ROOST_RESTORE_NOTRES=0
  ROOST_RESTORE_DRY_S=0 ROOST_RESTORE_DRY_W=0 ROOST_RESTORE_DRY_P=0 ROOST_RESTORE_DRY_K=0 ROOST_RESTORE_DRY_R=0
  server_running && running=1
  if [ "$running" = 1 ]; then
    ROOST_SHAPE_TFLAG="$_SOCKET_FLAG" ROOST_SHAPE_TSOCK="$SOCKET"
    roost_shape__read_rules || true
    roost_restore__names
  else
    ROOST_RESTORE_NAMES=$'\n'
  fi
  printf 'from %s (%s; %s)\n' "$(roost_restore__stampgen "$ROOST_RESTORE_FILE")" "$ROOST_RESTORE_WHY" \
    "$(roost_restore__ago "$(roost_restore__hdr "$ROOST_RESTORE_FILE" saved)")"
  for f in "$ROOST_RESTORE_PD"/*.session; do
    [ -e "$f" ] || continue
    name="$(roost_restore__addr "$f")"
    if g="$(roost_shape_get "$f" group)"; then
      if roost_restore__exists "$name"; then printf 'session %s (exists - skipped)\n' "$name"; rc=12
      else printf "session %s (joins %s's group)\n" "$name" "$g"; ROOST_RESTORE_DRY_S=$((ROOST_RESTORE_DRY_S + 1)); fi
      continue
    fi
    n=0
    while IFS= read -r wf; do
      [ -n "$wf" ] && n=$((n + $(roost_restore__panes "$(roost_restore__addr "$wf")" | grep -c .)))
    done <<< "$(roost_restore__windows "$name")"
    if roost_restore__exists "$name"; then
      printf 'session %s (exists - skipped, %s panes not restored)\n' "$name" "$n"; rc=12; continue
    fi
    printf 'session %s\n' "$name"
    ROOST_RESTORE_DRY_S=$((ROOST_RESTORE_DRY_S + 1))
    while IFS= read -r wf; do
      [ -n "$wf" ] || continue
      a="$(roost_restore__addr "$wf")"; idx="${a##*:}"
      wn="$(roost_shape_get "$wf" name)" || wn="-"
      printf '  window %s %s\n' "$idx" "$wn"
      ROOST_RESTORE_DRY_W=$((ROOST_RESTORE_DRY_W + 1))
      while IFS= read -r pf; do
        [ -n "$pf" ] || continue
        pn="$(roost_shape_get "$pf" name)" || pn="-"
        # Not in a $(...): the action sets ROOST_RESTORE_NOTRES in this shell.
        roost_restore__action "$pf" > "$ROOST_RESTORE_PD/.act"
        act="$(cat "$ROOST_RESTORE_PD/.act")"; h="${act%%|*}" act="${act#*|}"
        printf '    pane %s %-12s %-30s %-8s %s\n' "$(roost_restore__addr "$pf" | sed 's/.*\.//')" \
          "$pn" "$(roost_shape_get "$pf" cwd)" "$h" "$act"
        ROOST_RESTORE_DRY_P=$((ROOST_RESTORE_DRY_P + 1))
        roost_shape_get "$pf" session_id >/dev/null 2>&1 && ROOST_RESTORE_DRY_K=$((ROOST_RESTORE_DRY_K + 1))
        [ "$act" = resume ] && ROOST_RESTORE_DRY_R=$((ROOST_RESTORE_DRY_R + 1))
        # §5.6's store listing, indented under the pane it is for (#191 Part
        # 6): the same lines the real run's report prints, without its
        # header, since the pane line above already says why. Printed, never
        # run, here as there. A directory that is gone has nothing to list.
        if [ -d "$(roost_shape_get "$pf" cwd)" ] && roost_restore__listing_of "$pf"; then
          roost_resume_listing "$ROOST_RESTORE_LH" "$ROOST_RESTORE_LD" "$ROOST_RESTORE_LS" | sed 's/^/      /' || true
        fi
      done <<< "$(roost_restore__panes "$a")"
    done <<< "$(roost_restore__windows "$name")"
  done
  if roost_restore__renumbers; then
    printf 'note: renumber-windows is on in your tmux conf, so windows will not keep their saved indices\n'
  fi
  # The real run's 13 for a keyed pane whose directory is gone; 12 wins.
  [ "${ROOST_RESTORE_NOTRES:-0}" = 1 ] && [ "$rc" = 0 ] && rc=13
  return "$rc"
}

# roost_restore__bootgen FILE -> "BOOT GEN" from a save's header: what names
# one save, whatever file holds it (§4.8: `declined` is matched by its
# header's boot and gen, never by boot alone, which every save of one
# server's run shares).
roost_restore__bootgen() { printf '%s %s\n' "$(roost_restore__hdr "$1" boot)" "$(roost_restore__hdr "$1" gen)"; }

# roost_restore_list SHAPEDIR -> prints every save (§3.6 --list): `shape`,
# then `history/` newest first, one line each with its STAMP-GEN, trigger
# and counts; `*` marks the one a restore with no --from picks. The save a
# person declined at the restore offer (§4.8) is marked `declined`, and when
# the ring has dropped it — it is in neither `shape` nor history/ — it is
# listed last, from `declined` itself, since `--from STAMP-GEN` still finds
# it there (F N9).
roost_restore_list() {
  local sdir="$1" f mark where pick="" dbg="" dseen=0
  if [ -z "$sdir" ] || { [ ! -f "$sdir/shape" ] && [ ! -d "$sdir/history" ] && [ ! -f "$sdir/declined" ]; }; then
    printf 'roost restore: no saves for this server\n'
    roost_restore__list_pending "$sdir"
    return 0
  fi
  # The one the reading rule picks (§3.6 steps 1 to 3), marked `*`.
  if [ -f "$sdir/shape" ]; then roost_restore__reading_rule "$sdir"; pick="$ROOST_RESTORE_FILE"; fi
  # The declined save, and whether the ring still holds it: decided here,
  # before the listing's pipe, whose loop runs in a subshell and could not
  # tell this shell what it saw.
  if [ -f "$sdir/declined" ]; then
    dbg="$(roost_restore__bootgen "$sdir/declined")"
    for f in "$sdir/shape" "$sdir"/history/*; do
      [ -f "$f" ] && [ "$(roost_restore__bootgen "$f")" = "$dbg" ] && { dseen=1; break; }
    done
  fi
  { [ -f "$sdir/shape" ] && printf '%s\n' "$sdir/shape"
    # `|| true`: with no history/ yet `ls` fails, and under bin/roost's
    # `set -e -o pipefail` that failure ended --list before the rest of it
    # ran (found by Task 3.11, whose pending listing comes after this loop).
    ls -1 "$sdir/history" 2>/dev/null | sort -r | while IFS= read -r f; do printf '%s\n' "$sdir/history/$f"; done || true
    [ -n "$dbg" ] && [ "$dseen" = 0 ] && printf '%s\n' "$sdir/declined"
  } | while IFS= read -r f; do
    [ -f "$f" ] || continue
    if [ "$f" = "$sdir/shape" ]; then where="shape"
    elif [ "$f" = "$sdir/declined" ]; then where="kept only as declined"
    else where="history"; fi
    if [ "$f" = "$pick" ]; then mark="*" where="$where (restore picks this)"; else mark=" "; fi
    if [ -n "$dbg" ] && [ "$(roost_restore__bootgen "$f")" = "$dbg" ]; then
      where="$where; declined at the restore offer"
    fi
    printf '%s %s  %s  %s sessions, %s windows, %s panes  %s\n' "$mark" "$(roost_restore__stampgen "$f")" \
      "$(roost_restore__hdr "$f" trigger)" "$(grep -c '^session ' "$f")" "$(grep -c '^window ' "$f")" \
      "$(grep -c '^pane ' "$f")" "$where"
    # Its sessions, by name; a later member of a group once, as joining its
    # group (ruling R7: --list names a member the way --dry-run does).
    printf '    sessions: %s\n' "$(awk -v RS= '/^session / {
        n = $0; sub(/^session /, "", n); sub(/\n.*/, "", n)
        g = ""; if (match($0, /\ngroup [^\n]*/)) g = substr($0, RSTART + 7, RLENGTH - 7)
        printf "%s%s%s", (c++ ? ", " : ""), n, (g != "" ? " (joins " g "'"'"'s group)" : "")
      }' "$f")"
  done
  roost_restore__list_pending "$sdir"
  return 0
}

# roost_restore__list_pending SHAPEDIR — the pending record (§4.3 --list,
# §4.6): every file under pending/<boot>/, one line each with its name, its
# state (roost_pending_state), its key and old pane, and a failed file's
# reason — so a `.launching`, `.failed` or `.taken` file is never invisible.
roost_restore__list_pending() {
  local d f st first h i was
  [ -n "${1:-}" ] && [ -d "$1/pending" ] || return 0
  for d in "$1"/pending/*/; do
    [ -d "$d" ] || continue
    printf 'pending resumes (boot %s):\n' "$(basename "$d")"
    for f in "$d"%*; do
      [ -f "$f" ] || continue
      st="$(roost_pending_state "$f" || printf 'unknown')"
      roost_pending__get "$f" harness; h="$ROOST_PENDING_V"
      roost_pending__get "$f" session_id; i="$ROOST_PENDING_V"
      roost_pending__get "$f" was; was="$ROOST_PENDING_V"
      first=""
      case "$f" in *.failed) IFS= read -r first < "$f" || true ;; esac
      printf '  %-14s %-18s %s %s (was %s)%s\n' "${f##*/}" "$st" "$h" "$i" "$was" "${first:+  $first}"
    done
  done
}
