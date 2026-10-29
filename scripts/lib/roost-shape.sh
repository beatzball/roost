# roost-shape.sh — the saved shape of a server (#51, #191): which directory a
# save goes to, and whether one is written at all.
#
# Sourced by bin/roost. The design, and every measurement these rules rest on,
# is docs/airig/specs/2026-10-24-persistent-sessions-design.md (§3.1 where it
# lives, §3.4a the one switch). Later tasks add the writer, the checker, the
# parser and the saver to this file; the plan's "Names this plan fixes" table
# says which function lives where.
#
# THE LAYOUT, one directory per server:
#
#   <root>/<server key>/
#     shape, history/, gen, ...   (§3.1 lists every file; each lands with the
#                                  task that first writes it)
#
# <root> is roost_shape_saving's answer. <server key> is roost_shape_key's.
# The directory is 0700 and every file in it 0600, because a shape lists every
# project directory and every session id, and a session id alone is enough to
# `--resume` a conversation on a shared machine (§3.1).

# roost_shape_saving -> prints the shape root, or nothing; exit 0 when saving
# is on, 1 when it is off.
#
# THE ONE SWITCH (§3.4a). Every writer of a shape — `roost save`, the hooks,
# the direct calls in roost's own verbs — asks this function first and nothing
# else. That is the whole point of it: if saving ever became opt-in, this is
# the one place that would change, and the spec lists the sections that would
# change with it. Decided by the human on 2026-10-25: only the login service
# is opt-in, saving is always on, so this reads ROOST_SHAPE_DIR and NOTHING
# else — no `persist` marker, no config file.
#
# ROOST_SHAPE_DIR, when SET, wins outright — even when empty, which is how
# tests/lib.sh switches saving off for the whole suite and how a user turns it
# off. It must be absolute; a relative value saves nothing rather than
# scattering shapes into whatever directory a hook happened to run in. Unset,
# the default is $XDG_STATE_HOME/roost/shapes, beside the pane records and the
# extension state, so `rm -rf ~/.local/state/roost` still means "forget
# everything roost remembered" (§3.1, §9 Q3). A relative XDG_STATE_HOME is
# ignored, as the XDG spec says and roost_record_root does; then
# $HOME/.local/state. No usable HOME either: nothing.
#
# Trailing slashes are dropped, and a root that is then empty — "/" — is
# refused, the record's rule: later parts remove directories under this path.
roost_shape_saving() {
  local r x
  if [ "${ROOST_SHAPE_DIR+set}" = set ]; then
    r="$ROOST_SHAPE_DIR"
  else
    x="${XDG_STATE_HOME:-}"
    case "$x" in
      /*) r="$x/roost/shapes" ;;
      *)
        case "${HOME:-}" in
          /*) r="$HOME/.local/state/roost/shapes" ;;
          *) return 1 ;;
        esac ;;
    esac
  fi
  case "$r" in /*) ;; *) return 1 ;; esac
  while :; do
    case "$r" in */) r="${r%/}" ;; *) break ;; esac
  done
  [ -n "$r" ] || return 1
  printf '%s\n' "$r"
}

# roost_shape_key FLAG SOCKET -> prints the server's directory name.
#
# FLAG and SOCKET are bin/roost's own pair (_SOCKET_FLAG and SOCKET): `-L
# NAME` for a named server, `-S PATH` for a socket path.
#
# A `-L NAME` server is keyed NAME (`roost` for the default), because the name
# is what survives a reboot: the socket FILE under /tmp/tmux-UID/ does not, so
# a key built from it would never find the last boot's shape.
#
# A `-S PATH` server is keyed `path-<cksum of PATH>`. Not PATH with `/` written
# as `-`: that is not one-to-one — `/a/b-c` and `/a-b/c` both become `-a-b-c`
# — and two servers would overwrite each other's shape. `cksum` is POSIX and on
# every machine roost runs on; the save's header keeps the readable path. A
# side effect worth having: a test server whose socket FILE is called `roost`
# still never shares a key with the real server.
roost_shape_key() {
  case "$1" in
    -S) printf 'path-%s\n' "$(printf '%s' "$2" | cksum | cut -d' ' -f1)" ;;
    *) printf '%s\n' "$2" ;;
  esac
}

# roost_shape_dir FLAG SOCKET -> prints <root>/<key>, made and set 0700; exit
# 1, printing and making nothing, when saving is off or the directory cannot
# be made.
#
# The root is made 0700 only when this creates it — a ROOST_SHAPE_DIR the
# user made keeps the mode they gave it, and its parents (…/state/roost is
# shared with the pane records and extension state) are not touched; the
# record's rule (roost_record_ensure). The per-server directory is roost's own
# and loses every group and other bit every time (`chmod go-rwx`), so one left
# 0755 by hand stops listing every project to other local users at the next
# save. Only taken away, never added: a directory a person made read-only
# (0500) stays read-only, and the save then fails and names it (§8.1 test 10a)
# instead of roost quietly making it writable again.
#
# The FILES are the writer's half: whoever writes one sets `umask 077` for that
# write. That cannot be done here — callers run this in a $(...) subshell, and
# a umask set in a subshell does not reach the caller.
roost_shape_dir() {
  local root key d
  root="$(roost_shape_saving)" || return 1
  key="$(roost_shape_key "$1" "$2")"
  [ -n "$key" ] || return 1
  d="$root/$key"
  if [ ! -d "$root" ]; then
    mkdir -p "$root" 2>/dev/null || return 1
    chmod 700 "$root" 2>/dev/null || true
  fi
  if [ ! -d "$d" ]; then
    ( umask 077; mkdir -p "$d" ) 2>/dev/null || return 1
  fi
  chmod go-rwx "$d" 2>/dev/null || return 1
  printf '%s\n' "$d"
}

# The agreement table is roost_close_harness's (§3.2 names it), so the two
# can never disagree about what a command is. Sourced by path, relative to
# this file, because tests source this library without bin/roost's
# ROOST_HOME. roost-close.sh only defines functions.
. "$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/roost-close.sh"

# roost_shape_agree HARNESS COMMAND -> prints ok | exited | nested | other.
#
# Is the pane still running the agent whose identity it carries (§3.2)? The
# identity options outlive the agent: an agent that exited leaves them on a
# shell, and a different agent started in the same pane — or run from its
# shell, §2.6's second case — leaves the first one's. A save that wrote them
# as live would restore the wrong conversation. So:
#
#   a shell             -> exited. Holds for all five harnesses, because a
#                          shell's name is known whatever the harness.
#   a harness's command -> ok when it is the one reported, nested when it is
#                          another's (roost_close_harness: Claude's version
#                          string, and the five names).
#   anything else       -> other, except for a harness whose command is not
#                          distinctive: pi reads `node` (probe 1.6, measured),
#                          which any Node program reads, and opencode was not
#                          measured, so those two pass on presence alone, as
#                          §3.2 allows; §10 names the risk. copilot reads
#                          `copilot` (probe 1.6), so it is held to it.
roost_shape_agree() {
  case "$2" in
    sh|bash|zsh|fish|dash) printf 'exited\n'; return 0 ;;
  esac
  roost_close_harness "" "$2" ""
  if [ -n "$ROOST_CLOSE_HARNESS" ]; then
    if [ "$ROOST_CLOSE_HARNESS" = "$1" ]; then printf 'ok\n'; else printf 'nested\n'; fi
    return 0
  fi
  case "$1" in
    pi|opencode) printf 'ok\n' ;;
    *) printf 'other\n' ;;
  esac
}

