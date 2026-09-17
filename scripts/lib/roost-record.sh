# roost-record.sh — the per-pane record that outlives the pane (#74), and the
# durable reply history built on it (#42).
#
# Sourced by scripts/roost-agent-state (the Claude and codex Stop hook) and by
# bin/roost (`reply`, `read`, `forget`). The design, and every measurement these
# rules rest on, is docs/airig/specs/2026-09-16-pane-record-design.md.
#
# THE PANE OPTION STAYS THE TRUTH. @roost-reply is still written exactly as
# before, and `read` serves a file only when it agrees with that value. A
# record is a copy that survives what the pane cannot: a reply past the 12 KB
# cap, an earlier turn, and a pane that is gone. Everything here fails soft —
# any step that cannot be done leaves the pane option to do its job.
#
# THE LAYOUT, one directory per pane, plain files, no parser:
#
#   <root>/<start_time>-<server_pid>/<pane_number>/
#     schema            "1"
#     socket            the socket path of the server that wrote it
#     replies/000001    the raw bytes of one turn's reply, one file per turn
#
# The server's boot key is in the path because tmux restarts pane ids at %0 on
# every server start (measured on tmux 3.3a, 3.4 and 3.6): keyed by socket and
# pane alone, a restarted server's %0 would overwrite the dead server's %0.
#
# Names reserved for later work, which nothing here writes (see the spec):
# name, session, window, cwd, state, harness, session_id, and per-turn sidecars
# `replies/NNNNNN.<field>`. A reader here counts a turn only when its name is
# digits alone, which is what keeps those sidecars — and `.tmp.*` files —
# invisible to it.
#
# NO LOCK. macOS ships no flock(1). A turn is written to a mktemp file and
# hard-linked into place: link(2) refuses a name that exists, so two writers
# can never take the same number, and a reader, which lists only digit names,
# can never see half a file. Measured: 40 writer processes on one pane at once,
# no turn lost, no partial read, on macOS and in the Ubuntu CI image.
#
# Everything here is bash 3.2: no BASHPID, no associative arrays, and no
# expansion of an array that may be empty, because the Stop hook runs under
# `set -u` and bash 3.2 calls an empty "${a[@]}" unbound.

ROOST_RECORD_SCHEMA=1

