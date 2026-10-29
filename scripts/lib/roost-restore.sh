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
# In Part 1 restore PLACES ONLY: every pane comes back as a shell in its saved
# directory, and a pane's agent key stays in the shape for Part 3.
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
# session NAME. Up to tmux 3.7a, `.` and `:` are stored as `_` (probe 1.4),
# so a hand-edited `v3.69-x` is the session `v3_69-x`; from 3.7b both are
# kept (CHANGES 3.7b; measured on 3.8, docs/airig/probes/persist-1-tmux38.md),
# and `v3.69-x` and `v3_69-x` are two sessions. The rule is the server's
# version, read once: a test session made only to see how its name is stored
# would run a person's session-created hooks. A version this cannot read
# (`master`, `next-3.9`) is a newer tmux, which keeps them. Learned by
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
roost_restore__learn_dots() {
  case "$(t -u display-message -p '#{version}' 2>/dev/null || true)" in
    [0-2].*|3.[0-6]|3.[0-6][a-z]|3.7|3.7a) ROOST_RESTORE_MAPDOTS=1 ;;
    *) ROOST_RESTORE_MAPDOTS=0 ;;
  esac
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
# only as the old form, a 3.8 layout gave no size, the session was made
# 80x24, and its saved layout could not apply.
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
roost_restore_place_pane() {
  roost_restore__claim "$1" "$2" || return $?
  roost_restore__respawn "$1" "$3"
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
roost_restore__respawn_claimed() {
  if roost_restore__placing "$(t -u display-message -p -t "$1" '#{pane_start_command}' 2>/dev/null || true)" "${2##*/}"; then
    roost_restore__respawn "$1" "$3"
    return 0
  fi
  mv "$2.used" "$2.taken" 2>/dev/null || true
  return 2
}

# roost_restore__respawn PANE CWD -> step (iv): a shell in CWD.
roost_restore__respawn() {
  t set-option -pu -t "$1" remain-on-exit 2>/dev/null || true
  t respawn-pane -k -t "$1" -c "$2" "${ROOST_RESTORE_SHELL_ARGS[@]}" 2>/dev/null || true
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
  local -a blocks panes
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
      zp=0; roost_restore__respawn_claimed "$id" "$f" "$out" || zp=$?
    else
      zp=0; roost_restore_place_pane "$id" "$f" "$out" || zp=$?
    fi
    # A pane restore leaves to a person is named: restoring/, with each
    # file's .taken rename, is removed when restore ends (§3.5 step 4), so
    # this line is the record of which saved pane went where.
    case "$zp" in
      1) printf 'roost restore: pane %s (%s) was taken by a key during placement; left as it is\n' \
           "$(roost_restore__addr "${blocks[$i]}")" "$id" >&2 ;;
      2) printf 'roost restore: pane %s (%s) was changed by hand during placement; left as it is\n' \
           "$(roost_restore__addr "${blocks[$i]}")" "$id" >&2 ;;
    esac
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
  local -a wins
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
    return 12
  fi
  cwd="$(roost_restore__cwd "$pfirst" 2>/dev/null)"
  size="$(roost_restore__size "$name")"; w="${size% *}" h="${size#* }"
  local -a nflag=()
  wname="$(roost_shape_get "$wfirst" name)" && nflag=(-n "$wname")
  if [ "$boot" = 1 ]; then
    f="$ROOST_RESTORE_RD/bootstrap.$ROOST_RESTORE_RUN"; : > "$f"
    # The server's first session, started the way ensure_session starts one
    # (-f CONF), at the saved size, with the placing placeholder by its own
    # path as its one pane (§4.3 Server, §2.10).
    # A failure here returns 1, which stops the WHOLE run (roost_restore_run):
    # no later session may be made on a server that was not started the roost
    # way (review round 1, Fable B1).
    if ! out="$(t -f "$CONF" new-session -d -P -F '#{session_id} #{window_id} #{pane_id}' \
      -s "$(roost_restore__unvis "$name")" ${nflag[@]+"${nflag[@]}"} -c "$cwd" -x "$w" -y "$h" \
      "$ROOST_HOME/scripts/roost-placeholder" "$f" --placing 2>&1)"; then
      printf "roost restore: could not start the tmux server with session '%s' (%s); nothing restored\n" \
        "$name" "$(printf '%s' "$out" | head -1)" >&2
      return 1
    fi
  else
    roost_restore__new_file; f="$ROOST_RESTORE_F"
    out="$(t new-session -d -P -F '#{session_id} #{window_id} #{pane_id}' \
      -s "$(roost_restore__unvis "$name")" ${nflag[@]+"${nflag[@]}"} -c "$cwd" -x "$w" -y "$h" \
      "$ROOST_HOME/scripts/roost-placeholder" "$f" --placing 2>/dev/null)" || {
        printf "roost restore: session '%s' could not be made — skipped, %s panes not restored\n" "$name" "$npanes" >&2
        return 12; }
  fi
  sid="${out%% *}" out="${out#* }" wid="${out%% *}" pane="${out#* }"
  [ "${#nflag[@]}" -gt 0 ] && roost_restore__window_name "$wid" "$wname"
  t set-option -p -t "$pane" remain-on-exit failed 2>/dev/null || true
  if [ "$boot" = 1 ]; then
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
    case "$r" in
      0) ;;
      1) printf "roost restore: session '%s' skipped: the bootstrap pane was taken by a key — %s panes not restored (tmux kill-session -t NAME, then roost restore --only NAME)\n" "$name" "$npanes" >&2
         return 12 ;;
      *) [ "$r" = 2 ] && printf 'roost restore: pane %s (%s) was changed by hand during placement; left as it is\n' \
           "$(roost_restore__addr "$pfirst")" "$pane" >&2
         printf "roost restore: session '%s' skipped: it was changed by hand during placement — %s panes not restored\n" "$name" "$npanes" >&2
         return 12 ;;
    esac
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
    return 12
  fi
  if ! gid="$(roost_restore__sid "$grp")"; then
    printf "roost restore: session '%s' skipped: %s, whose group it joins, is not on the server\n" "$name" "$grp" >&2
    return 12
  fi
  out="$(t new-session -d -P -F '#{session_id}' -t "$gid" -s "$(roost_restore__unvis "$name")" 2>/dev/null)" || {
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
roost_restore_prepare() {
  local r=0
  if ! roost_shape_check "$1"; then
    printf 'roost restore: %s: %s; nothing done\n' "$1" "$ROOST_SHAPE_FAULT" >&2
    return 16
  fi
  ROOST_RESTORE_PD="$(mktemp -d)"
  roost_shape_parse "$1" "$ROOST_RESTORE_PD" || return 1
  roost_restore__select || r=$?
  return "$r"
}

roost_restore_run() {
  local file="$1" sdir="$2" rc=0 r blk boot=0 own
  # restoring/ lives in the server's shape directory, where the saver (Part 4)
  # looks for it; with saving off there is no saver to hold off, and the run's
  # files go to a directory of its own.
  if [ -n "$sdir" ]; then ROOST_RESTORE_RD="$sdir/restoring"
  else ROOST_RESTORE_RD="$(mktemp -d)/restoring"; fi
  ROOST_RESTORE_N=0 ROOST_RESTORE_SESSIONS=0 ROOST_RESTORE_WINDOWS=0 ROOST_RESTORE_PANES=0
  # This run's token for its file names (roost_restore__new_file): pid,
  # clock and a random number, digits and `-` only, so it never holds the
  # `.` the names are split on. Unique enough across runs: a repeat needs the
  # same pid in the same second and the same 15-bit draw.
  ROOST_RESTORE_RUN="$$-$(date +%s)-$RANDOM"
  ROOST_SHAPE_TFLAG="$_SOCKET_FLAG" ROOST_SHAPE_TSOCK="$SOCKET"
  own=0; roost_shape_owner_take "$ROOST_RESTORE_RD" || own=$?
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
        roost_shape_owner_drop "$ROOST_RESTORE_RD"
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
  roost_shape_owner_drop "$ROOST_RESTORE_RD"
  rm -rf "$ROOST_RESTORE_PD"
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

# roost_restore_pick SHAPEDIR FROM -> ROOST_RESTORE_FILE and
# ROOST_RESTORE_WHY; exit 2 when there is nothing to restore.
#
# Which save (§4.3, §3.6). No --from: this server's `shape` (Part 4 adds the
# reading rule). --from STAMP-GEN: `shape` when it is that save, else
# `history/STAMP-GEN` (Part 7 adds the offer's pin and `declined`). --from
# FILE: that file, the caller's own choice. The SERVER is always the caller's
# (`-L`/`-S`, ROOST_SOCKET), never the file's `socket` line.
roost_restore_pick() {
  local sdir="$1" from="$2"
  ROOST_RESTORE_FILE="" ROOST_RESTORE_WHY="" ROOST_RESTORE_BYFILE=0
  if [ -z "$from" ]; then
    if [ -n "$sdir" ] && [ -f "$sdir/shape" ]; then
      ROOST_RESTORE_FILE="$sdir/shape" ROOST_RESTORE_WHY="the newest save"; return 0
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
# Part 1 every pane is placed as a shell; a key is kept for a later roost
# that resumes.
roost_restore__action() {
  local h r sh gone=0 d
  d="$(roost_shape_get "$1" cwd)"
  [ -d "$d" ] || gone=1
  if h="$(roost_shape_get "$1" harness)"; then
    if [ "$gone" = 1 ]; then printf '%s|shell in ~, not resumed: directory gone\n' "$h"
    else printf '%s|shell, not resumed: this roost places panes only\n' "$h"; fi
  elif r="$(roost_shape_get "$1" stale_reason)"; then
    sh="$(roost_shape_get "$1" stale_harness)"
    if [ "$gone" = 1 ]; then printf -- '-|shell in ~, not resumed: directory gone\n'
    else printf -- '-|shell, not resumed: stale (%s %s)\n' "$r" "$sh"; fi
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
roost_restore_dry_run() {
  local f a rc=0 name g wf pf idx wn n pn h act running=0
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
      else printf "session %s (joins %s's group)\n" "$name" "$g"; fi
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
    while IFS= read -r wf; do
      [ -n "$wf" ] || continue
      a="$(roost_restore__addr "$wf")"; idx="${a##*:}"
      wn="$(roost_shape_get "$wf" name)" || wn="-"
      printf '  window %s %s\n' "$idx" "$wn"
      while IFS= read -r pf; do
        [ -n "$pf" ] || continue
        pn="$(roost_shape_get "$pf" name)" || pn="-"
        act="$(roost_restore__action "$pf")"; h="${act%%|*}" act="${act#*|}"
        printf '    pane %s %-12s %-30s %-8s %s\n' "$(roost_restore__addr "$pf" | sed 's/.*\.//')" \
          "$pn" "$(roost_shape_get "$pf" cwd)" "$h" "$act"
      done <<< "$(roost_restore__panes "$a")"
    done <<< "$(roost_restore__windows "$name")"
  done
  if roost_restore__renumbers; then
    printf 'note: renumber-windows is on in your tmux conf, so windows will not keep their saved indices\n'
  fi
  return "$rc"
}

# roost_restore_list SHAPEDIR -> prints every save (§3.6 --list): `shape`,
# then `history/` newest first, one line each with its STAMP-GEN, trigger
# and counts; `*` marks the one a restore with no --from picks.
roost_restore_list() {
  local sdir="$1" f mark where
  if [ -z "$sdir" ] || { [ ! -f "$sdir/shape" ] && [ ! -d "$sdir/history" ]; }; then
    printf 'roost restore: no saves for this server\n'
    return 0
  fi
  { [ -f "$sdir/shape" ] && printf '%s\n' "$sdir/shape"
    ls -1 "$sdir/history" 2>/dev/null | sort -r | while IFS= read -r f; do printf '%s\n' "$sdir/history/$f"; done
  } | while IFS= read -r f; do
    [ -f "$f" ] || continue
    if [ "$f" = "$sdir/shape" ]; then mark="*" where="shape (restore picks this)"; else mark=" " where="history"; fi
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
  return 0
}