# roost_shape__t ARGS... — tmux on the server being saved. The flag and socket
# are bin/roost's own pair, set by roost_shape_save.
#
# `-u`, always: the tmux CLIENT decides how a value is printed, and under
# LC_ALL=C or no locale at all it prints a control byte and every non-ASCII
# byte as `_` — a directory holding a newline came out as `n_l`, which the
# writer then saved as if it existed, and a UTF-8 glyph was lost (review round
# 1, B4; measured on tmux 3.2a, 3.4 and 3.6). `-u` tells the client it may
# print UTF-8, and gave the same bytes as a UTF-8 locale on all three builds,
# under C and with no locale set, so no locale has to be found or set. (A
# client started inside tmux assumes UTF-8 anyway, which is why this hid in
# every run from a roost pane.)
roost_shape__t() { tmux -u "$ROOST_SHAPE_TFLAG" "$ROOST_SHAPE_TSOCK" "$@"; }

# roost_shape__read_rules -> sets ROOST_SHAPE_DOLLAR and ROOST_SHAPE_OCTAL.
#
# What this server does to a value when it PRINTS it, learned once per run,
# before the listings (rulings R6 and R8.2, probe 1.3,
# docs/airig/probes/persist-1-control-bytes.md). tmux 3.4 prints every `$`
# with one backslash put before it — in show-options, display and list-* alike,
# with or without #{q:} — and prints ESC and other control bytes in an option
# or a path as `\NNN` octal text; tmux 3.2a and 3.6 print both as they are.
# Without this, a save on 3.4 writes `cwd /x/a\$b` for a pane in `/x/a$b` — a
# directory that does not exist — and keeps a name holding ESC as harmless
# looking text that never was.
#
# So: set one pane option to a known value holding both, read it back, unset
# it, all in one tmux command. No -t: the current pane of whichever session
# tmux picks, which is fine, because any pane answers the question and the
# option is gone before the command returns. Measured on 3.2a, 3.4 and 3.6:
# the target-less form works on a detached server and leaves no pane with the
# option.
roost_shape__read_rules() {
  local out esc
  esc="$(printf '\033')"
  ROOST_SHAPE_DOLLAR=0 ROOST_SHAPE_OCTAL=0
  out="$(roost_shape__t set-option -p @roost-shape-probe "a\$b${esc}c" ';' \
    show-options -pv @roost-shape-probe ';' set-option -pu @roost-shape-probe 2>/dev/null)" || return 1
  case "$out" in *'\$'*) ROOST_SHAPE_DOLLAR=1 ;; esac
  case "$out" in *'\033'*) ROOST_SHAPE_OCTAL=1 ;; esac
  return 0
}

# roost_shape__clean VALUE [octal] -> ROOST_SHAPE_V, the value as the person
# set it; exit 1 when it holds a control character.
#
# R6 first: on a server that prints `\$`, remove exactly one backslash before
# every `$`. A backslash already in the value is not doubled by tmux 3.4
# (`a\$b` prints `a\\$b`), so this undoes the print exactly.
#
# Then the control-byte test, in the C locale so it is a byte test and a UTF-8
# glyph is not a "control character". A value that holds one is never written
# (§3.2: the file holds no control byte); the caller applies Task 1.3's rule
# for its key. With `octal` and a server that prints control bytes as `\NNN`
# (R8.2), any backslash and three octal digits counts as one too — so a
# literal `\033` a person typed is dropped as well: the safe side, and said in
# the docs. `octal` is passed only for pane options and paths: tmux itself
# stores a control byte in a session or window name as escape text on EVERY
# build (probe 1.3), so for names the octal rule would give a different result
# on 3.4 than on 3.6.
roost_shape__clean() {
  local LC_ALL=C v="$1"
  [ "$ROOST_SHAPE_DOLLAR" = 1 ] && v="${v//\\\$/\$}"
  ROOST_SHAPE_V="$v"
  case "$v" in *[[:cntrl:]]*) return 1 ;; esac
  if [ "${2:-}" = octal ] && [ "$ROOST_SHAPE_OCTAL" = 1 ]; then
    case "$v" in *\\[0-7][0-7][0-7]*) return 1 ;; esac
  fi
  return 0
}

# roost_shape__redact LAUNCH -> prints it with every WORD=value whose name
# holds KEY, TOKEN, SECRET or PASSWORD (any case) as WORD=… (§3.2's `launch`).
# The pane option keeps what was handed; only the file is redacted, because
# the file is what gets copied between machines and read by people.
roost_shape__redact() {
  local out="" w n
  local -a words
  IFS=' ' read -r -a words <<< "$1"
  for w in ${words[@]+"${words[@]}"}; do
    case "$w" in
      [A-Za-z_]*=*)
        n="${w%%=*}"
        case "$n" in
          *[!A-Za-z0-9_]*) ;;
          *[Kk][Ee][Yy]*|*[Tt][Oo][Kk][Ee][Nn]*|*[Ss][Ee][Cc][Rr][Ee][Tt]*|*[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]*)
            w="$n=…" ;;
        esac ;;
    esac
    out="${out:+$out }$w"
  done
  printf '%s\n' "$out"
}

# roost_shape__stamp -> prints the save's UTC time, `2026-10-24T20:51:02Z`.
# ROOST_TEST_NOW=EPOCH is the clock when set (the plan's test seam). `date -r`
# is BSD's form and `-d @` GNU's; whichever this machine has.
roost_shape__stamp() {
  if [ -n "${ROOST_TEST_NOW:-}" ]; then
    date -u -r "$ROOST_TEST_NOW" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -d "@$ROOST_TEST_NOW" +%Y-%m-%dT%H:%M:%SZ
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

# The three listings, one line per object, fields separated by a space.
#
# Free text goes through #{q:}, which escapes a space as `\ ` (and a
# backslash, quote, `$`, `#` likewise), so a plain `read` WITHOUT -r splits on
# the unescaped spaces and undoes the escaping in the same step — measured, a
# name with two leading and three trailing spaces comes back byte for byte.
# Each free-text field carries an `x` in front, because an EMPTY field would
# be two spaces in a row and `read` would collapse them and shift every field
# after it. No tab anywhere: tmux 3.4 prints a tab as `_` under a C locale
# (docs/known-gaps.md).
#
# Each line ENDS with `.` and its own id, and starts with it. A newline in a
# value is printed raw — #{q:} does not escape it — so it cuts the line in
# two (probe 1.3, every build). Ruling R8.1: a line that does not start with
# its id, or does not end with `.<the same id>`, is a fault of that round, not
# data. The part that starts with a valid id keeps its own context fields —
# they come before any free text, so a cut never reaches them — and its FREE
# TEXT is read again field by field with `display -p -t ID`, which returns the
# whole value, newline and all, so the control-byte rule sees it; the stray
# part after the cut is skipped.
ROOST_SHAPE_FS='#{session_id} #{session_attached} #{session_grouped} #{window_index} x#{q:session_group} x#{q:session_name} .#{session_id}'
ROOST_SHAPE_FW='#{window_id} #{session_id} #{window_index} #{window_active} #{window_zoomed_flag} #{automatic-rename} #{window_layout} x#{q:window_name} .#{window_id}'
ROOST_SHAPE_FP='#{pane_id} #{session_id} #{window_id} #{pane_index} #{pane_active} x#{q:pane_current_command} x#{q:@agent_state} x#{q:@roost-harness} x#{q:@roost-session} x#{q:@roost-transcript-path} x#{q:@roost-launch} x#{q:@roost-cwd} x#{q:@roost-name} x#{q:pane_current_path} .#{pane_id}'

# roost_shape__suspect LINE -> exit 0 when a listing line must be read again
# field by field. On a server that prints control bytes as `\NNN` (R8.2), the
# backslash of `\033` is NOT #{q:}-escaped — tmux adds it after the quoting —
# so the `read` that undoes #{q:} would eat it and leave `033`, and the octal
# rule could never see it (measured on tmux 3.4: a directory `e<ESC>c` was
# read as `e033c`). Any line holding a backslash and three octal digits is
# therefore read again with `display -p`, whose output nothing unescapes. A
# line where the backslash was a person's own (`\\033` after #{q:}) takes
# the same slow path; the result is the same, only slower.
roost_shape__suspect() {
  [ "$ROOST_SHAPE_OCTAL" = 1 ] || return 1
  case "$1" in *\\[0-7][0-7][0-7]*) return 0 ;; esac
  return 1
}

