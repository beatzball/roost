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
#     replies/000001.pane  what tmux STORED in @roost-reply for that turn, read
#                       back in the same tmux command that stored it; `read`
#                       serves the turn file only while the pane still holds
#                       exactly this (roost_record_match)
#     replies/000001.sent_by  who sent the prompt that started that turn (#56):
#                       the `--from LABEL` of the `roost send`, else `pane:%N`
#                       for a send from a pane on this server, else `human`.
#                       Written by `send` through roost_record_put_turn_field,
#                       and BEFORE the turn file: the label is known when the
#                       turn begins, the reply only when it ends
#     answers           one line per dialog answered with `roost answer`
#                       (#142), appended by roost_record_put_answer
#
# The server's boot key is in the path because tmux restarts pane ids at %0 on
# every server start (measured on tmux 3.3a, 3.4 and 3.6): keyed by socket and
# pane alone, a restarted server's %0 would overwrite the dead server's %0.
#
# Names reserved for later work (see the spec): name, session, window, cwd,
# state, harness, session_id, and further per-turn sidecars
# `replies/NNNNNN.<field>` (`.pane` is the one #42 uses, `.sent_by` the one
# #56 uses). Three of them are
# written now, and not from this file: `session_id`, `cwd` and `harness`, by
# scripts/lib/roost-identity.sh (#141), which creates the directory the way
# roost_record_append does. Nothing here writes them. A reader here counts a turn only when its name is
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
# THE WATCHDOG ESCALATES, and a plain `kill` is why it had to (#125). Against a
# SIGSTOPped server the client does not block — it spins, and a spinning tmux
# client does not act on the SIGTERM a bare `kill` sends. Measured on tmux 3.6 /
# macOS 26.3 by calling this function directly against a stopped throwaway
# server: the client sat at 100% CPU for 2 minutes 21 seconds against a
# 2-second watchdog, still in state R; an explicit SIGTERM afterwards left it R
# a second later, and only SIGKILL ended it. So the bound was not a bound —
# `roost forget --gone` never returned and a core stayed pegged until something
# else killed the client. SIGTERM first is kept because a client that CAN
# answer a signal should exit its own way; SIGKILL one second later is what
# makes the 2 seconds a promise. Worst case is therefore 3 seconds, not 2, and
# tests/test-reply-record.sh holds it to 8.
#
# A SIGKILLed probe leaves `status` at 137 with no output, which the shape check
# below reads as unknown — "could not ask", never "gone". That direction
# matters: a record is kept when roost cannot reach the server, and the
# assertions around the stopped-server case in tests/test-reply-record.sh pin
# exactly that.
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
    { sleep 2; kill "$probe"; sleep 1; kill -9 "$probe"; } \
      </dev/null >/dev/null 2>&1 3>&- 4<&- &
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

# roost_record_ensure DIR SOCKET -> 0, with ROOST_RECORD_CREATED set to 1 when
# this call made the pane directory, once DIR is a record this roost may write
# into: its directories exist, private, with a schema file and (when SOCKET is
# given) a socket file. 1 when it cannot be — not creatable, or a schema this
# roost does not understand. SOCKET may be "" for a writer that does not know
# it; the next writer that does backfills it.
#
# Split out of roost_record_append, unchanged, when `send` gained a sidecar to
# write BEFORE a pane's first turn exists (#56): the two writers must make a
# record the same way, and a record `send` created is still the one the hook
# then appends into. A caller that creates a record runs roost_record_sweep
# afterwards, as roost_record_append always has, because creation is the
# once-per-pane moment the sweep is tied to.
roost_record_ensure() {
  local dir="$1" sock="$2" st=0
  ROOST_RECORD_CREATED=0
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
      ROOST_RECORD_CREATED=1
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
  return 0
}

# roost_record_append DIR SOCKET TEXT -> ROOST_RECORD_TURN, and 0; 1 when
# nothing was recorded. The caller then sets @roost-reply exactly as before.
#
# Called once per turn, from the two places that set @roost-reply, and never on
# the PostToolUse path. Measured on the design machine: +7 to +17 ms on a turn
# end of 85 to 95 ms, most of it the forks for mkdir, mktemp, ln and rm.
roost_record_append() {
  local LC_ALL=C dir="$1" sock="$2" text="$3" tmp n f created=0
  ROOST_RECORD_TURN=""
  roost_record_ensure "$dir" "$sock" || return 1
  created="$ROOST_RECORD_CREATED"

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

  # ROOST_RECORD_NO_PRUNE=1 defers the prune to the caller, for a turn that is
  # not complete until a sidecar is written too (roost_record_append_interrupted):
  # pruning first and rolling the turn back after would leave the record
  # with no turns at all, and the next append would reuse a number.
  [ "${ROOST_RECORD_NO_PRUNE:-}" = 1 ] || roost_record_prune "$dir"
  if [ "$created" = 1 ]; then
    roost_record_sweep
  fi
  return 0
}

