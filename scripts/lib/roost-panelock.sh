# roost-panelock.sh — one writer per pane input box at a time (#175).
#
# A pane's input box is a single shared line, and two commands that type into
# it at once destroy each other's work: one's C-u clears the other's paste, one
# presses Enter on what the other typed, and the one whose text never landed
# still sees "the screen changed" and reports success. `send` is the first
# writer and this file is its lock; `answer` (#142), which will type a key
# into a blocked pane and then watch the badge, is the second and should take
# the same one, so that a `send --force` and an `answer` aimed at one dialog
# cannot both land.
#
# THE LOCK IS A DIRECTORY BESIDE THE SERVER'S SOCKET, named for the socket and
# the pane: `<socket dir>/roost-send-lock.<socket name>.<N>`. That scopes it to
# one server by construction — a `-S` test server in a mktemp directory and
# the real `-L roost` server can never share one — and it dies with the socket
# directory, so a throwaway server leaves nothing behind. Not under the record
# directory, which the suite and any user can turn off, and not
# XDG_RUNTIME_DIR, which macOS does not set. mkdir because it is atomic on
# every file system that matters and macOS ships no flock(1) — the choice
# roost-events.sh made for its reconcile lock, for the same reason.
#
# A HOLDER THAT DIED TAKES ITS LOCK WITH IT: the caller's EXIT trap calls
# roost_panelock_drop. A holder that was SIGKILLed cannot, so the directory
# carries the holder's pid and a waiter whose holder is gone takes the lock
# over — under a second `.take` directory, re-checked once that is held, so
# two waiters that both saw the dead holder cannot both replace it.
#
# WHAT "GONE" MEANS, and each clause was earned by review:
#   - the pid is not alive (kill -0 fails). A pid another user owns reads as
#     gone here too (EPERM); sends are per user, so that is not a case worth
#     a worse rule;
#   - the pid is alive but is NOT A ROOST — `ps -o args=` does not mention
#     roost. A killed sender's pid can be handed to a long-lived stranger,
#     and without this clause every later send to that pane would wait the
#     whole bound and fail, for as long as the stranger lived. A real sender
#     is `bash .../bin/roost send …`, so its args always carry the name;
#   - there is NO PID FILE and the directory is a minute old. A holder between
#     its mkdir and its pid write takes microseconds, so a minute is a holder
#     that died in that gap. A holder STOPPED in that gap for a minute would
#     lose its lock and then write its pid into the taker's — known, and not
#     worth a rule that could never take over a lock with no pid at all.
#
# Taking over is itself done safely twice. A `.take` a minute old is a taker
# that was killed mid-takeover; it is moved aside with mv (rename(2), so one
# of two waiters that both found it old wins and the other's mv fails) and
# then removed, never rmdir'd in place, where the second waiter's rmdir
# would remove the first's FRESH guard. And a stale lock that cannot be
# removed (a permission, a file system in trouble) does not spin: every pass
# of the loop pays one tick toward the bound, takeover or not.
#
# Sourced, not executed, `roost_panelock_*` prefix. NO TMUX CALL: the caller
# passes the socket path and pane id it has already read, so this file needs
# nothing but mkdir, rmdir, mv, rm, find, kill, ps and cat, and a test can
# drive it with no server at all. find's -maxdepth and -mmin exist in BSD,
# GNU and busybox find. Every `&&` list ends in `|| true`: bin/roost runs
# under `set -e`, and a failing LAST command of an `&&` list is not exempt.
#
#   roost_panelock_path SOCKET_PATH PANE_ID
#       Prints the lock directory for that pane on that server, or nothing
#       when the two are not an absolute path and a %N.
#   roost_panelock_take SOCKET_PATH PANE_ID TIMEOUT_SECONDS
#       0: held — ROOST_PANELOCK names the directory and ROOST_PANELOCK_HELD
#          is 1. The CALLER installs the trap that calls roost_panelock_drop:
#          a trap is per process and belongs to the command that owns the
#          other things it cleans up, and installing it here would replace
#          one the caller already has.
#       1: another process held it for the whole TIMEOUT. Nothing was taken.
#       2: nothing to lock — the arguments were not a socket path and a pane.
#       3: the directory was made but the pid file could not be written, so
#          the lock was given back: a lock with no pid would read as stale a
#          minute later and be taken from under a live holder. The caller
#          decides what to do without a lock.
#   roost_panelock_drop
#       Removes the lock this process holds, if any. Always 0.
#
# The polls are a tenth of a second (`sleep 1` where sleep cannot do fractions),
# so TIMEOUT 0 means one attempt and no wait — plus the one more attempt a
# takeover earns. Leading zeros are stripped from TIMEOUT: `08` is not octal
# to a human, and `$(( ))` would abort on it (the same strip bin/roost gives
# its other knobs, for the same measured reason).
ROOST_PANELOCK=""
ROOST_PANELOCK_HELD=0