# roost_shape__d ID FORMAT -> ROOST_SHAPE_D, one value of one object, raw,
# byte for byte. SETS rather than prints, with a sentinel: a $(...) drops every
# trailing newline, the value's own with tmux's, so a name or directory that
# ENDS in a newline lost it and was saved as clean text (review round 1, Codex
# B5). tmux adds exactly one newline after the value; only that one is taken.
roost_shape__d() {
  ROOST_SHAPE_D="$(roost_shape__t display-message -p -t "$1" "$2" 2>/dev/null; printf .)"
  ROOST_SHAPE_D="${ROOST_SHAPE_D%.}"
  ROOST_SHAPE_D="${ROOST_SHAPE_D%$'\n'}"
}

# roost_shape__list -> fills the S_*, W_* and P_* arrays; exit 1 when the
# server cannot be listed. Three listings, then the consistency check of §3.5
# step 2: every pane's window and session, and every window's session, must be
# in the other listings — the three can straddle a split or a kill — else list
# again, at most three times. A round that never agrees publishes nothing.
roost_shape__list() {
  local try=0 ls lw lp
  while [ "$try" -lt 3 ]; do
    try=$((try + 1))
    ls="$(roost_shape__t list-sessions -F "$ROOST_SHAPE_FS" 2>/dev/null)" || return 1
    lw="$(roost_shape__t list-windows -a -F "$ROOST_SHAPE_FW" 2>/dev/null)" || return 1
    lp="$(roost_shape__t list-panes -a -F "$ROOST_SHAPE_FP" 2>/dev/null)" || return 1
    roost_shape__parse_sessions "$ls"
    roost_shape__parse_windows "$lw"
    roost_shape__parse_panes "$lp"
    roost_shape__consistent && return 0
  done
  return 1
}

roost_shape__parse_sessions() {
  local line sid att grp awin xg xn end
  S_ID=() S_ATT=() S_GRP=() S_AWIN=() S_GROUP=() S_NAME=()
  while IFS= read -r line; do
    case "$line" in \$[0-9]*) ;; *) continue ;; esac
    IFS=' ' read sid att grp awin xg xn end <<< "$line"
    if [ "$end" != ".$sid" ] || roost_shape__suspect "$line"; then
      # Only the FREE TEXT is read again: the fields before it are the
      # line's own and a newline cannot reach them (review round 1, Codex B3).
      roost_shape__d "$sid" '#{session_group}'; xg="x$ROOST_SHAPE_D"
      roost_shape__d "$sid" '#{session_name}'; xn="x$ROOST_SHAPE_D"
    fi
    S_ID+=("$sid"); S_ATT+=("$att"); S_GRP+=("$grp"); S_AWIN+=("$awin")
    S_GROUP+=("${xg#x}"); S_NAME+=("${xn#x}")
  done <<< "$1"
}

roost_shape__parse_windows() {
  local line wid sid idx act zoom auto layout xn end
  W_ID=() W_SID=() W_IDX=() W_ACT=() W_ZOOM=() W_AUTO=() W_LAYOUT=() W_NAME=()
  while IFS= read -r line; do
    case "$line" in @[0-9]*) ;; *) continue ;; esac
    IFS=' ' read wid sid idx act zoom auto layout xn end <<< "$line"
    if [ "$end" != ".$wid" ] || roost_shape__suspect "$line"; then
      # Only the name is read again. The fields before it — the session, the
      # index, the layout — are this LINE's own: a linked window is listed
      # once per session, and asked by @N alone tmux answers one of them, so
      # every copy would take that one's address (review round 1, Codex B3:
      # a save then published a repeated address its own checker refused).
      roost_shape__d "$wid" '#{window_name}'; xn="x$ROOST_SHAPE_D"
    fi
    W_ID+=("$wid"); W_SID+=("$sid"); W_IDX+=("$idx"); W_ACT+=("$act"); W_ZOOM+=("$zoom")
    W_AUTO+=("$auto"); W_LAYOUT+=("$layout"); W_NAME+=("${xn#x}")
  done <<< "$1"
}

roost_shape__parse_panes() {
  local line pid sid wid idx act xc xs xh xi xt xl xr xn xp end
  P_ID=() P_SID=() P_WID=() P_IDX=() P_ACT=() P_CMD=() P_STATE=() P_HARNESS=()
  P_SESSION=() P_TRANSCRIPT=() P_LAUNCH=() P_RCWD=() P_NAME=() P_PATH=()
  while IFS= read -r line; do
    case "$line" in %[0-9]*) ;; *) continue ;; esac
    IFS=' ' read pid sid wid idx act xc xs xh xi xt xl xr xn xp end <<< "$line"
    if [ "$end" != ".$pid" ] || roost_shape__suspect "$line"; then
      # The free text only; session, window, index and active are this line's
      # own context (see the window case above, and Codex B3).
      roost_shape__d "$pid" '#{pane_current_command}'; xc="x$ROOST_SHAPE_D"
      roost_shape__d "$pid" '#{@agent_state}'; xs="x$ROOST_SHAPE_D"
      roost_shape__d "$pid" '#{@roost-harness}'; xh="x$ROOST_SHAPE_D"
      roost_shape__d "$pid" '#{@roost-session}'; xi="x$ROOST_SHAPE_D"
      roost_shape__d "$pid" '#{@roost-transcript-path}'; xt="x$ROOST_SHAPE_D"
      roost_shape__d "$pid" '#{@roost-launch}'; xl="x$ROOST_SHAPE_D"
      roost_shape__d "$pid" '#{@roost-cwd}'; xr="x$ROOST_SHAPE_D"
      roost_shape__d "$pid" '#{@roost-name}'; xn="x$ROOST_SHAPE_D"
      roost_shape__d "$pid" '#{pane_current_path}'; xp="x$ROOST_SHAPE_D"
    fi
    P_ID+=("$pid"); P_SID+=("$sid"); P_WID+=("$wid"); P_IDX+=("$idx"); P_ACT+=("$act")
    P_CMD+=("${xc#x}"); P_STATE+=("${xs#x}"); P_HARNESS+=("${xh#x}"); P_SESSION+=("${xi#x}")
    P_TRANSCRIPT+=("${xt#x}"); P_LAUNCH+=("${xl#x}"); P_RCWD+=("${xr#x}"); P_NAME+=("${xn#x}")
    P_PATH+=("${xp#x}")
  done <<< "$1"
}