# roost_record_append_interrupted DIR SOCKET -> ROOST_RECORD_TURN, and 0; 1
# when nothing was recorded. An EMPTY turn file, then `replies/NNNNNN.outcome`
# holding `interrupted` (#95). It exists so an interrupted prompt KEEPS its
# turn number: a turn that ends with no reply records nothing, so the next
# prompt's reply would take its number and `wait-done --turn N` would return
# on the wrong prompt (the turn-over design, §5.4). The file is empty because
# the turn produced nothing; the sidecar says why, and is what `wait-done
# --turn N` reads to exit 5 and `read --turn N` to say so. Both are written by
# the two writers of this outcome: scripts/lib/roost-unblock.sh after a Claude
# interrupt it proved from the transcript, and scripts/roost-agent-state on
# `idle --interrupted` (codex's Interrupt, copilot's aborted idle). The
# sidecar is written second: a reader that sees the file without it reads an
# empty reply, which is true, rather than an outcome that is not there yet.
#
# TEXT, when given, is the turn's MAIN reply: an interrupt that ends a turn
# held by background work (#97) must not lose the answer the agent already
# gave, which the hold kept only on the pane (flock round 1 on #95).
#
# BOTH WRITES OR NEITHER (flock round 1 on #95). A turn file without its
# sidecar reads as a turn that FINISHED with an empty reply, and once the
# pane's own @roost-ended has gone stale `wait-done --turn N` would exit 0 on
# it: a false done, the direction this design exists to remove. So when the
# sidecar cannot be written the turn file is taken back and the call returns
# 1 -- "could not record", the behaviour before #95 (no turn file, the next
# prompt takes the number). The callers keep the badge change either way.
#
# The prune waits until both are written (flock round 2, reproduced): with
# ROOST_RECORD_KEEP=1 the append pruned turn N-1, the rollback then removed
# turn N, and the next append reused N-1's number.
roost_record_append_interrupted() {
  ROOST_RECORD_NO_PRUNE=1 roost_record_append "$1" "$2" "${3:-}" || return 1
  if ! roost_record_put_turn_field "$1" "$ROOST_RECORD_TURN" outcome interrupted "$2"; then
    roost_record_turn_file "$1" "$ROOST_RECORD_TURN"
    rm -f "$ROOST_RECORD_FILE" "$ROOST_RECORD_FILE".* 2>/dev/null || true
    ROOST_RECORD_TURN=""
    return 1
  fi
  roost_record_prune "$1"
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
    # The turn's sidecars go with it — `.pane`, `.sent_by` and `.outcome`
    # today, any `.<field>` later.
    rm -f "$f" "$f".* || return 0
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

# roost_record_put_pane DIR N STORED — record what tmux stored in @roost-reply
# for turn N, as `replies/NNNNNN.pane`. STORED is the output of a
# `show-options -pqv @roost-reply` run in the SAME tmux command as the
# set-option that stored it, so another writer cannot slip in between. Written
# whole or not at all; an empty value records nothing.
roost_record_put_pane() {
  [ -n "$3" ] || return 1
  roost_record_turn_file "$1" "$2"
  roost_record__put "$ROOST_RECORD_FILE.pane" "$3"
}

# roost_record_put_turn_field DIR N FIELD VALUE [SOCKET] — write one per-turn
# sidecar, `replies/NNNNNN.FIELD`, whole or not at all: a mktemp file in the
# same directory, 0600 as mktemp makes it, then mv, which is rename(2). A
# second write for the same turn and field replaces the first the same way.
# 0 when it was written; 1 when nothing was.
#
# `send --from` is the first caller (#56), and `roost answer` (#142) is the
# next: one writer here, so a new field is one call and not a second copy of
# the temp-and-rename dance. FIELD is `[a-z_]+` — the sidecar name is a file
# name, and the digit-only readers above stay blind to it only because it
# carries a suffix; VALUE is one non-empty line, so a reader can `read -r` it.
# N is checked the way roost_record_append checks its own number: digits, at
# most 15 of them, leading zeros allowed and dropped so `007` and `7` name the
# same turn.
#
# THE TURN FILE NEED NOT EXIST YET, and usually does not: `send` knows the turn
# number when the turn BEGINS (the badge left done/idle, so the next recorded
# reply is base + 1), and the reply that becomes the turn file is written by the
# Stop hook when the turn ENDS. So the record directory is created here when
# this is the pane's first turn, the way the hook would create it, and the
# sweep that creation triggers runs here for the same reason it runs there.
#
# What that opens, and what closes it: a turn that begins and then ends
# WITHOUT a reply — an API error, an interrupt, an answer that was all tool
# calls — records nothing, so its predicted number is taken by the NEXT turn,
# which would inherit this sidecar: a prompt the human typed by hand, read
# back as the coordinator's. `send` cannot know that when it writes, so the
# sidecar is dropped later instead, by roost_record_drop_pending below, which
# scripts/roost-agent-state calls when a NEW turn begins — the one point every
# harness passes through — and before it moves the badge that `send` waits
# for, so the label of the turn now starting is never there to be dropped.
roost_record_put_turn_field() {
  local LC_ALL=C dir="$1" n="$2" field="$3" value="$4" sock="${5:-}"
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#n}" -le 15 ] || return 1
  n=$((10#$n))
  case "$field" in ''|*[!a-z_]*) return 1 ;; esac
  case "$value" in ''|*$'\n'*) return 1 ;; esac
  roost_record_ensure "$dir" "$sock" || return 1
  roost_record_turn_file "$dir" "$n"
  roost_record__put "$ROOST_RECORD_FILE.$field" "$value" || return 1
  if [ "$ROOST_RECORD_CREATED" = 1 ]; then
    roost_record_sweep
  fi
  return 0
}

# roost_record_put_answer DIR LINE [SOCKET] — append one line to `answers`
# in the pane's record (#142): who answered a dialog with `roost answer`, how,
# and what roost saw confirm it. 0 when it was written, 1 when nothing was.
#
# NOT a per-turn sidecar, and that is the point of a file of its own (the
# answer design, §8): the turn that holds a dialog has no turn file yet, since
# a turn file is written at Stop, and one turn can hold several dialogs. So
# it is one line per answer, appended, never rewritten. LINE is one line, at
# most 1024 bytes: well under PIPE_BUF, so one append(2) cannot interleave
# with another writer's. Its last field is the dialog's description, which can
# hold a secret (scripts/roost-agent-state warns about @roost-blocked-on), so
# the file is 0600 like the replies beside it. `roost forget` removes it with
# the rest of the pane's record, and with ROOST_RECORD_DIR="" nothing is
# written, as for replies.
roost_record_put_answer() {
  local LC_ALL=C dir="$1" line="$2" sock="${3:-}"
  case "$line" in ''|*$'\n'*) return 1 ;; esac
  [ "${#line}" -le 1024 ] || return 1
  roost_record_ensure "$dir" "$sock" || return 1
  if [ ! -f "$dir/answers" ]; then
    ( umask 077; : >> "$dir/answers" ) 2>/dev/null || return 1
  fi
  { printf '%s\n' "$line" >> "$dir/answers"; } 2>/dev/null || return 1
  if [ "$ROOST_RECORD_CREATED" = 1 ]; then
    roost_record_sweep
  fi
  return 0
}