# roost_record_root -> ROOST_RECORD_ROOT, the directory records live in, or ""
# when nothing may be recorded.
#
# SETS rather than prints, the roost_self_socket and roost_ext__roots shape: the
# Stop hook calls it once per turn, and a $(...) is a fork.
#
# ROOST_RECORD_DIR, when SET, wins outright — even when empty, which is how a
# test (and tests/lib.sh for the whole suite) switches recording off. It must be
# an absolute path; anything else records nothing. Unset, the default is
# $XDG_STATE_HOME/roost/panes, beside the extension state roost_ext__roots
# already keeps under $XDG_STATE_HOME/roost. A relative XDG_STATE_HOME is
# ignored, as the XDG spec says and scripts/roost-wiring does for
# XDG_CONFIG_HOME; then $HOME/.local/state. No usable HOME either: nothing.
#
# Trailing slashes are dropped, and a root that is then empty — "/" — is
# refused: `forget --all` removes directories under this path.
roost_record_root() {
  local r x
  ROOST_RECORD_ROOT=""
  if [ "${ROOST_RECORD_DIR+set}" = set ]; then
    r="$ROOST_RECORD_DIR"
  else
    x="${XDG_STATE_HOME:-}"
    case "$x" in
      /*) r="$x/roost/panes" ;;
      *)
        case "${HOME:-}" in
          /*) r="$HOME/.local/state/roost/panes" ;;
          *) return 0 ;;
        esac ;;
    esac
  fi
  case "$r" in /*) ;; *) return 0 ;; esac
  while [ "${r%/}" != "$r" ]; do r="${r%/}"; done
  [ -n "$r" ] || return 0
  ROOST_RECORD_ROOT="$r"
}

# roost_record_keep -> ROOST_RECORD_KEEP_N: turns kept per pane. A positive
# integer from ROOST_RECORD_KEEP, else 100 (measured: 99% of Claude transcripts
# on the design machine held 90 turns or fewer).
roost_record_keep() {
  local LC_ALL=C
  case "${ROOST_RECORD_KEEP:-}" in
    ''|*[!0-9]*|0*) ROOST_RECORD_KEEP_N=100 ;;
    *) ROOST_RECORD_KEEP_N="$ROOST_RECORD_KEEP" ;;
  esac
}

# roost_record_days -> ROOST_RECORD_DAYS_N: days after which a record that is
# not live is swept. A non-negative integer from ROOST_RECORD_DAYS, else 30.
roost_record_days() {
  local LC_ALL=C
  case "${ROOST_RECORD_DAYS:-}" in
    ''|*[!0-9]*) ROOST_RECORD_DAYS_N=30 ;;
    *) ROOST_RECORD_DAYS_N="$ROOST_RECORD_DAYS" ;;
  esac
}

# roost_record_pane_dir BOOT PANE -> ROOST_RECORD_PANE_DIR, and 0; or 1 when
# records are off or either key is not the shape tmux gives.
#
# BOOT is `#{start_time}-#{pid}`, PANE is `%N`. Both are checked before they
# become a path, so a value from an option or an argument can never climb out
# of the root. The pane number is used without its `%`, so a path is never a
# printf format.
roost_record_pane_dir() {
  local LC_ALL=C boot="$1" pane="$2" n
  ROOST_RECORD_PANE_DIR=""
  [ -n "${ROOST_RECORD_ROOT:-}" ] || return 1
  case "$boot" in
    [0-9]*-[0-9]*) ;;
    *) return 1 ;;
  esac
  case "${boot%%-*}${boot#*-}" in ''|*[!0-9]*) return 1 ;; esac
  case "$pane" in %[0-9]*) ;; *) return 1 ;; esac
  n="${pane#%}"
  case "$n" in *[!0-9]*) return 1 ;; esac
  ROOST_RECORD_PANE_DIR="$ROOST_RECORD_ROOT/$boot/$n"
}

# roost_record_schema DIR -> 0 when DIR is a record this roost understands.
#   1  no record: DIR is missing, or it holds neither schema nor replies/ — a
#      record a writer is still creating reads as none, not as damage
#   2  unreadable: no schema, or not a plain integer; ROOST_RECORD_SCHEMA_SEEN
#      holds what was there
#   3  newer: an integer larger than ROOST_RECORD_SCHEMA
# `read -r` rather than $(cat): no fork, and a schema is one short line.
roost_record_schema() {
  local LC_ALL=C s=""
  ROOST_RECORD_SCHEMA_SEEN=""
  [ -d "$1" ] || return 1
  if [ ! -f "$1/schema" ]; then
    [ -d "$1/replies" ] || return 1
    return 2
  fi
  IFS= read -r s < "$1/schema" || [ -n "$s" ] || true
  ROOST_RECORD_SCHEMA_SEEN="$s"
  case "$s" in
    ''|*[!0-9]*|0*) return 2 ;;
  esac
  [ "${#s}" -le 9 ] || return 3
  [ "$s" -le "$ROOST_RECORD_SCHEMA" ] || return 3
  [ "$s" = "$ROOST_RECORD_SCHEMA" ] || return 2
  return 0
}

# roost_record__put FILE CONTENT — write FILE whole or not at all: a mktemp
# file beside it, then mv, which is rename(2).
roost_record__put() {
  local tmp
  tmp="$(mktemp "${1%/*}/.tmp.XXXXXX" 2>/dev/null)" || return 1
  if { printf '%s' "$2" > "$tmp"; } 2>/dev/null && mv -f "$tmp" "$1" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# roost_record_scan REPLIES_DIR -> ROOST_RECORD_COUNT, ROOST_RECORD_MIN,
# ROOST_RECORD_MAX (0 when there are none).
#
# Numeric, not glob order: six-digit zero padding sorts correctly only up to
# 999999, and turn 1000000 is seven digits. No fork: this runs on every turn.
# A name longer than 15 digits is not ours and is skipped rather than handed to
# arithmetic that would overflow.
roost_record_scan() {
  local LC_ALL=C f b v
  ROOST_RECORD_COUNT=0 ROOST_RECORD_MIN=0 ROOST_RECORD_MAX=0
  for f in "$1"/[0-9]*; do
    [ -f "$f" ] || continue
    b="${f##*/}"
    case "$b" in *[!0-9]*) continue ;; esac
    [ "${#b}" -le 15 ] || continue
    v=$((10#$b))
    ROOST_RECORD_COUNT=$((ROOST_RECORD_COUNT + 1))
    if [ "$ROOST_RECORD_COUNT" -eq 1 ] || [ "$v" -lt "$ROOST_RECORD_MIN" ]; then ROOST_RECORD_MIN="$v"; fi
    if [ "$v" -gt "$ROOST_RECORD_MAX" ]; then ROOST_RECORD_MAX="$v"; fi
  done
}

# roost_record_turn_file DIR N -> ROOST_RECORD_FILE, the path turn N would have.
roost_record_turn_file() {
  local name
  printf -v name '%06d' "$2"
  ROOST_RECORD_FILE="$1/replies/$name"
}

# roost_record_back DIR K -> ROOST_RECORD_BACK, the number of the K-th newest
# turn that exists (1 is the newest), or "". Walks the turns that are there, so
# a gap a human made by deleting a file is stepped over rather than counted.
#
# The list is built in a variable and sorted by one sort(1), rather than in a
# $(for ...; case ...) — bash 3.2 cannot parse a `case` pattern's `)` inside
# $(...), which is how the first version of this failed on macOS.
roost_record_back() {
  local LC_ALL=C f b list=""
  ROOST_RECORD_BACK=""
  for f in "$1"/replies/[0-9]*; do
    [ -f "$f" ] || continue
    b="${f##*/}"
    case "$b" in *[!0-9]*) continue ;; esac
    [ "${#b}" -le 15 ] || continue
    list="$list$((10#$b))
"
  done
  [ -n "$list" ] || return 0
  ROOST_RECORD_BACK="$(printf '%s' "$list" | sort -n | tail -n "$2" | head -n 1)"
  roost_record_scan "$1/replies"
  [ "$2" -le "$ROOST_RECORD_COUNT" ] || ROOST_RECORD_BACK=""
}