# roost_shape__consistent -> exit 0 when every pane's (session, window) pair
# is a listed window, every window's session a listed session, and every
# listed session has a listed window. The third: a session killed after
# list-sessions and before list-windows is in the first listing only, and
# without this the round went on to a file the checker refuses (a session
# with no window block) instead of listing again (review round 2, Fable N3).
# `list-windows -a` lists a group's later member's windows under it too, so
# a member is held to the same rule.
roost_shape__consistent() {
  local i j ok
  i=0
  while [ "$i" -lt "${#S_ID[@]}" ]; do
    ok=1; j=0
    while [ "$j" -lt "${#W_SID[@]}" ]; do [ "${W_SID[$j]}" = "${S_ID[$i]}" ] && { ok=0; break; }; j=$((j + 1)); done
    [ "$ok" = 0 ] || return 1
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "${#W_ID[@]}" ]; do
    ok=1; j=0
    while [ "$j" -lt "${#S_ID[@]}" ]; do [ "${S_ID[$j]}" = "${W_SID[$i]}" ] && { ok=0; break; }; j=$((j + 1)); done
    [ "$ok" = 0 ] || return 1
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "${#P_ID[@]}" ]; do
    ok=1; j=0
    while [ "$j" -lt "${#W_ID[@]}" ]; do
      [ "${W_ID[$j]}" = "${P_WID[$i]}" ] && [ "${W_SID[$j]}" = "${P_SID[$i]}" ] && { ok=0; break; }
      j=$((j + 1))
    done
    [ "$ok" = 0 ] || return 1
    i=$((i + 1))
  done
  return 0
}

