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

# roost_shape__fg_is HARNESS COMMAND — the foreground COMMAND can be this
# harness itself. roost_close_harness's names (Claude's version string, the
# five names), plus the two that table cannot claim because they are not
# distinctive: pi runs as `node` (probe 1.6), and opencode — not measured —
# as `node` or `bun` besides its own name. A shell running one of those for
# this harness is the agent at work, judged by the table; a shell running
# anything else is a person's job.
#
# Moved here from scripts/lib/roost-resume.sh (it was roost_resume__fg_is)
# when save and revive came to share roost_shape_agree_pane, below.
roost_shape__fg_is() {
  roost_close_harness "" "$2" ""
  [ "$ROOST_CLOSE_HARNESS" = "$1" ] && return 0
  case "$1:$2" in
    pi:node|opencode:node|opencode:bun) return 0 ;;
  esac
  return 1
}

# roost_shape_agree_pane HARNESS COMMAND PANE-PID -> prints ok | exited |
# nested | other. THE agreement table for a live pane: save's writer and
# `revive` both ask this, so a restore never refuses a pane that `revive`
# would resume (Part 3's header: "one agreement table, before the engine",
# from Part 2's review round 1, Fable N3). Before it, save called a shell pane
# running a job `other` while revive called it `exited`.
#
# It is roost_shape_agree (§3.2's table) with one addition, for a SHELL pane:
# #{pane_current_command} names the foreground job, so a shell running `sleep
# 60` reads `sleep`, which the table calls `other` (13, nothing anyone can
# do). But the agent has left and a person is using the shell — §4.1 step
# 7's case, "a shell pane whose shell has a child process", refused with exit
# 1 and replaced under --force. So when the pane's OWN process (PANE-PID,
# #{pane_pid}) is a shell and the foreground is not a harness, the pane is
# `exited` and step 7's shell check decides. A harness in the foreground (a
# person typed `claude` at the prompt) is still judged by the table: ok or
# nested. `other` is left for a pane whose own process is neither — an
# editor or a `sleep` started as the pane's command.
#
# The pane's own process is asked FIRST, for every harness (Part 2's review
# round 1, Codex B2): asked only after the table said `other`, it never ran
# for pi and opencode, which the table admits on presence alone — a shell
# left by pi and running `sleep 600` read `ok`, and the person's job was
# killed without --force. For a shell-owned pane: the foreground is this
# harness (roost_shape__fg_is) → the table decides (ok); another harness's
# distinctive command → the table decides (nested); anything else → exited.
#
# An empty PANE-PID, or one `ps` cannot name (the pane died between the
# listing and this read), is the table alone: there is no process to ask.
roost_shape_agree_pane() {
  local o=""
  [ -n "${3:-}" ] && o="$(ps -o comm= -p "$3" 2>/dev/null || true)"
  o="${o##*/}"; o="${o#-}"; o="${o%% *}"
  case "$o" in
    sh|bash|zsh|fish|dash)
      roost_close_harness "" "$2" ""
      if ! roost_shape__fg_is "$1" "$2" && [ -z "$ROOST_CLOSE_HARNESS" ]; then
        printf 'exited\n'; return 0
      fi ;;
  esac
  roost_shape_agree "$1" "$2"
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
ROOST_SHAPE_FP='#{pane_id} #{session_id} #{window_id} #{pane_index} #{pane_active} #{pane_pid} x#{q:pane_current_command} x#{q:@agent_state} x#{q:@roost-harness} x#{q:@roost-session} x#{q:@roost-transcript-path} x#{q:@roost-launch} x#{q:@roost-cwd} x#{q:@roost-name} x#{q:pane_current_path} .#{pane_id}'

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
  local line pid sid wid idx act ppid xc xs xh xi xt xl xr xn xp end
  P_ID=() P_SID=() P_WID=() P_IDX=() P_ACT=() P_PPID=() P_CMD=() P_STATE=() P_HARNESS=()
  P_SESSION=() P_TRANSCRIPT=() P_LAUNCH=() P_RCWD=() P_NAME=() P_PATH=()
  while IFS= read -r line; do
    case "$line" in %[0-9]*) ;; *) continue ;; esac
    IFS=' ' read pid sid wid idx act ppid xc xs xh xi xt xl xr xn xp end <<< "$line"
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
    P_ID+=("$pid"); P_SID+=("$sid"); P_WID+=("$wid"); P_IDX+=("$idx"); P_ACT+=("$act"); P_PPID+=("$ppid")
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
    # The one table save and revive share (roost_shape_agree_pane), asked
    # with the pane's own process.
    agree="$(roost_shape_agree_pane "$h" "$cmd" "${P_PPID[$k]}")"
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