# roost_record_live SOCKET BOOT PANE -> 0 when the server at SOCKET is still the
# boot that wrote the record and still has the pane.
#
# One question to tmux, and nothing to the kernel. A pid never reaches `kill -0`
# or `ps`, so a pid the system has handed to an unrelated process cannot make a
# record look live: a boot key whose pid now belongs to something else simply
# does not match what the server says about itself. #{pane_current_command} is
# not part of it (it changes during one agent's run — measured) and neither is
# #{pane_pid} (respawn-pane -k keeps the pane and changes it; the history
# belongs to the pane).
#
# What could still fool it: a new server on the same socket, with the same pid,
# started in the same second. That needs a pid wrap inside one second.
#
# Returns 0 only for "live". Code that DELETES must not read its 1 as "gone" —
# use roost_record_liveness, which can also answer "unknown".
roost_record_live() {
  roost_record_liveness "$@"
  [ "$ROOST_RECORD_LIVENESS" = live ]
}

# roost_record_liveness SOCKET BOOT PANE -> ROOST_RECORD_LIVENESS: live, gone,
# or unknown. Only `gone` may be acted on by anything that deletes.
#
# THREE answers, because "could not ask" is not "not there". With tmux off PATH,
# or a socket directory the caller cannot search, the first version answered
# "not live" and `forget --gone` removed a live pane's history at exit 0 (review
# round 1, reproduced). The second version decided some cases with test(1)
# before asking tmux, and `[ -d ]` is false for "no such directory" and for
# "not allowed to look" alike, so a locked grandparent directory, or a sandbox
# hiding /tmp/tmux-UID, still deleted live records (review round 2, reproduced).
# So nothing is decided from the filesystem: tmux is asked, and its answer read.
#
#   live     tmux printed exactly "BOOT PANE"
#   gone     tmux printed a boot key that is not BOOT, or BOOT with no such
#            pane; or it failed with "no server running on" (a socket file a
#            killed server left) or "(No such file or directory)" (the socket
#            or its directory is not there — tmux unlinks its socket on exit)
#   unknown  anything else: no socket recorded, tmux not found, "(Permission
#            denied)", "(Operation not permitted)", any other error or output,
#            or no answer within 2 seconds
#
# Measured on macOS tmux 3.6, Alpine tmux 3.4 and Ubuntu tmux 3.3a, as a normal
# user: a locked parent or grandparent gives "Permission denied"; a missing
# socket or missing directory gives "No such file or directory". The strerror
# half is locale text, so LC_MESSAGES=C is pinned for this one call — with
# LC_ALL removed from its environment, because LC_ALL outranks LC_MESSAGES and
# a UTF-8 LC_CTYPE is left alone.
#
# A 2-second bound, because a stopped server (kill -STOP, a debugger) accepts the
# connection and never answers, and `tmux display-message` then waits forever
# (review round 1, reproduced). macOS ships no timeout(1), so the probe runs in
# the background beside a watchdog that kills it.
#
# Its output goes to a FILE, not to the command substitution's pipe. A tmux
# client hands its stdout to the server, so a stopped server holds a pipe's
# write end open and `$(...)` waits for it forever — the watchdog killed the
# client and the caller still hung (measured while fixing review round 2). The
# file is unlinked the moment it is opened, and read back through a second
# descriptor opened before the unlink, so a caller killed mid-probe leaves
# nothing behind (review round 2). A killed client exits 0 with no output, which
# the shape check below reads as unknown. `sleep 2` is a whole number of
# seconds, which every sleep(1) accepts.
roost_record_liveness() {
  local sock="$1" got rc body
  ROOST_RECORD_LIVENESS=unknown
  [ -n "$sock" ] || return 0
  command -v tmux >/dev/null 2>&1 || return 0
  got="$(
    f="$(mktemp "${TMPDIR:-/tmp}/roost-live.XXXXXX" 2>/dev/null)" || exit 0
    exec 3>"$f" 4<"$f"
    rm -f "$f"
    env -u LC_ALL LC_MESSAGES=C tmux -S "$sock" display-message -p -t "$3" \
      '#{start_time}-#{pid} #{pane_id}' </dev/null >&3 2>&3 3>&- 4<&- &
    probe=$!
    { sleep 2; kill "$probe"; } </dev/null >/dev/null 2>&1 3>&- 4<&- &
    dog=$!
    status=0
    wait "$probe" || status=$?
    kill "$dog" 2>/dev/null
    exec 3>&-
    cat <&4
    printf '\nrc=%s' "$status"
  )"
  case "$got" in *"