# roost_shape__home -> the home directory's absolute path, for a cwd the file
# cannot hold. Expanded by the writer, never the four characters `$HOME`:
# the file is data, and nothing in it is ever evaluated (§3.2).
roost_shape__home() {
  case "${HOME:-}" in /*) printf '%s\n' "$HOME" ;; *) printf '/\n' ;; esac
}

# roost_shape__body -> prints every block (no header) on stdout, the
# control-byte lines on stderr, and sets ROOST_SHAPE_COUNTS.
#
# Order: sessions by id (creation order — what restore recreates first),
# then each full session's windows by index, each window's panes by index.
#
# A SESSION GROUP (ruling R7, the human's choice, probe 1.2): tmux lists a
# group once per member with the same window and pane ids. Groups are keyed on
# #{session_group} — never #{window_linked}, which reads 0 for a group's
# windows on 3.2a and 3.4 and 1 on 3.6. The member with the lowest session id
# is the first member and is written in full; every later member is one
# session block with its own keys and `group <first member's name>`, and none
# of its windows or panes, so no pane is written twice and restore makes one
# copy of each. A window linked into two sessions OUTSIDE a group is still
# written under each (§3.2).
roost_shape__body() {
  local i j k n first fname ns=0 nw=0 np=0 na=0 nk=0 sid wid v agree home
  local -a order
  home="$(roost_shape__home)"
  # Sessions sorted by the number in their id.
  i=0
  while [ "$i" -lt "${#S_ID[@]}" ]; do order+=("${S_ID[$i]#\$} $i"); i=$((i + 1)); done
  for n in $(printf '%s\n' ${order[@]+"${order[@]}"} | sort -n -k1,1 | while read -r _ x; do printf '%s\n' "$x"; done); do
    sid="${S_ID[$n]}"
    roost_shape__clean "${S_NAME[$n]}" || true
    printf 'session %s\nid %s\n' "$ROOST_SHAPE_V" "$sid"
    ns=$((ns + 1))
    first=""
    if [ "${S_GRP[$n]}" = 1 ] && [ -n "${S_GROUP[$n]}" ]; then
      # The first member is the lowest id carrying the same group name.
      k=0; first="$n"
      while [ "$k" -lt "${#S_ID[@]}" ]; do
        if [ "${S_GRP[$k]}" = 1 ] && [ "${S_GROUP[$k]}" = "${S_GROUP[$n]}" ] \
           && [ "${S_ID[$k]#\$}" -lt "${S_ID[$first]#\$}" ]; then first="$k"; fi
        k=$((k + 1))
      done
      [ "$first" = "$n" ] && first=""
    fi
    if [ -n "$first" ]; then
      roost_shape__clean "${S_NAME[$first]}" || true
      printf 'group %s\nactive_window %s\n' "$ROOST_SHAPE_V" "${S_AWIN[$n]}"
      [ "${S_ATT[$n]:-0}" -gt 0 ] 2>/dev/null && printf 'active 1\n'
      printf '\n'
      continue
    fi
    [ "${S_ATT[$n]:-0}" -gt 0 ] 2>/dev/null && printf 'active 1\n'
    printf '\n'
    j=0
    while [ "$j" -lt "${#W_ID[@]}" ]; do
      if [ "${W_SID[$j]}" = "$sid" ]; then
        wid="${W_ID[$j]}"
        roost_shape__clean "${S_NAME[$n]}" || true
        printf 'window %s:%s\nid %s\n' "$ROOST_SHAPE_V" "${W_IDX[$j]}" "$wid"
        nw=$((nw + 1))
        # A name only when a person or roost set it: an automatic name (a
        # shell's, `zsh`) would come back pinned and stop following the pane.
        if [ "${W_AUTO[$j]}" != 1 ]; then
          if roost_shape__clean "${W_NAME[$j]}"; then printf 'name %s\n' "$ROOST_SHAPE_V"
          else printf 'roost save: window %s: its name holds a control character; name not saved\n' "$wid" >&2; fi
        fi
        printf 'layout %s\n' "${W_LAYOUT[$j]}"
        # The layout string does not carry the zoom (probe 1.1): saved as read,
        # never unzoomed to save, and the flag kept beside it.
        [ "${W_ZOOM[$j]}" = 1 ] && printf 'zoomed 1\n'
        [ "${W_ACT[$j]}" = 1 ] && printf 'active 1\n'
        printf '\n'
        k=0
        while [ "$k" -lt "${#P_ID[@]}" ]; do
          if [ "${P_WID[$k]}" = "$wid" ] && [ "${P_SID[$k]}" = "$sid" ]; then
            roost_shape__pane "$k" "$n" "${W_IDX[$j]}" "$home"
            np=$((np + 1))
            case "$ROOST_SHAPE_PANE_KIND" in conv) na=$((na + 1)) ;; stale) nk=$((nk + 1)) ;; esac
          fi
          k=$((k + 1))
        done
      fi
      j=$((j + 1))
    done
  done
  ROOST_SHAPE_COUNTS="$ns sessions, $nw windows, $np panes, $na with a conversation, $nk stale"
}

# roost_shape__pane K SESSION-INDEX WINDOW-INDEX HOME -> one pane block.
# Sets ROOST_SHAPE_PANE_KIND to conv, stale or "".
roost_shape__pane() {
  local k="$1" pid="${P_ID[$1]}" cmd sname agree h s t
  ROOST_SHAPE_PANE_KIND=""
  roost_shape__clean "${S_NAME[$2]}" || true; sname="$ROOST_SHAPE_V"
  printf 'pane %s:%s.%s\nid %s\n' "$sname" "$3" "${P_IDX[$k]}" "$pid"
  if [ -n "${P_NAME[$k]}" ]; then
    if roost_shape__clean "${P_NAME[$k]}" octal; then printf 'name %s\n' "$ROOST_SHAPE_V"
    else printf 'roost save: pane %s: its name holds a control character; name not saved\n' "$pid" >&2; fi
  fi
  # cwd is required and always exists (§3.2). One the file cannot hold is
  # written as the home directory, so restore gives a shell there; a resume's
  # directory comes from §5.1, never from this key.
  if roost_shape__clean "${P_PATH[$k]}" octal && [ -n "$ROOST_SHAPE_V" ]; then
    printf 'cwd %s\n' "$ROOST_SHAPE_V"
  else
    printf 'cwd %s\n' "$4"
    printf 'roost save: pane %s: its directory holds a control character; saved as the home directory\n' "$pid" >&2
  fi
  if [ -n "${P_RCWD[$k]}" ]; then
    if roost_shape__clean "${P_RCWD[$k]}" octal; then printf 'session_cwd %s\n' "$ROOST_SHAPE_V"
    else printf 'roost save: pane %s: session_cwd holds a control character; not saved\n' "$pid" >&2; fi
  fi
  roost_shape__clean "${P_CMD[$k]}" octal && cmd="$ROOST_SHAPE_V" || cmd=""
  h="" s="" t=""
  roost_shape__clean "${P_HARNESS[$k]}" octal && h="$ROOST_SHAPE_V"
  roost_shape__clean "${P_SESSION[$k]}" octal && s="$ROOST_SHAPE_V"
  roost_shape__clean "${P_TRANSCRIPT[$k]}" octal && t="$ROOST_SHAPE_V"
  if [ -n "$h" ] && [ -n "$s" ]; then
    agree="$(roost_shape_agree "$h" "$cmd")"
    if [ "$agree" = ok ]; then
      printf 'harness %s\nsession_id %s\n' "$h" "$s"
      [ -n "$t" ] && printf 'transcript %s\n' "$t"
      ROOST_SHAPE_PANE_KIND=conv
    else
      # Written as stale_*, so a reader sees what the pane last reported and
      # why, and restore never resumes it (§3.2, §5.6).
      printf 'stale_reason %s\nstale_harness %s\nstale_session_id %s\n' "$agree" "$h" "$s"
      [ -n "$t" ] && printf 'stale_transcript %s\n' "$t"
      ROOST_SHAPE_PANE_KIND=stale
    fi
  fi
  if [ -n "${P_LAUNCH[$k]}" ]; then
    if roost_shape__clean "${P_LAUNCH[$k]}" octal; then printf 'launch %s\n' "$(roost_shape__redact "$ROOST_SHAPE_V")"
    else printf 'roost save: pane %s: its launch command holds a control character; not saved\n' "$pid" >&2; fi
  fi
  [ -n "$cmd" ] && printf 'command %s\n' "$cmd"
  roost_shape__clean "${P_STATE[$k]}" && [ -n "$ROOST_SHAPE_V" ] && printf 'state %s\n' "$ROOST_SHAPE_V"
  [ "${P_ACT[$k]}" = 1 ] && printf 'active 1\n'
  printf '\n'
}

# roost_shape__publishable TMPFILE -> exit 0 when the new file passes the
# reader; else removes it, says why on stderr, and exits 1. A save never
# replaces the last good shape with one restore would refuse (review round 1,
# Codex B3: one did, through a repeated address): the writer and the reader
# are checked against each other at every save, not only by the tests.
roost_shape__publishable() {
  roost_shape_check "$1" 2>/dev/null && return 0
  printf 'roost save: the new shape would be refused by restore (%s); nothing written\n' "$ROOST_SHAPE_FAULT" >&2
  rm -f "$1"
  return 1
}

# roost_shape_save FLAG SOCKET TO TRIGGER -> exit 0 or 1.
#
# `roost save` (§4.2). Prints the shape's path (or TO) on stdout and `S
# sessions, W windows, P panes, A with a conversation, K stale` on stderr.
# TO empty means the server's own `shape`; TO a path writes a copy there and
# leaves `shape`, `gen` and `history/` alone (how a person moves a shape).
#
# Publishing is Part 1's form of §3.5 step 2 (Part 4 makes it the saver):
#   - build the body; a listing that fails, or never agrees, publishes
#     NOTHING and exits 1 — the last good `shape` is worth more than a
#     partial one;
#   - compare the body (everything after the header's blank line) with
#     `shape`'s: the same means nothing is written, because the header alone
#     never makes a save worth keeping (§3.2);
#   - else write a temp file in the shape directory (umask 077: 0600, the
#     record's rule — the shape lists every project and session id), hard-link
#     the current `shape` into `history/<its stamp>-<its gen>`, rename the
#     temp over `shape` (rename(2): a reader never sees a partial file), and
#     write `gen` + 1 the same way.
# History grows without a ring in this part; Part 4 adds ROOST_SHAPE_KEEP.
roost_shape_save() {
  local flag="$1" sock="$2" to="$3" trigger="${4:-save}" dir="" gen=0 body hdr tmp info
  local boot ver spath saved key old oldgen oldsaved
  ROOST_SHAPE_TFLAG="$flag" ROOST_SHAPE_TSOCK="$sock"
  key="$(roost_shape_key "$flag" "$sock")"
  if [ -z "$to" ]; then
    if ! roost_shape_saving >/dev/null; then
      printf 'roost save: saving is off (ROOST_SHAPE_DIR is empty or not an absolute path); nothing written\n' >&2
      return 0
    fi
    if ! dir="$(roost_shape_dir "$flag" "$sock")"; then
      printf 'roost save: cannot make the shape directory %s/%s; nothing written\n' "$(roost_shape_saving)" "$key" >&2
      return 1
    fi
  fi
  info="$(roost_shape__t display-message -p '#{start_time}-#{pid} #{version} #{socket_path}' 2>/dev/null)" || info=""
  if [ -z "$info" ] || ! roost_shape__read_rules || ! roost_shape__list; then
    printf 'roost save: could not list the tmux server on %s %s; nothing written\n' "$flag" "$sock" >&2
    return 1
  fi
  boot="${info%% *}"; info="${info#* }"; ver="${info%% *}"; spath="${info#* }"
  roost_shape__clean "$spath" octal && spath="$ROOST_SHAPE_V" || spath="-"
  # The body is built ONCE, into a temp file in this shell, so its counts
  # (ROOST_SHAPE_COUNTS) are this shell's too: built inside a $(...) they
  # were lost, and the first version built it twice to get them back (review
  # round 1, Fable N6), a cost Part 4 would pay at every structural event.
  local bodyf
  bodyf="$(mktemp)" || return 1
  roost_shape__body > "$bodyf" || { rm -f "$bodyf"; return 1; }
  body="$(cat "$bodyf")"; rm -f "$bodyf"
  if [ -n "$dir" ] && [ -f "$dir/shape" ] && [ "$(sed '1,/^$/d' "$dir/shape")" = "$body" ]; then
    printf '%s\n' "$dir/shape"
    printf '%s\n' "$ROOST_SHAPE_COUNTS" >&2
    return 0
  fi
  [ -n "$dir" ] && [ -f "$dir/gen" ] && read -r gen < "$dir/gen" 2>/dev/null
  case "$gen" in ''|*[!0-9]*) gen=0 ;; esac
  [ -n "$dir" ] && gen=$((gen + 1))
  saved="$(roost_shape__stamp)"
  hdr="$(printf 'roost-shape 1\nserver %s\nsocket %s\nboot %s\nsaved %s\ngen %s\ntrigger %s\nroost %s\ntmux %s\nhost %s\n' \
    "$key" "$spath" "$boot" "$saved" "$gen" "$trigger" "${ROOST_VERSION:-unknown}" "$ver" "$(uname -n)")"
  if [ -n "$to" ]; then
    tmp="$( (umask 077; mktemp "$to.XXXXXX") 2>/dev/null)" || {
      printf 'roost save: cannot write next to %s; nothing written\n' "$to" >&2; return 1; }
    printf '%s\n\n%s\n' "$hdr" "$body" > "$tmp" || { rm -f "$tmp"; printf 'roost save: cannot write %s\n' "$to" >&2; return 1; }
    roost_shape__publishable "$tmp" || return 1
    mv -f "$tmp" "$to" || { rm -f "$tmp"; printf 'roost save: cannot write %s\n' "$to" >&2; return 1; }
    printf '%s\n' "$to"
    printf '%s\n' "$ROOST_SHAPE_COUNTS" >&2
    return 0
  fi
  tmp="$( (umask 077; mktemp "$dir/.shape.XXXXXX") 2>/dev/null)" || {
    printf 'roost save: cannot write in %s; nothing written\n' "$dir" >&2; return 1; }
  if ! printf '%s\n\n%s\n' "$hdr" "$body" > "$tmp"; then
    rm -f "$tmp"; printf 'roost save: cannot write in %s; nothing written\n' "$dir" >&2; return 1
  fi
  roost_shape__publishable "$tmp" || return 1
  if [ -f "$dir/shape" ]; then
    oldsaved="$(sed -n 's/^saved //p;/^$/q' "$dir/shape")"
    oldgen="$(sed -n 's/^gen //p;/^$/q' "$dir/shape")"
    old="$(printf '%s' "$oldsaved" | tr -d ':-')-${oldgen:-0}"
    ( umask 077; mkdir -p "$dir/history" ) 2>/dev/null
    [ -e "$dir/history/$old" ] || ln "$dir/shape" "$dir/history/$old" 2>/dev/null || true
  fi
  if ! mv -f "$tmp" "$dir/shape"; then
    rm -f "$tmp"; printf 'roost save: cannot publish %s/shape; nothing written\n' "$dir" >&2; return 1
  fi
  tmp="$( (umask 077; mktemp "$dir/.gen.XXXXXX") 2>/dev/null)" \
    && printf '%s\n' "$gen" > "$tmp" && mv -f "$tmp" "$dir/gen"
  printf '%s\n' "$dir/shape"
  printf '%s\n' "$ROOST_SHAPE_COUNTS" >&2
  return 0
}

# roost_shape_check FILE -> exit 0 when the whole file may be restored; else
# exit 1 with ROOST_SHAPE_FAULT="line N: <fault>". An unknown block is skipped
# with one stderr line naming its line, and the file still passes.
#
# The whole file is checked before restore's first tmux command (§3.2, §4.3):
# #51 requirement 7 is never to half-restore, so one bad line refuses all of
# it. One pass, `IFS= read -r line`, the key as ${line%% *} and the value as
# ${line#* } — everything after the first space, byte for byte, leading and
# trailing spaces included — then the cross-block checks. Nothing in the file
# is evaluated: no eval, no source.
#
# The rules, in order:
#   - the first line is `roost-shape N`; no readable first line, or a larger
#     N, is a refusal (the number moves only when a key changes meaning);
#   - a line with no space has no value; a value holding a tab or any other
#     control character is refused (the writer never writes one, probe 1.3);
#   - a key repeated inside one block is a hand-edit error;
#   - a block starts with `session NAME`, `window SESSION:INDEX` or `pane
#     SESSION:INDEX.PANE`; any other first word is a block a later roost
#     added, skipped, so an additive file never makes an older roost refuse;
#   - required keys: the header's roost-shape, server, boot, saved, gen,
#     trigger; a session's id; a window's id and layout; a pane's id and cwd;
#   - no address repeats, every window names a session block and every pane a
#     window block (an address with no parent);
#   - a session group (R7): a `group` line names a session with a full block
#     — not itself, not another later member — and a later member owns no
#     window or pane block. Each of these is "an address with no parent", so
#     the whole file is refused, the rule above.
# roost_shape__digits X -> exit 0 when X is one or more ASCII digits.
roost_shape__digits() { [ -n "$1" ] && [ -z "${1//[0-9]/}" ]; }

roost_shape_check() {
  local LC_ALL=C file="$1" line n=0 key val kind="" addr="" bstart=0 keys="" first=1
  local hdr_keys="" addrs=$'\n' sessions=$'\n' full=$'\n' later=$'\n' windows=$'\n'
  local wchk="" pchk="" gchk="" fchk="" wsess=$'\n' s w rest
  local nl=$'\n'
  ROOST_SHAPE_FAULT=""
  if [ ! -s "$file" ]; then ROOST_SHAPE_FAULT="line 1: no readable first line (want roost-shape 1)"; return 1; fi
  # The block's end: check its required keys and record its address.
  roost_shape__endblock() {
    case "$kind" in
      header)
        for key in roost-shape server boot saved gen trigger; do
          case "$keys" in *" $key "*) ;; *) ROOST_SHAPE_FAULT="line 1: the header has no $key"; return 1 ;; esac
        done ;;
      session)
        case "$keys" in *" id "*) ;; *) ROOST_SHAPE_FAULT="line $bstart: session $addr has no id"; return 1 ;; esac ;;
      window)
        for key in id layout; do
          case "$keys" in *" $key "*) ;; *) ROOST_SHAPE_FAULT="line $bstart: window $addr has no $key"; return 1 ;; esac
        done ;;
      pane)
        for key in id cwd; do
          case "$keys" in *" $key "*) ;; *) ROOST_SHAPE_FAULT="line $bstart: pane $addr has no $key"; return 1 ;; esac
        done ;;
    esac
    case "$kind" in
      session)
        case "$keys" in
          *" group "*) later="$later$addr$nl" ;;
          *) full="$full$addr$nl" fchk="$fchk$bstart $addr$nl" ;;
        esac ;;
    esac
    kind="" keys=""
    return 0
  }
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if [ "$first" = 1 ]; then
      first=0
      case "$line" in
        "roost-shape "*)
          val="${line#roost-shape }"
          case "$val" in ''|*[!0-9]*) ROOST_SHAPE_FAULT="line 1: no readable first line (want roost-shape 1)"; return 1 ;; esac
          if [ "$val" -gt 1 ]; then ROOST_SHAPE_FAULT="line 1: roost-shape $val is newer than this roost reads (1)"; return 1; fi ;;
        *) ROOST_SHAPE_FAULT="line 1: no readable first line (want roost-shape 1)"; return 1 ;;
      esac
      kind=header bstart=1 keys=" roost-shape "
      continue
    fi
    if [ -z "$line" ]; then
      [ -n "$kind" ] && { roost_shape__endblock || return 1; }
      continue
    fi
    case "$line" in *" "*) ;; *) ROOST_SHAPE_FAULT="line $n: no value after the key $line"; return 1 ;; esac
    key="${line%% *}" val="${line#* }"
    case "$val" in *[[:cntrl:]]*) ROOST_SHAPE_FAULT="line $n: a value holds a tab or a control character"; return 1 ;; esac
    if [ -z "$kind" ]; then
      # A block's first line.
      bstart=$n addr="$val" keys=""
      case "$key" in
        session) kind=session ;;
        window)
          kind=window
          s="${val%:*}" rest="${val##*:}"
          if [ "$s" = "$val" ] || [ -z "$s" ] || ! roost_shape__digits "$rest"; then
            ROOST_SHAPE_FAULT="line $n: window $val is not SESSION:INDEX"; return 1
          fi
          wchk="$wchk$n $s$nl" windows="$windows$val$nl" wsess="$wsess$s$nl" ;;
        pane)
          kind=pane
          s="${val%:*}" rest="${val##*:}"
          w="${rest%.*}"
          if [ "$s" = "$val" ] || [ -z "$s" ] || [ "$w" = "$rest" ] \
             || ! roost_shape__digits "$w" || ! roost_shape__digits "${rest##*.}"; then
            ROOST_SHAPE_FAULT="line $n: pane $val is not SESSION:WINDOW.PANE"; return 1
          fi
          pchk="$pchk$n $s:$w$nl" ;;
        *)
          printf 'roost: line %s: unknown block %s skipped\n' "$n" "$key" >&2
          kind=unknown ;;
      esac
      if [ "$kind" != unknown ]; then
        case "$addrs" in *"$nl$key $val$nl"*) ROOST_SHAPE_FAULT="line $n: repeated address $key $val"; return 1 ;; esac
        addrs="$addrs$key $val$nl"
      fi
      continue
    fi
    [ "$kind" = unknown ] && continue
    case "$keys" in *" $key "*) ROOST_SHAPE_FAULT="line $n: repeated key $key"; return 1 ;; esac
    keys="$keys $key "
    [ "$kind" = session ] && [ "$key" = group ] && gchk="$gchk$bstart $addr $val$nl"
  done < "$file"
  [ -n "$kind" ] && { roost_shape__endblock || return 1; }
  # The cross-block checks, once every block is known: parents, then groups.
  local ln a g
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ln="${line%% *}" a="${line#* }"
    case "$full$later" in *"$nl$a$nl"*) ;; *)
      ROOST_SHAPE_FAULT="line $ln: window $(sed -n "${ln}s/^window //p" "$file") has no session block"; return 1 ;; esac
    case "$later" in *"$nl$a$nl"*)
      ROOST_SHAPE_FAULT="line $ln: window $(sed -n "${ln}s/^window //p" "$file") belongs to $a, a later member of a group (it has no windows of its own)"; return 1 ;; esac
  done <<< "$wchk"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ln="${line%% *}" a="${line#* }"
    case "$windows" in *"$nl$a$nl"*) ;; *)
      ROOST_SHAPE_FAULT="line $ln: pane $(sed -n "${ln}s/^pane //p" "$file") has no window block"; return 1 ;; esac
  done <<< "$pchk"
  # A full session needs a window: tmux has no session without one, and a
  # first block with none could never start the server the roost way (review
  # round 1, Fable B1: restore then made the NEXT session on a bare server,
  # with no roost.conf, no hooks and no wiring). A later member of a group has
  # no window blocks by design (R7) and is not checked here.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ln="${line%% *}" a="${line#* }"
    case "$wsess" in *"$nl$a$nl"*) ;; *)
      ROOST_SHAPE_FAULT="line $ln: session $a has no window block"; return 1 ;; esac
  done <<< "$fchk"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ln="${line%% *}" rest="${line#* }"
    # rest is "<member> <first>"; a session name holds no space only when tmux
    # made it, so split on the LAST space is wrong for a hand-made one: the
    # member's name is the block address, read back from its line.
    a="$(sed -n "${ln}s/^session //p" "$file")" g="${rest#"$a" }"
    case "$full" in *"$nl$g$nl"*) ;; *)
      ROOST_SHAPE_FAULT="line $ln: session $a joins $g, which has no full session block"; return 1 ;; esac
  done <<< "$gchk"
  return 0
}

# roost_shape_parse FILE DIR -> one file per block in DIR, named NNNN.<kind>
# (0000.header, then session, window and pane blocks in file order), each
# holding that block's lines verbatim. Call it only after roost_shape_check
# passed. An unknown block is not written: restore never sees it.
roost_shape_parse() {
  local file="$1" dir="$2" line n=0 cur="" kind=""
  ( umask 077; mkdir -p "$dir" ) || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$line" ]; then cur=""; continue; fi
    if [ -z "$cur" ]; then
      case "${line%% *}" in
        roost-shape) kind=header ;;
        session|window|pane) kind="${line%% *}" ;;
        *) kind=unknown ;;
      esac
      if [ "$kind" = unknown ]; then cur=/dev/null
      else cur="$dir/$(printf '%04d' "$n").$kind"; n=$((n + 1)); : > "$cur"; fi
    fi
    [ "$cur" = /dev/null ] || printf '%s\n' "$line" >> "$cur"
  done < "$file"
}

# roost_shape_get BLOCKFILE KEY -> prints the value; exit 1 when the key is
# absent. A reader tests presence (§3.2: absent, not empty). The block's
# first line is its address, not a key, and is never matched.
roost_shape_get() {
  local line first=1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$first" = 1 ]; then first=0; continue; fi
    case "$line" in "$2 "*) printf '%s\n' "${line#"$2" }"; return 0 ;; esac
  done < "$1"
  return 1
}

# THE OWNER RULE (§3.5 step 1, revision 2 item 3), for `restoring/` now and
# for the saver's `lock/` in Part 4. A directory is held by one process,
# which records its pid and start time (`ps -o lstart=`). It is taken over
# ONLY when that pid is not running, or is running with another start time
# (the pid was reused). Never by age: a slow or stopped owner keeps it, and
# whoever waits keeps waiting.
#
# HOW IT IS EXCLUSIVE (review round 1, B2: two processes that both saw one
# dead owner both took it over, measured). The record is a SYMBOLIC LINK,
# DIR/owner, whose target is "PID LSTART". `ln -s` makes it with its content
# in one step and fails when it exists, so there is no moment when DIR is held
# but its owner is unwritten — the first version's mkdir-then-write left one,
# and a reader there saw "no owner" and took over. Taking over a DEAD record
# is itself a claim, made the same way on a name derived from exactly that
# record (roost_shape__claim on DIR/owner.x.<sum>, roost_shape__takeover):
# only one process can win the takeover of one dead record, and only its
# winner removes it. A takeover whose taker died is taken over the same way,
# one level down.

# roost_shape__lstart PID -> prints the process's start time, or nothing.
roost_shape__lstart() { ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//;s/ *$//'; }

# roost_shape__alive RECORD -> exit 0 when "PID LSTART" names a running
# process with that start time; ROOST_SHAPE_OWNER_PID is the pid.
roost_shape__alive() {
  local pid="${1%% *}" lst="${1#* }"
  ROOST_SHAPE_OWNER_PID="$pid"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  lst="$(printf '%s' "$lst" | sed 's/^ *//;s/ *$//')"
  [ -n "$lst" ] && [ "$(roost_shape__lstart "$pid")" = "$lst" ]
}