# roost_shape__build -> builds this server's body into ROOST_SHAPE_BODY and
# reads its boot, version and socket path (ROOST_SHAPE_BOOT, _VER, _SPATH);
# exit 0, or the failing tmux read's exit code (1 when it gave none) with
# nothing built. ROOST_SHAPE_TFLAG and _TSOCK name the server.
roost_shape__build() {
  local info r=0 bodyf
  info="$(roost_shape__t display-message -p '#{start_time}-#{pid} #{version} #{socket_path}' 2>/dev/null)" || r=$?
  [ -n "$info" ] || { [ "$r" = 0 ] && r=1; return "$r"; }
  roost_shape__read_rules || return 1
  roost_shape__list || return 1
  ROOST_SHAPE_BOOT="${info%% *}"; info="${info#* }"; ROOST_SHAPE_VER="${info%% *}"; ROOST_SHAPE_SPATH="${info#* }"
  roost_shape__clean "$ROOST_SHAPE_SPATH" octal && ROOST_SHAPE_SPATH="$ROOST_SHAPE_V" || ROOST_SHAPE_SPATH="-"
  # The body is built ONCE, into a temp file in this shell, so its counts
  # (ROOST_SHAPE_COUNTS) are this shell's too: built inside a $(...) they
  # were lost, and the first version built it twice to get them back (review
  # round 1, Fable N6), a cost Part 4 would pay at every structural event.
  bodyf="$(mktemp)" || return 1
  roost_shape__body > "$bodyf" || { rm -f "$bodyf"; return 1; }
  ROOST_SHAPE_BODY="$(cat "$bodyf")"; rm -f "$bodyf"
  return 0
}

# roost_shape__header KEY GEN TRIGGER -> the header lines (no blank line).
roost_shape__header() {
  printf 'roost-shape 1\nserver %s\nsocket %s\nboot %s\nsaved %s\ngen %s\ntrigger %s\nroost %s\ntmux %s\nhost %s\n' \
    "$1" "$ROOST_SHAPE_SPATH" "$ROOST_SHAPE_BOOT" "$(roost_shape__stamp)" "$2" "$3" \
    "${ROOST_VERSION:-unknown}" "$ROOST_SHAPE_VER" "$(uname -n)"
}