# roost_record_get_turn_field DIR N FIELD -> ROOST_RECORD_FIELD, the first
# line of `replies/NNNNNN.FIELD`, or "" when there is no such sidecar. The
# first line only, by `read -r` and no fork, the way roost_record__socket reads
# its one line: the writer above stores one line, and a file edited by hand to
# hold more must not hand a reader a value with a newline in it. FIELD is
# checked as the writer checks it, so a caller cannot read a path through it.
roost_record_get_turn_field() {
  local LC_ALL=C v=""
  ROOST_RECORD_FIELD=""
  case "$3" in ''|*[!a-z_]*) return 1 ;; esac
  roost_record_turn_file "$1" "$2"
  [ -f "$ROOST_RECORD_FILE.$3" ] || return 1
  IFS= read -r v < "$ROOST_RECORD_FILE.$3" || [ -n "$v" ] || return 1
  ROOST_RECORD_FIELD="$v"
}

# roost_record_drop_pending DIR — remove every sidecar filed beside the turn
# that has not been recorded yet: `replies/<MAX+1>.<field>`, where MAX is the
# newest recorded turn (0 when there is none) and MAX + 1 is the number `send`
# predicts and files its `sent_by` under. Nothing of a recorded turn is
# touched, and a record with no replies directory, or no record at all, is
# nothing to do. Always 0: this runs inside a hook under `set -e`, and a
# sidecar that could not be removed must not stop the badge from moving.
#
# WHY IT EXISTS: a turn that ends without a reply is never recorded, so the
# number `send` predicted for it goes to the next turn — and so would the
# label, unless something takes it away in between. The caller is
# scripts/roost-agent-state, on the stamp of `working` from a finished state,
# which is the start of that next turn whatever harness is running; its
# comment says why there and not on the error paths. `.pane` is written with
# the turn file, never before it, so the only sidecars this can find are the
# ones filed ahead of a turn: today `.sent_by`, and whatever #142 files next.
roost_record_drop_pending() {
  local dir="$1"
  [ -d "$dir/replies" ] || return 0
  roost_record_scan "$dir/replies"
  roost_record_turn_file "$dir" $((ROOST_RECORD_MAX + 1))
  rm -f "$ROOST_RECORD_FILE".* 2>/dev/null || true
  return 0
}