# roost_shape__seam VAR — a test seam: when the variable names a file, mark
# FILE.at.<pid> and wait (bounded) until FILE exists. Read only when set.
roost_shape__seam() {
  local f i=0
  eval "f=\${$1:-}"
  [ -n "$f" ] || return 0
  : > "$f.at.$$"
  while [ ! -e "$f" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
}

# roost_shape__takeover PATH RECORD -> prints the name a takeover of PATH's
# dead RECORD is claimed on: PATH's first name, `.x.`, and the cksum of PATH
# and RECORD together. One name per (path, record), so two takers of the same
# dead record race on one `ln -s`, and a later holder who dies has a name of
# its own. Its length is FIXED: the first version appended the whole record
# to PATH at every level, and a chain of takers that died holding their
# claims reached a name longer than a file name may be (ENAMETOOLONG; review
# round 2, Codex R2-B4). cksum is POSIX; a clash of two sums only makes two
# records share one takeover name, which is still exclusive.
roost_shape__takeover() {
  local dir="${1%/*}" base="${1##*/}" sum
  sum="$(printf '%s\n%s' "$1" "$2" | cksum | sed 's/[^0-9][^0-9]*/-/;s/[^0-9-]//g')"
  printf '%s/%s.x.%s\n' "$dir" "${base%%.x.*}" "$sum"
}

# roost_shape__claim PATH ME -> 0 claimed (PATH was free), 2 claimed from a
# dead holder, 1 a live process holds it (ROOST_SHAPE_OWNER_PID), 3 it cannot
# be claimed at all (ROOST_SHAPE_OWNER_FAULT says why).
roost_shape__claim() {
  local path="$1" me="$2" cur sub took=0 i=0 r first=1 miss=0
  ROOST_SHAPE_OWNER_FAULT=""
  while [ "$i" -lt 100 ]; do
    i=$((i + 1))
    [ "$first" = 1 ] && roost_shape__seam ROOST_TEST_OWNER_PAUSE_FRESH
    first=0
    if ln -s "$me" "$path" 2>/dev/null; then return "$took"; fi
    if ! cur="$(readlink "$path" 2>/dev/null)"; then
      # Something that is not a symbolic link: no restore wrote it, and no
      # pid can be read from it, so it is named once, not spun on (review
      # round 2, Fable N2).
      if [ -e "$path" ]; then
        ROOST_SHAPE_OWNER_FAULT="$path is not an owner record (not a symbolic link); remove it when no restore is running"
        return 3
      fi
      # The directory itself is gone: another owner's drop removed it
      # between this taker's mkdir and its link (ENOENT). A free directory,
      # so make it again (Fable N2).
      if [ ! -d "${path%/*}" ]; then
        ( umask 077; mkdir -p "${path%/*}" ) 2>/dev/null || {
          ROOST_SHAPE_OWNER_FAULT="cannot create ${path%/*}"; return 3; }
        continue
      fi
      # `ln -s` failed and nothing is there: either the record went between
      # the two calls (the next turn wins), or the name cannot be made at
      # all. Three in a row is the second: a clear refusal, never a loop
      # retrying an `ln -s` that cannot succeed (review round 2, R2-B4).
      miss=$((miss + 1))
      if [ "$miss" -ge 3 ]; then
        ROOST_SHAPE_OWNER_FAULT="cannot create $path"
        return 3
      fi
      continue
    fi
    miss=0
    roost_shape__alive "$cur" && return 1
    # A dead record was seen: whoever links PATH from here on replaces a dead
    # owner, even when another taker removed the record and this one linked
    # first, so it must report 2 and settle what the dead owner left (review
    # round 2, Fable N1: it reported 0, fresh, and skipped the settling).
    took=2
    roost_shape__seam ROOST_TEST_OWNER_PAUSE_DEAD
    sub="$(roost_shape__takeover "$path" "$cur")"
    r=0; roost_shape__claim "$sub" "$me" || r=$?
    [ "$r" = 3 ] && return 3
    if [ "$r" = 1 ]; then sleep 0.05; continue; fi
    roost_shape__seam ROOST_TEST_OWNER_PAUSE_HELD
    # Held. The record is still the dead one (only this takeover's holder may
    # remove it, a dead owner releases nothing, and a fresh `ln -s` fails
    # while it exists), so remove it and claim; whoever links first owns it.
    [ "$(readlink "$path" 2>/dev/null)" = "$cur" ] && rm -f "$path"
    roost_shape__seam ROOST_TEST_OWNER_PAUSE_GAP
    if ln -s "$me" "$path" 2>/dev/null; then rm -f "$sub"; return 2; fi
    rm -f "$sub"
  done
  ROOST_SHAPE_OWNER_PID="${cur%% *}"
  return 1
}

# roost_shape_owner_take DIR -> 0 when DIR is made and owned by this process;
# 2 when taken over from an owner that is gone (the caller then settles what
# that owner left, §4.7 arrow T2b); 1 when a live owner holds it
# (ROOST_SHAPE_OWNER_PID names it); 3 when it cannot be owned at all
# (ROOST_SHAPE_OWNER_FAULT says why, naming the path). DIR itself is made by
# anyone (mkdir -p): what is exclusive is the owner record in it.
roost_shape_owner_take() {
  # A directory that cannot be made is no one's: exit 3 naming it, never 1,
  # which the caller reports as another restore holding it (review round 3,
  # Fable N2: an unwritable shape directory read "pid ?").
  if ! ( umask 077; mkdir -p "$1" ) 2>/dev/null; then
    ROOST_SHAPE_OWNER_FAULT="cannot create $1"
    return 3
  fi
  roost_shape__claim "$1/owner" "$$ $(roost_shape__lstart "$$")"
}

# roost_shape_owner_live DIR -> exit 0 when DIR's recorded owner is running
# with the recorded start time; ROOST_SHAPE_OWNER_PID is its pid.
roost_shape_owner_live() {
  local cur
  cur="$(readlink "$1/owner" 2>/dev/null)" || return 1
  roost_shape__alive "$cur"
}

# roost_shape_owner_drop DIR -> removes DIR, with everything in it, the
# owner's last act (§3.5 step 4: restore removes `restoring/` after its last
# tmux command, and while it exists the saver only records a want). Renamed
# aside first, so DIR is gone in one step and a reader never finds half of it.
roost_shape_owner_drop() {
  local gone="$1.gone.$$"
  if mv "$1" "$gone" 2>/dev/null; then rm -rf "$gone"; else rm -rf "$1"; fi
}