rc="*) ;; *) return 0 ;; esac
  rc="${got##*
rc=}"
  body="${got%
rc=*}"
  # tmux ends its answer, and its error, with a newline of its own.
  body="${body%
}"
  if [ "$rc" = 0 ]; then
    if [ "$body" = "$2 $3" ]; then
      ROOST_RECORD_LIVENESS=live
      return 0
    fi
    # Only an answer shaped like tmux's own is trusted to say "not this pane".
    # An empty or mangled one (a full disk, a wrapper printing something else)
    # stays unknown.
    case "$body" in
      [0-9]*-[0-9]*" "|[0-9]*-[0-9]*" %"[0-9]*) ROOST_RECORD_LIVENESS=gone ;;
    esac
    return 0
  fi
  case "$body" in
    "no server running on "*) ROOST_RECORD_LIVENESS=gone ;;
    "error connecting to "*"(No such file or directory)") ROOST_RECORD_LIVENESS=gone ;;
  esac
  return 0
}

# roost_record_is_record DIR -> 0 when DIR is a pane record roost wrote: its
# name is a pane number, its parent's name is a boot key, and it holds a
# `schema` file — the first thing a writer creates, and the one file every
# record has. Anything that deletes checks this, so a directory that merely has
# the right SHAPE under the root is left alone, even one holding a `replies/`
# (review round 1 reproduced all three delete paths removing such directories).
# A record whose schema file was lost is not removed by any `forget` form; its
# directory is the user's to delete.
roost_record_is_record() {
  local dir="$1" n boot
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  n="${dir##*/}"
  boot="${dir%/*}"; boot="${boot##*/}"
  roost_record_pane_dir "$boot" "%$n" || return 1
  [ "$ROOST_RECORD_PANE_DIR" = "$dir" ] || return 1
  [ -f "$dir/schema" ] && [ ! -L "$dir/schema" ]
}

# roost_record__socket DIR -> ROOST_RECORD_SOCKET_SEEN, the recorded socket path.
roost_record__socket() {
  local s=""
  ROOST_RECORD_SOCKET_SEEN=""
  [ -f "$1/socket" ] || return 1
  IFS= read -r s < "$1/socket" || [ -n "$s" ] || true
  ROOST_RECORD_SOCKET_SEEN="$s"
}