# roost_shape_save FLAG SOCKET TO TRIGGER -> exit 0 or 1.
#
# `roost save` (§4.2), the person's verb. Prints the shape's path (or TO) on
# stdout and `S sessions, W windows, P panes, A with a conversation, K stale`
# on stderr. TO empty means the server's own `shape`; TO a path writes a copy
# there and leaves `shape`, `gen` and `history/` alone (how a person moves a
# shape), and takes no lock: it publishes nothing the saver owns.
#
# Without TO it goes through the saver (§3.5, roost_shape__saver), like every
# hook: it records its want, waits for a live saver to finish (bounded), and
# then runs the saver itself, so a person's save and a hook's never publish
# over each other. The rules of a round — a listing that fails publishes
# nothing; a body equal to `shape`'s writes nothing; a temp file, a hard link
# into history/, a rename — are roost_shape__round's.
#
# The server is asked once BEFORE anything is written: a save of a server
# that is not running exits 1 and leaves the directory exactly as it was
# (§8.1 test 10a), with no want, lock or save.err of its own.
roost_shape_save() {
  local flag="$1" sock="$2" to="$3" trigger="${4:-save}" dir="" gen=0 hdr tmp key r i
  ROOST_SHAPE_TFLAG="$flag" ROOST_SHAPE_TSOCK="$sock"
  key="$(roost_shape_key "$flag" "$sock")"
  if [ -n "$to" ]; then
    if ! roost_shape__build; then
      printf 'roost save: could not list the tmux server on %s %s; nothing written\n' "$flag" "$sock" >&2
      return 1
    fi
    hdr="$(roost_shape__header "$key" 0 "$trigger")"
    tmp="$( (umask 077; mktemp "$to.XXXXXX") 2>/dev/null)" || {
      printf 'roost save: cannot write next to %s; nothing written\n' "$to" >&2; return 1; }
    printf '%s\n\n%s\n' "$hdr" "$ROOST_SHAPE_BODY" > "$tmp" || { rm -f "$tmp"; printf 'roost save: cannot write %s\n' "$to" >&2; return 1; }
    roost_shape__publishable "$tmp" || return 1
    mv -f "$tmp" "$to" || { rm -f "$tmp"; printf 'roost save: cannot write %s\n' "$to" >&2; return 1; }
    printf '%s\n' "$to"
    printf '%s\n' "$ROOST_SHAPE_COUNTS" >&2
    return 0
  fi
  if ! roost_shape_saving >/dev/null; then
    printf 'roost save: saving is off (ROOST_SHAPE_DIR is empty or not an absolute path); nothing written\n' >&2
    return 0
  fi
  if ! dir="$(roost_shape_dir "$flag" "$sock")"; then
    printf 'roost save: cannot make the shape directory %s/%s; nothing written\n' "$(roost_shape_saving)" "$key" >&2
    return 1
  fi
  if ! roost_shape__t display-message -p '#{pid}' >/dev/null 2>&1; then
    printf 'roost save: could not list the tmux server on %s %s; nothing written\n' "$flag" "$sock" >&2
    return 1
  fi
  if ! roost_shape__want "$dir" "$trigger"; then
    printf 'roost save: cannot write in %s; nothing written\n' "$dir" >&2
    return 1
  fi
  # A live saver holds lock/: wait for it, bounded (30 s). It may well write
  # this save's want itself; the round below then finds the same body and
  # writes nothing, and the path is still the newest save.
  i=0
  while :; do
    r=0; roost_shape__lock "$dir" || r=$?
    case "$r" in 0|2) break ;; 3)
      printf 'roost save: %s; nothing written\n' "${ROOST_SHAPE_OWNER_FAULT:-cannot lock $dir}" >&2; return 1 ;; esac
    i=$((i + 1))
    if [ "$i" -ge 300 ]; then
      printf 'roost save: another save (pid %s) has held %s/lock for 30 s; your save is wanted and that saver will write it\n' \
        "${ROOST_SHAPE_OWNER_PID:-?}" "$dir" >&2
      return 1
    fi
    sleep 0.1
  done
  # Held. This save's own round must run in THIS process, so its counts are
  # known: the want goes back in case the saver before took it.
  roost_shape__want "$dir" "$trigger" || true
  ROOST_SHAPE_LAST=""
  roost_shape__saver "$dir" "$key"
  case "$ROOST_SHAPE_LAST" in
    published|same)
      printf '%s\n' "$dir/shape"
      printf '%s\n' "$ROOST_SHAPE_COUNTS" >&2
      return 0 ;;
  esac
  return 1
}

# THE SAVER (§3.5), what `roost save --auto` runs. Ten hooks firing in one
# second must not publish an older listing last, and a restore building
# sixty panes must not have `shape` rewritten under it sixty times. So there
# is one saver at a time per server, and every other caller only says that a
# save is wanted:
#
#   want/<trigger>[.<%N>]   one empty file per cause. A FILE each, never one
#                           flag: coalescing keeps every cause (revision 2,
#                           item 1), and the saver writes them all into the
#                           header's `trigger` line
#   lock/                   the saver's, under THE OWNER RULE (pid and start
#                           time; roost_shape_owner_take). Taken over only
#                           from a dead owner or a reused pid, NEVER by age: a
#                           slow or stopped saver keeps it and the wants wait
#                           (a live owner held over 60 s is a doctor warning)
#   restoring/              while it has a live owner, a save only records its
#                           want: restore's own final save publishes (step 4)
#
# --auto never prints and never fails loudly: a hook's `run-shell -b` shows
# any output to whoever is looking at the server, so the arm in bin/roost
# throws both streams away and exits 0 whatever happens here.

# roost_shape__want DIR NAME -> exit 0 when want/NAME exists. A caller whose
# write races the saver's `mv want want.<pid>` fails once (the directory it
# made is gone); it makes want/ again and writes once more (§3.5 step 2).
roost_shape__want() {
  local i=0
  while [ "$i" -lt 3 ]; do
    i=$((i + 1))
    ( umask 077; mkdir -p "$1/want" && : > "$1/want/$2" ) 2>/dev/null && return 0
  done
  return 1
}