# roost_record_match REPLY DIR N -> 0, with ROOST_RECORD_TEXT set, when turn N's
# file may be printed in place of REPLY, the pane's current @roost-reply. This
# is the rule that makes "the pane wins" mechanical.
#
# The file stands in only while the pane still holds EXACTLY what tmux stored
# for that turn: REPLY must equal `NNNNNN.pane`. Both sides are tmux's own
# stored text, so they compare exactly whatever tmux did to the value on the way
# in. A value set any other way afterwards — by hand, by a writer that recorded
# nothing, by an older roost — differs, and the pane value is printed as before.
#
# WHY NOT COMPARE THE PANE WITH THE FILE. The first two versions did, first
# loosely and then by re-encoding the file (review round 1). That can only work
# if tmux stores what it is sent, and it does not (measured, one printable and
# one control byte per version, as a client with and without a UTF-8 locale):
#
#   tmux 3.4      `$` before a letter or `{` stored as `\$` (`$HOME` -> `\$HOME`)
#   3.4, 3.5a     control bytes and invalid UTF-8 stored as `\ooo`
#   3.3a/3.4/3.5a/3.7c, no UTF-8 locale:  newline, tab, non-ASCII -> `_`
#   3.6           as sent
#
# Those rewrites cannot be undone: `\$` may have been `$` or `\$`, `\033` may
# have been ESC or four characters, `_` may have been anything. CI on tmux 3.4
# printed a reply containing `$HOME` as `\$HOME` for exactly this reason (PR #84).
# Reading back what was stored sidesteps the question instead of modelling every
# version's rules, and it also serves the RAW bytes on those servers, where the
# pane value alone would print them rewritten.
#
# One defence is kept on top: when REPLY ends in roost_reply_encode's
# `[roost: reply truncated — M of N bytes]` marker, N must be the file's byte
# count, so a turn file replaced after the fact is not printed under an old
# pane value. A marker tmux mangled (no UTF-8 locale turns the dash into `_`)
# simply does not parse, and the sidecar comparison stands alone.
roost_record_match() {
  local LC_ALL=C reply="$1" stored tail n
  ROOST_RECORD_TEXT=""
  roost_record_turn_file "$2" "$3"
  roost_record_read "$ROOST_RECORD_FILE.pane" || return 1
  stored="$ROOST_RECORD_TEXT"
  [ -n "$stored" ] && [ "$reply" = "$stored" ] || return 1
  roost_record_turn_file "$2" "$3"
  roost_record_read "$ROOST_RECORD_FILE" || return 1
  tail="${reply##*$'\n'}"
  case "$tail" in
    "[roost: reply truncated — "*" of "*" bytes]")
      n="${tail##* of }"
      n="${n% bytes]}"
      [ "$n" = "${#ROOST_RECORD_RAW}" ] || return 1 ;;
  esac
  return 0
}