roost_panelock_path() {
  case "$2" in %[0-9]*) ;; *) return 0 ;; esac
  case "$1" in /*) ;; *) return 0 ;; esac
  printf '%s/roost-send-lock.%s.%s\n' "${1%/*}" "${1##*/}" "${2#%}"
}

# 0 when the holder of the lock at $1 is gone.
roost_panelock__stale() {
  local pid
  pid="$(cat "$1/pid" 2>/dev/null || true)"
  case "$pid" in
    ''|*[!0-9]*) [ -n "$(find "$1" -maxdepth 0 -mmin +1 2>/dev/null)" ] ;;
    *)
      if kill -0 "$pid" 2>/dev/null; then
        case "$(ps -o args= -p "$pid" 2>/dev/null || true)" in *roost*) return 1 ;; esac
      fi
      return 0 ;;
  esac
}

# 0 held, 1 someone else has it, 3 made but the pid could not be kept.
roost_panelock__mkdir() {
  mkdir "$1" 2>/dev/null || return 1
  if ! printf '%s\n' "$$" > "$1/pid" 2>/dev/null; then
    rmdir "$1" 2>/dev/null || true
    return 3
  fi
  ROOST_PANELOCK="$1"
  ROOST_PANELOCK_HELD=1
  return 0
}

roost_panelock_take() {
  local lock timeout ticks=0 rc
  lock="$(roost_panelock_path "$1" "$2")"
  [ -n "$lock" ] || return 2
  case "$3" in ''|*[!0-9]*) timeout=0 ;; *) timeout="$3" ;; esac
  while [ "${#timeout}" -gt 1 ] && [ "${timeout%${timeout#?}}" = 0 ]; do
    timeout="${timeout#0}"
  done
  while :; do
    rc=0; roost_panelock__mkdir "$lock" || rc=$?
    case "$rc" in 0) return 0 ;; 3) return 3 ;; esac
    if roost_panelock__stale "$lock"; then
      if [ -n "$(find "$lock.take" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
        mv "$lock.take" "$lock.take.old.$$.$RANDOM" 2>/dev/null && rm -rf "$lock".take.old.* 2>/dev/null || true
      fi
      if mkdir "$lock.take" 2>/dev/null; then
        roost_panelock__stale "$lock" && rm -rf "$lock" 2>/dev/null || true
        rmdir "$lock.take" 2>/dev/null || true
        # The attempt a takeover earns, so that TIMEOUT 0 can still take over
        # a dead holder's lock. Every pass still pays its tick below.
        rc=0; roost_panelock__mkdir "$lock" || rc=$?
        case "$rc" in 0) return 0 ;; 3) return 3 ;; esac
      fi
    fi
    [ "$ticks" -lt $((timeout * 10)) ] || return 1
    sleep 0.1 2>/dev/null || sleep 1
    ticks=$((ticks + 1))
  done
}

roost_panelock_drop() {
  if [ "$ROOST_PANELOCK_HELD" = 1 ] && [ -n "$ROOST_PANELOCK" ]; then
    rm -rf "$ROOST_PANELOCK" 2>/dev/null || true
    ROOST_PANELOCK_HELD=0
  fi
  return 0
}