# roost_shape__err DIR STEP CODE — R3: a round that failed says so, in
# `save.err` (0600) beside `shape`: the stamp, the step and its exit code.
# `doctor` quotes it (Task 4.11), because every timer-based saver read
# shipped with a health line that said "saved" while nothing was written.
# Written only into a directory that still exists (a removed one is never
# made again by a late write), and silent when it cannot be written at all
# (a read-only directory): doctor's "no save since this server started"
# line covers that case.
roost_shape__err() {
  local tmp
  [ -d "$1" ] || return 0
  tmp="$( (umask 077; mktemp "$1/.err.XXXXXX") 2>/dev/null)" || return 0
  if printf 'saved %s\nstep %s\nexit %s\n' "$(roost_shape__stamp)" "$2" "$3" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$1/save.err" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
  return 0
}

# roost_shape__mine DIR -> exit 0 while DIR/lock is still this saver's: the
# record roost_shape_owner_take linked for this process. A lock that went
# with its directory (`rm -rf` of the shape directory under a held saver), or
# that another saver now holds, is not.
#
# ROOST_SHAPE_ME is that record, read ONCE when the lock is taken: the start
# time costs a `ps` on macOS, and a save must cost the same few processes on
# a 4-pane server as on a 40-pane one (Task 4.11; other tools' per-pane `ps`
# saves pinned whole machines after a sleep).
roost_shape__mine() {
  [ -n "${ROOST_SHAPE_ME:-}" ] && [ "$(readlink "$1/lock/owner" 2>/dev/null)" = "$ROOST_SHAPE_ME" ]
}

# roost_shape__lock DIR -> roost_shape_owner_take on DIR/lock, and on success
# ROOST_SHAPE_ME, the record it linked (the same two reads the owner rule
# makes, so they agree byte for byte).
roost_shape__lock() {
  local r=0
  roost_shape_owner_take "$1/lock" || r=$?
  case "$r" in 0|2) ROOST_SHAPE_ME="$$ $(roost_shape__lstart "$$")" ;; esac
  return "$r"
}

# roost_shape__prune DIR — the ring (§3.6): history/ keeps the newest
# ROOST_SHAPE_KEEP saves (default 100, enough for a 38-pane fleet's teardown
# chain and the save before it), by `gen`, the counter that orders two saves
# made in one second. A value that is not a whole number above 0 is the
# default: a typo must never empty the history.
roost_shape__prune() {
  local keep="${ROOST_SHAPE_KEEP:-100}" n f
  case "$keep" in ''|*[!0-9]*|0) keep=100 ;; esac
  [ -d "$1/history" ] || return 0
  n="$(ls "$1/history" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$n" -gt "$keep" ] || return 0
  # Names are STAMP-GEN, the stamp holding no `-`: sort on the gen.
  ls "$1/history" | sort -t- -k2,2n | head -n "$((n - keep))" | while IFS= read -r f; do
    rm -f "$1/history/$f"
  done
}

