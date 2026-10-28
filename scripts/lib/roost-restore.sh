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
# A WINDOW name is the opposite case and never goes through this: `new-window
# -n` stores what it is given (3.4 escapes only a raw control byte, which a
# saved name cannot hold), so the saved name is passed as it is — measured
# exact on all three builds; undoing it there made it drift.
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
  done <<< "$(t list-sessions -F '#{session_name}' 2>/dev/null || true)"
}

# roost_restore__exists NAME -> exit 0 when a session of that saved name is on
# the server. tmux stores `.` and `:` in a session name as `_` (probe 1.4), so
# a hand-edited `v3.69-x` is the session `v3_69-x`: compared both ways, it is
# never made a second time.
roost_restore__exists() {
  local m="${1//./_}"
  m="${m//:/_}"
  case "$ROOST_RESTORE_NAMES" in *$'\n'"$1"$'\n'*|*$'\n'"$m"$'\n'*) return 0 ;; esac
  return 1
}

# roost_restore__sid NAME -> prints the id of the session of that saved name.
# A target is never built from a saved name (probe 1.4: `=NAME:INDEX` falls
# back to a window NAMED like the index when the index is missing); every
# target after this is the id.
roost_restore__sid() {
  local id n m="${1//./_}"
  m="${m//:/_}"
  while IFS=' ' read -r id n; do
    roost_shape__clean "$n" || true
    if [ "$ROOST_SHAPE_V" = "$1" ] || [ "$ROOST_SHAPE_V" = "$m" ]; then printf '%s\n' "$id"; return 0; fi
  done <<< "$(t list-sessions -F '#{session_id} #{session_name}' 2>/dev/null || true)"
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
roost_restore__size() {
  local f l c w=0 h=0 cw ch
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    l="$(roost_shape_get "$f" layout)" || continue
    c="${l#*,}"; c="${c%%,*}"
    cw="${c%x*}" ch="${c#*x}"
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

# roost_restore__new_file -> ROOST_RESTORE_F, a fresh restoring/place.<n>,
# made. SETS rather than prints: the counter has to move in the caller's
# shell, and a $(...) would count in a subshell and hand every pane the same
# file (measured: every split pane got place.1, and only one could win it).
roost_restore__new_file() {
  ROOST_RESTORE_N=$((ROOST_RESTORE_N + 1))
  ROOST_RESTORE_F="$ROOST_RESTORE_RD/place.$ROOST_RESTORE_N"
  : > "$ROOST_RESTORE_F"
}

# roost_restore__shell_cmd -> sets ROOST_RESTORE_SHELL_ARGS (an array): the
# command a SHELL pane is respawned with. default-command's value as ONE
# string, ensure_session's form, read once after `roost wiring apply`: a bare
# `respawn-pane` re-runs the pane's creation command — the placeholder — and
# ignores default-command (measured on tmux 3.6). Empty (wiring off) →
# default-shell and `-l` as argv, what tmux runs for an empty default-command.
roost_restore__shell_cmd() {
  local dc ds
  dc="$(t show-options -gqv default-command 2>/dev/null || true)"
  if [ -n "$dc" ]; then ROOST_RESTORE_SHELL_ARGS=("$dc"); return 0; fi
  ds="$(t show-options -gqv default-shell 2>/dev/null || true)"
  ROOST_RESTORE_SHELL_ARGS=("${ds:-${SHELL:-/bin/sh}}" -l)
}

# roost_restore__placing STARTCOMMAND BASE -> exit 0 when a pane's start
# command is the placing placeholder for the file named BASE (`place.3`,
# `bootstrap`). tmux prints an argv command with double quotes round an
# argument that holds a space (measured, tmux 3.6), so quotes and backslashes
# are dropped before the compare, and the name must be followed by exactly
# ` --placing` at the end: `place.1` never matches `place.10`.
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
  sc="$(t display-message -p -t "$1" '#{pane_start_command}' 2>/dev/null || true)"
  if ! roost_restore__placing "$sc" "${2##*/}"; then
    mv "$2.used" "$2.taken" 2>/dev/null || true
    return 2
  fi
  return 0
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
roost_restore__settle_dead() {
  local f base id sc dir
  for f in "$ROOST_RESTORE_RD"/bootstrap "$ROOST_RESTORE_RD"/bootstrap.used \
           "$ROOST_RESTORE_RD"/place.* ; do
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
      dir="$(t display-message -p -t "$id" '#{pane_current_path}' 2>/dev/null || true)"
      t set-option -pu -t "$id" remain-on-exit 2>/dev/null || true
      t respawn-pane -k -t "$id" -c "${dir:-${HOME:-/}}" "${ROOST_RESTORE_SHELL_ARGS[@]}" 2>/dev/null || true
    done <<< "$(t list-panes -a -F '#{pane_id} #{pane_start_command}' 2>/dev/null || true)"
  done
  find "$ROOST_RESTORE_RD" -mindepth 1 ! -name owner -exec rm -f {} + 2>/dev/null || true
}

# roost_restore__window_first SID WID SAVEDINDEX — the first window of a
# session restore made takes its saved index: new-session puts it at
# base-index, and a sparse set or another base-index must come back as saved
# (§4.3 Windows).
roost_restore__window_first() {
  local cur
  cur="$(t display-message -p -t "$2" '#{window_index}' 2>/dev/null || true)"
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
    done <<< "$(t list-panes -t "$wid" -F '#{pane_id} #{pane_width} #{pane_height}' 2>/dev/null || true)"
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
  while IFS= read -r id; do [ -n "$id" ] && panes+=("$id"); done <<< "$(t list-panes -t "$wid" -F '#{pane_id}' 2>/dev/null || true)"
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
      roost_restore__respawn "$id" "$out"; zp=0
    else
      zp=0; roost_restore_place_pane "$id" "$f" "$out" || zp=$?
    fi
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
    f="$ROOST_RESTORE_RD/bootstrap"; : > "$f"
    # The server's first session, started the way ensure_session starts one
    # (-f CONF), at the saved size, with the placing placeholder by its own
    # path as its one pane (§4.3 Server, §2.10).
    out="$(t -f "$CONF" new-session -d -P -F '#{session_id} #{window_id} #{pane_id}' \
      -s "$(roost_restore__unvis "$name")" ${nflag[@]+"${nflag[@]}"} -c "$cwd" -x "$w" -y "$h" \
      "$ROOST_HOME/scripts/roost-placeholder" "$f" --placing 2>/dev/null)" || return 1
  else
    roost_restore__new_file; f="$ROOST_RESTORE_F"
    out="$(t new-session -d -P -F '#{session_id} #{window_id} #{pane_id}' \
      -s "$(roost_restore__unvis "$name")" ${nflag[@]+"${nflag[@]}"} -c "$cwd" -x "$w" -y "$h" \
      "$ROOST_HOME/scripts/roost-placeholder" "$f" --placing 2>/dev/null)" || {
        printf "roost restore: session '%s' could not be made — skipped, %s panes not restored\n" "$name" "$npanes" >&2
        return 12; }
  fi
  sid="${out%% *}" out="${out#* }" wid="${out%% *}" pane="${out#* }"
  t set-option -p -t "$pane" remain-on-exit failed 2>/dev/null || true
  if [ "$boot" = 1 ]; then
    roost_restore__hold ROOST_TEST_RESTORE_HOLD
    server_init
    roost_restore__shell_cmd
    # Replaceable only when this run made it, wins the rename, and it still
    # holds the one pane restore made (§4.3). Lost: a key took it, the pane
    # is the person's, and the saved session is skipped by name.
    r=0; roost_restore__claim "$pane" "$f" || r=$?
    if [ "$r" = 0 ] && [ "$(t list-panes -s -t "$sid" -F x 2>/dev/null | grep -c .)" != 1 ]; then
      mv "$f.used" "$f.taken" 2>/dev/null || true; r=2
    fi
    if [ "$r" != 0 ]; then
      printf "roost restore: session '%s' skipped: the bootstrap pane was taken by a key — %s panes not restored (tmux kill-session -t NAME, then roost restore --only NAME)\n" "$name" "$npanes" >&2
      return 12
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
      # The window name goes in as saved: `new-window -n` stores it as given,
      # where undoing tmux's escaping would make it drift (R8.3, measured).
      out="$(t new-window -d -P -F '#{window_id} #{pane_id}' -t "$sid:$idx" ${nf[@]+"${nf[@]}"} \
        -c "$(roost_restore__cwd "$pfirst" 2>/dev/null)" \
        "$ROOST_HOME/scripts/roost-placeholder" "$f" --placing 2>/dev/null)" || {
          printf 'roost restore: window %s could not be made; its panes are not restored\n' "$(roost_restore__addr "$wf")" >&2
          rc=13; continue; }
      wid="${out%% *}" pane="${out#* }"
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
# saved session skipped as existing; 16 the file refused (nothing done); 1 a
# live restore holds `restoring/`.
roost_restore_run() {
  local file="$1" sdir="$2" rc=0 r blk boot=0 own
  if ! roost_shape_check "$file"; then
    printf 'roost restore: %s: %s; nothing done\n' "$file" "$ROOST_SHAPE_FAULT" >&2
    return 16
  fi
  ROOST_RESTORE_PD="$(mktemp -d)"
  roost_shape_parse "$file" "$ROOST_RESTORE_PD" || { rm -rf "$ROOST_RESTORE_PD"; return 1; }
  # restoring/ lives in the server's shape directory, where the saver (Part 4)
  # looks for it; with saving off there is no saver to hold off, and the run's
  # files go to a directory of its own.
  if [ -n "$sdir" ]; then ROOST_RESTORE_RD="$sdir/restoring"
  else ROOST_RESTORE_RD="$(mktemp -d)/restoring"; fi
  ROOST_RESTORE_N=0 ROOST_RESTORE_SESSIONS=0 ROOST_RESTORE_WINDOWS=0 ROOST_RESTORE_PANES=0
  ROOST_SHAPE_TFLAG="$_SOCKET_FLAG" ROOST_SHAPE_TSOCK="$SOCKET"
  own=0; roost_shape_owner_take "$ROOST_RESTORE_RD" || own=$?
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
    find "$ROOST_RESTORE_RD" -mindepth 1 ! -name owner -exec rm -f {} + 2>/dev/null || true
    boot=1
  fi
  roost_restore__names
  # Full sessions first, in file order; the first one starts the server when
  # it is not running. Then the later members of groups, which join them.
  for blk in "$ROOST_RESTORE_PD"/*.session; do
    [ -e "$blk" ] || continue
    roost_shape_get "$blk" group >/dev/null && continue
    r=0; roost_restore__make_session "$blk" "$boot" || r=$?
    if [ "$boot" = 1 ]; then
      boot=0
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
  roost_shape_owner_drop "$ROOST_RESTORE_RD"
  rm -rf "$ROOST_RESTORE_PD"
  return "$rc"
}