# roost_record_append DIR SOCKET TEXT -> ROOST_RECORD_TURN, and 0; 1 when
# nothing was recorded. The caller then sets @roost-reply exactly as before.
#
# Called once per turn, from the two places that set @roost-reply, and never on
# the PostToolUse path. Measured on the design machine: +7 to +17 ms on a turn
# end of 85 to 95 ms, most of it the forks for mkdir, mktemp, ln and rm.
roost_record_append() {
  local LC_ALL=C dir="$1" sock="$2" text="$3" tmp n f created=0 st=0
  ROOST_RECORD_TURN=""
  [ -n "$dir" ] || return 1

  # 0700 on the two directories this creates: a record holds what an agent
  # said. mktemp already makes every file 0600, and a hard link keeps it.
  if [ ! -d "$dir" ]; then
    # The root is made 0700 only when this creates it — a ROOST_RECORD_DIR the
    # user made keeps the mode they gave it. Its parents (…/state/roost is
    # shared with extension state) are not touched. Review round 1 found the
    # first version left the root 0755, so any local user could list boot keys.
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

  # Backfill, then check. A missing field of this schema is written; a record
  # with a schema this roost does not understand — newer, or damaged — is never
  # written into: an older roost must not add to a newer one's record, and a
  # damaged one is for a human to look at (`read` warns, `forget` removes).
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
  if [ ! -d "$dir/replies" ]; then
    mkdir -m 700 "$dir/replies" 2>/dev/null || [ -d "$dir/replies" ] || return 1
  fi

  # mktemp, not .tmp.$$: inside a subshell $$ is the PARENT's pid, and two
  # writers forked from one shell then shared a temp name and deleted each
  # other's file — the design prototype hung on exactly that. bash 3.2 has no
  # BASHPID to use instead.
  tmp="$(mktemp "$dir/replies/.tmp.XXXXXX" 2>/dev/null)" || return 1
  # The braces carry the 2>/dev/null to the redirection itself: a temp file
  # removed under a writer (a racing `forget`) otherwise prints bash's own
  # "No such file or directory" from inside the hook (review round 1).
  if ! { printf '%s' "$text" > "$tmp"; } 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi

  roost_record_scan "$dir/replies"
  n=$((ROOST_RECORD_MAX + 1))
  while :; do
    # Past 15 digits every reader skips the name (roost_record_scan), so a turn
    # written there could never be read, counted or pruned. Refuse instead.
    if [ "${#n}" -gt 15 ]; then
      rm -f "$tmp"
      return 1
    fi
    roost_record_turn_file "$dir" "$n"
    f="$ROOST_RECORD_FILE"
    # A name that is already there and is not a turn roost can read — a
    # directory, a symlink (dangling or not) — is stepped past BEFORE ln sees
    # it. `ln TMP DIR` links INTO a directory and exits 0, so the first version
    # reported the same turn number forever and, through a symlink, wrote the
    # reply outside the record root (review round 1, reproduced).
    if [ -e "$f" ] || [ -L "$f" ]; then
      n=$((n + 1))
      continue
    fi
    if ln "$tmp" "$f" 2>/dev/null; then
      break
    fi
    # Retry ONLY on a name that exists: another writer took it. ln also fails
    # when the source is gone, the disk is full, or the filesystem has no hard
    # links, and a loop that retried on those never ends — the prototype's
    # second hang. Every retry steps past a name that is really there, so the
    # loop ends: there are only so many.
    if [ ! -e "$f" ] && [ ! -L "$f" ]; then
      rm -f "$tmp"
      return 1
    fi
    n=$((n + 1))
  done
  rm -f "$tmp"
  ROOST_RECORD_TURN="$n"

  roost_record_prune "$dir"
  if [ "$created" = 1 ]; then
    roost_record_sweep
  fi
  return 0
}

# roost_record_prune DIR — remove the oldest turns beyond ROOST_RECORD_KEEP.
# Rescans after each removal rather than sorting once: normally one file goes
# per turn, and a keep lowered by hand is a one-off.
#
# Pruning is never silent to a reader: `read --turn` names a pruned turn and the
# range that is kept.
roost_record_prune() {
  local f
  roost_record_keep
  roost_record_scan "$1/replies"
  while [ "$ROOST_RECORD_COUNT" -gt "$ROOST_RECORD_KEEP_N" ]; do
    roost_record_turn_file "$1" "$ROOST_RECORD_MIN"
    f="$ROOST_RECORD_FILE"
    [ -f "$f" ] || return 0
    rm -f "$f" || return 0
    roost_record_scan "$1/replies"
  done
}