# roost_shape__round DIR KEY TRIGGERS -> one round of §3.5 step 2, after the
# drain. Sets ROOST_SHAPE_LAST: published, same (the body equals `shape`'s,
# nothing written), failed (save.err written) or lost (the lock went: nothing
# published). Exit 0 for published and same, 1 otherwise.
roost_shape__round() {
  local dir="$1" key="$2" triggers="$3" r=0 gen=0 had_gen=0 hdr tmp old oldgen oldsaved
  ROOST_SHAPE_LAST=failed
  # A listing that fails, or never agrees, publishes NOTHING: the last good
  # `shape` is worth more than a partial one.
  roost_shape__build || r=$?
  if [ "$r" != 0 ]; then
    printf 'roost save: could not list the tmux server on %s %s; nothing written\n' "$ROOST_SHAPE_TFLAG" "$ROOST_SHAPE_TSOCK" >&2
    roost_shape__err "$dir" list "$r"
    return 1
  fi
  roost_shape__seam ROOST_TEST_SAVE_HOLD_AFTER_LIST
  # The body (everything after the header's blank line) equal to `shape`'s
  # means nothing is written: the header alone never makes a save worth
  # keeping (§3.2).
  if [ -f "$dir/shape" ] && [ "$(sed '1,/^$/d' "$dir/shape")" = "$ROOST_SHAPE_BODY" ]; then
    ROOST_SHAPE_LAST=same
    return 0
  fi
  if [ -f "$dir/gen" ]; then had_gen=1; read -r gen < "$dir/gen" 2>/dev/null || true; fi
  case "$gen" in ''|*[!0-9]*) gen=0 ;; esac
  gen=$((gen + 1))
  hdr="$(roost_shape__header "$key" "$gen" "$triggers")"
  # A temp file in the shape directory (umask 077: 0600, the record's rule —
  # the shape lists every project and session id), the current `shape`
  # hard-linked into history/<its stamp>-<its gen>, then the temp renamed
  # over `shape` (rename(2): a reader never sees a partial file) and `gen`
  # written the same way.
  tmp="$( (umask 077; mktemp "$dir/.shape.XXXXXX") 2>/dev/null)" || {
    printf 'roost save: cannot write in %s; nothing written\n' "$dir" >&2
    roost_shape__err "$dir" write 1; return 1; }
  if ! printf '%s\n\n%s\n' "$hdr" "$ROOST_SHAPE_BODY" > "$tmp"; then
    rm -f "$tmp"; printf 'roost save: cannot write in %s; nothing written\n' "$dir" >&2
    roost_shape__err "$dir" write 1; return 1
  fi
  if ! roost_shape__publishable "$tmp"; then
    roost_shape__err "$dir" check 1; return 1
  fi
  # The lock and gen this round started with must still be there: a shape
  # directory removed under a held saver (`rm -rf` while it listed) is not
  # filled again by its late write. One tool found a deleted session brought
  # back exactly that way; this pins the opposite.
  if ! roost_shape__mine "$dir" || { [ "$had_gen" = 1 ] && [ ! -f "$dir/gen" ]; }; then
    rm -f "$tmp"
    ROOST_SHAPE_LAST=lost
    return 1
  fi
  if [ -f "$dir/shape" ]; then
    oldsaved="$(sed -n 's/^saved //p;/^$/q' "$dir/shape")"
    oldgen="$(sed -n 's/^gen //p;/^$/q' "$dir/shape")"
    old="$(printf '%s' "$oldsaved" | tr -d ':-')-${oldgen:-0}"
    ( umask 077; mkdir -p "$dir/history" ) 2>/dev/null
    [ -e "$dir/history/$old" ] || ln "$dir/shape" "$dir/history/$old" 2>/dev/null || true
  fi
  # ROOST_TEST_PUBLISH_FAIL=1: the rename fails as a refused `mv` would, in
  # a directory that is otherwise writable (the plan's seam, for R3).
  r=0
  if [ "${ROOST_TEST_PUBLISH_FAIL:-}" = 1 ]; then r=1; else mv -f "$tmp" "$dir/shape" || r=$?; fi
  if [ "$r" != 0 ]; then
    rm -f "$tmp"; printf 'roost save: cannot publish %s/shape; nothing written\n' "$dir" >&2
    roost_shape__err "$dir" publish "$r"
    return 1
  fi
  tmp="$( (umask 077; mktemp "$dir/.gen.XXXXXX") 2>/dev/null)" \
    && printf '%s\n' "$gen" > "$tmp" && mv -f "$tmp" "$dir/gen"
  rm -f "$dir/save.err"
  roost_shape__prune "$dir"
  ROOST_SHAPE_LAST=published
  return 0
}

# roost_shape__saver DIR KEY — the loop of §3.5 steps 2 and 3. Call it
# holding DIR/lock. While want/ exists: move it aside in one rename, read its
# names as this round's causes, remove it, run one round. Then release the
# lock, and look once more: a want that arrived between the last check and
# the release is taken by trying the lock again (its maker found the lock
# held and left). A round that fails ends the loop; its wants are not put
# back (the server it could not list is the cause, and the next hook brings
# a new want).
roost_shape__saver() {
  local dir="$1" key="$2" drain triggers r
  while :; do
    while [ -d "$dir/want" ] && roost_shape__mine "$dir"; do
      drain="$dir/want.$$"
      rm -rf "$drain"
      mv "$dir/want" "$drain" 2>/dev/null || break
      # want/<trigger>.<%N> names a pane; the header carries the trigger.
      triggers="$(ls "$drain" 2>/dev/null | sed 's/\.%[0-9]*$//' | sort -u | tr '\n' ' ')"
      triggers="${triggers% }"
      ROOST_SHAPE_WANTS="$(ls "$drain" 2>/dev/null)"
      rm -rf "$drain"
      roost_shape__seam ROOST_TEST_SAVE_HOLD_AFTER_DRAIN
      [ -n "$triggers" ] || continue
      r=0; roost_shape__round "$dir" "$key" "$triggers" || r=1
      [ "$r" = 0 ] || break
    done
    roost_shape__mine "$dir" && roost_shape_owner_drop "$dir/lock"
    [ "${r:-0}" = 0 ] || return 0
    [ -d "$dir/want" ] || return 0
    r=0; roost_shape__lock "$dir" || r=$?
    case "$r" in 0|2) ;; *) return 0 ;; esac
  done
}

# THE CLOSED RECORD (§3.6a): a removal that was meant stays removed after a
# reboot. closed/<boot>/ holds one 0600 file per removal, each naming PANE
# IDS ONLY, `%N` per line, the ids of that boot (panes only: a window or
# session block left with no pane is dropped by restore, and naming a window
# would also drop a pane that had moved out of it before the kill). One file
# each, so a failed `roost close` can take its own back without editing a
# file others append to. Restore's step 4 reads only the directory of the
# boot a picked save names (§3.6).
#
#   kill.<stamp>-<pid>   a kill-pane, kill-window or kill-session: the panes in
#                        the hook's old @roost-ids and not in its new loop
#   died.<N>             pane-exited's own note: %N's process ended by itself.
#                        Never a removal on its own; it is the belt that keeps
#                        a kill file from removing a pane that died (§3.6a)
#   close.<N>            `roost close` (and `roost kill`/`stop`, ruling R1),
#                        written by bin/roost before the exit command

# roost_shape__closed_write DIR BOOT NAME CONTENT — one closed/ file, made
# whole in a temp file and renamed into place, 0600 under a 0700 directory.
# Silent when it cannot be written: a hook never fails loudly.
roost_shape__closed_write() {
  local d="$1/closed/$2" tmp
  ( umask 077; mkdir -p "$d" ) 2>/dev/null || return 0
  tmp="$( (umask 077; mktemp "$d/.w.XXXXXX") 2>/dev/null)" || return 0
  if printf '%s' "$4" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$d/$3" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
  return 0
}

# roost_shape__kill_diff BEFORE AFTER -> prints, one per line, the pane ids
# in BEFORE and not in AFTER, each list "x" then space-separated ids (the
# hook's form). Compared as SETS: after a join-pane the new loop holds the
# same ids in another order on every build (probe 4.4), and a string compare
# would read that as a kill. An EMPTY after-list prints nothing: the server
# is ending (§3.6a, the last-session case). A word that is not `%N` is
# ignored, so a mangled argument can only name fewer panes, never more.
roost_shape__kill_diff() {
  local before="${1#x}" after="${2#x}" id
  case "$after" in *%[0-9]*) ;; *) return 0 ;; esac
  for id in $before; do
    case "$id" in %[0-9]*) ;; *) continue ;; esac
    case "${id#%}" in *[!0-9]*) continue ;; esac
    case " $after " in *" $id "*) ;; *) printf '%s\n' "$id" ;; esac
  done
}

# roost_shape__compact_stamp -> 20261102T081500Z, the history names' form,
# from the same clock as every stamp (ROOST_TEST_NOW when set).
roost_shape__compact_stamp() { roost_shape__stamp | tr -d ':-'; }