# roost_record_sweep — remove every pane record that is not live and whose
# replies/ has not changed in ROOST_RECORD_DAYS days.
#
# Run only when a NEW pane record is created — once per pane, never once per
# turn — so the find(1) fork is not on every Stop. replies/ is what is dated,
# because linking a turn changes its mtime and not the pane directory's. Only a
# record roost_record_liveness calls gone is removed: a live pane is never swept,
# however long ago it last replied, and neither is one that cannot be checked.
# The check is bounded at 2 seconds per candidate, and candidates are only
# records older than ROOST_RECORD_DAYS, so a wedged server costs a new pane's
# first turn at most that.
#
# find's -mindepth, -maxdepth and -mtime exist in BSD, GNU and busybox find.
roost_record_sweep() {
  local f pane bootdir boot n
  [ -n "${ROOST_RECORD_ROOT:-}" ] && [ -d "$ROOST_RECORD_ROOT" ] || return 0
  roost_record_days
  while IFS= read -r f; do
    pane="${f%/replies}"
    bootdir="${pane%/*}"
    boot="${bootdir##*/}"
    n="${pane##*/}"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    roost_record_is_record "$pane" || continue
    roost_record__socket "$pane" || true
    # Only a record known to be gone. A live one is kept however old; one that
    # cannot be checked is kept too, and `roost forget --gone` names it.
    roost_record_liveness "$ROOST_RECORD_SOCKET_SEEN" "$boot" "%$n"
    [ "$ROOST_RECORD_LIVENESS" = gone ] || continue
    rm -rf "$pane"
    rmdir "$bootdir" 2>/dev/null || true
  done < <(find "$ROOST_RECORD_ROOT" -mindepth 3 -maxdepth 3 -type d -name replies \
             -mtime +"$ROOST_RECORD_DAYS_N" 2>/dev/null)
  return 0
}

# roost_record_read FILE -> ROOST_RECORD_RAW (every byte), ROOST_RECORD_TEXT
# (trailing newlines dropped — what a $(...) of the pane option gives, so the
# two compare and print alike). The sentinel keeps $(...) from eating the
# trailing newlines of RAW, whose byte count the match check needs.
roost_record_read() {
  local raw
  [ -f "$1" ] && [ -r "$1" ] || return 1
  raw="$(cat "$1" 2>/dev/null; printf x)" || return 1
  raw="${raw%x}"
  ROOST_RECORD_RAW="$raw"
  while [ "${raw%$'\n'}" != "$raw" ]; do raw="${raw%$'\n'}"; done
  ROOST_RECORD_TEXT="$raw"
}

# roost_record_match REPLY FILE -> 0, with ROOST_RECORD_TEXT set, when the file
# may be printed in place of REPLY. This is the rule that makes "the pane wins"
# mechanical: a file can only ever replace a pane value it agrees with.
#
#   - REPLY equals the file (trailing newlines aside), so printing the file is
#     printing the same bytes; or
#   - REPLY is EXACTLY what roost_reply_encode makes of the file's bytes: the
#     same head, cut back to the same newline, and the same
#     `[roost: reply truncated — M of N bytes]` marker.
#
# The second is checked by re-encoding the file with the M the marker names and
# comparing the whole value. The first version checked only N and that the head
# was a prefix, so a pane value with a shorter head, or a marker whose M did not
# match its head, still let the file through (review round 1, reproduced). M is
# taken from the marker rather than from this process's ROOST_REPLY_MAX: a
# writer with a different cap produced a head that is still exactly that file's.
#
# Anything else, including a value tmux rewrote on the way in, keeps the pane
# value: today's output. Byte lengths under LC_ALL=C, the reply channel's rule.
roost_record_match() {
  local LC_ALL=C reply="$1" tail m enc
  ROOST_RECORD_TEXT=""
  roost_record_read "$2" || return 1
  if [ "$reply" = "$ROOST_RECORD_TEXT" ]; then
    return 0
  fi
  tail="${reply##*$'\n'}"
  case "$tail" in
    "[roost: reply truncated — "*" of "*" bytes]") ;;
    *) return 1 ;;
  esac
  m="${tail#\[roost: reply truncated — }"
  m="${m%% of *}"
  case "$m" in ''|*[!0-9]*|0*) return 1 ;; esac
  [ "${#m}" -le 9 ] || return 1
  if ! command -v roost_reply_encode >/dev/null 2>&1; then
    . "${BASH_SOURCE[0]%/*}/roost-reply.sh" 2>/dev/null || return 1
  fi
  # The cap goes in as a prefix assignment, which bash undoes when the function
  # returns. A `local ROOST_REPLY_MAX` here, in a process where this call was
  # the first to source roost-reply.sh, swallowed that file's global default and
  # left the variable unset for any later roost_reply_encode (review round 2).
  enc="$(ROOST_REPLY_MAX="$m" roost_reply_encode "$ROOST_RECORD_RAW")"
  [ "$enc" = "$reply" ] || return 1
  return 0
}