# roost_shape_auto FLAG SOCKET TRIGGER [PANE [BOOT [BEFORE AFTER]]] — `roost
# save --auto` (§3.4, §3.5): first what only this caller knows, then the
# want, then save when no other saver is busy. Exit 0 always; the caller
# throws stdout and stderr away.
#
# Step 1 (revision 3): a removal hook's kill difference and pane-exited's
# death note go to closed/<BOOT>/ BEFORE the want and the lock, and whatever
# happens to them: a held saver or a held restoring/ must never delay or drop
# them. BOOT is the boot key the hook passed — the running server's — never
# one read from a saved shape (§3.6a item 5).
roost_shape_auto() {
  local flag="$1" sock="$2" trigger="$3" pane="${4:-}" boot="${5:-}" before="${6:-}" after="${7:-}"
  local dir key r ids
  ROOST_SHAPE_TFLAG="$flag" ROOST_SHAPE_TSOCK="$sock"
  case "$pane" in %[0-9]*) case "${pane#%}" in *[!0-9]*) pane="" ;; esac ;; *) pane="" ;; esac
  case "$boot" in [0-9]*-[0-9]*) case "$boot" in *[!0-9-]*) boot="" ;; esac ;; *) boot="" ;; esac
  dir="$(roost_shape_dir "$flag" "$sock")" || return 0
  key="$(roost_shape_key "$flag" "$sock")"
  if [ -n "$boot" ]; then
    if [ -n "$before" ]; then
      ids="$(roost_shape__kill_diff "$before" "$after")"
      [ -n "$ids" ] && roost_shape__closed_write "$dir" "$boot" \
        "kill.$(roost_shape__compact_stamp)-$$" "$ids"$'\n'
    fi
    [ "$trigger" = pane-exited ] && [ -n "$pane" ] && \
      roost_shape__closed_write "$dir" "$boot" "died.${pane#%}" "$pane"$'\n'
  fi
  roost_shape__want "$dir" "$trigger${pane:+.$pane}" || return 0
  # Step 4: a live restore owns publishing until it ends; its final save
  # (--trigger restore) covers this want. A restoring/ whose owner is dead
  # holds nothing.
  if [ -d "$dir/restoring" ] && roost_shape_owner_live "$dir/restoring"; then
    return 0
  fi
  r=0; roost_shape__lock "$dir" || r=$?
  case "$r" in 0|2) ;; *) return 0 ;; esac
  # ROOST_TEST_SAVE_HOLD: the saver holds lock/ here, before its first
  # drain, until the file exists (the plan's seam).
  roost_shape__seam ROOST_TEST_SAVE_HOLD
  roost_shape__saver "$dir" "$key"
  return 0
}

# roost_shape_save_now FLAG SOCKET TRIGGER — §3.4's direct call, for roost's
# own verbs: `spawn`, `split`, `view` after the name is stamped, `close`
# after the pane is gone, `revive` and the resume engine after a respawn
# (respawn-pane -k fires no hook, §2.7), restore after `restoring/` is
# dropped. The same saver as the hooks' (roost_shape_auto), run to the end
# before the verb goes on, so a verb's own change is on disk when it returns.
# In a subshell, so the listing's arrays and the ROOST_SHAPE_* globals never
# reach the verb that called it; the owner record is then the verb's own pid,
# alive for as long as the subshell is. Silent and never fails its caller.
roost_shape_save_now() {
  ( roost_shape_auto "$1" "$2" "$3" ) >/dev/null 2>&1 || true
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
#
# On Linux it is `t:` and the start time in clock ticks since boot, field 22
# of /proc/PID/stat: `ps -o lstart=` there is boot time plus those ticks,
# and boot time moves with every step of the realtime clock (a laptop or a
# VM waking), so a live owner's record stopped matching and a second restore
# took it over (review round 5, Codex B3, Fable N2). The ticks do not move,
# and a new process on a reused pid has other ticks. Field 2, the command
# name, is in parentheses and may hold spaces and `)`, so the fields are
# counted from after its LAST `) `. Elsewhere (macOS keeps the absolute
# start time) it is `ps -o lstart=`, as before.
roost_shape__lstart() {
  local st
  local -a f
  if [ -r "/proc/$1/stat" ] && st="$(cat "/proc/$1/stat" 2>/dev/null)" && [ -n "$st" ]; then
    read -r -a f <<< "${st##*) }"
    # f[0] is field 3 (state), so field 22 is f[19].
    case "${f[19]:-}" in ''|*[!0-9]*) return 0 ;; esac
    printf 't:%s\n' "${f[19]}"
    return 0
  fi
  roost_shape__pslstart "$1"
}
roost_shape__pslstart() { ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//;s/ *$//'; }

# roost_shape__alive RECORD -> exit 0 when "PID LSTART" names a running
# process with that start time; ROOST_SHAPE_OWNER_PID is the pid. A record
# in the `ps -o lstart=` form on Linux was written by a roost from before
# the start ticks: it is compared in its own form, so that owner, if still
# running, is not taken for dead.
roost_shape__alive() {
  local pid="${1%% *}" lst="${1#* }"
  ROOST_SHAPE_OWNER_PID="$pid"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  lst="$(printf '%s' "$lst" | sed 's/^ *//;s/ *$//')"
  [ -n "$lst" ] || return 1
  case "$lst" in
    t:*) [ "$(roost_shape__lstart "$pid")" = "$lst" ] ;;
    *) [ "$(roost_shape__pslstart "$pid")" = "$lst" ] ;;
  esac
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
