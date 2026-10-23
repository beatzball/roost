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
# two waiters that both saw the dead holder cannot both replace it. A pid
# another user owns reads as gone here (kill -0 fails with EPERM); sends are
# per user, so that is not a case worth a worse rule. A lock with no pid file
# at all is a holder between its mkdir and its write, which takes
# microseconds, so that shape is only stale once it is a minute old — and a
# `.take` a minute old is a taker that was itself killed mid-takeover, and is
# removed, or it would block every takeover for good.
#
# Sourced, not executed, `roost_panelock_*` prefix. NO TMUX CALL: the caller
# passes the socket path and pane id it has already read, so this file needs
# nothing but mkdir, rmdir, find, kill and cat, and a test can drive it with
# no server at all. find's -maxdepth and -mmin exist in BSD, GNU and busybox
# find.
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
#   roost_panelock_drop
#       Removes the lock this process holds, if any. Always 0.
#
# The polls are a tenth of a second (`sleep 1` where sleep cannot do fractions),
# so TIMEOUT 0 means one attempt and no wait.
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
    *) ! kill -0 "$pid" 2>/dev/null ;;
  esac
}

roost_panelock__mkdir() {
  mkdir "$1" 2>/dev/null || return 1
  ROOST_PANELOCK="$1"
  ROOST_PANELOCK_HELD=1
  printf '%s\n' "$$" > "$1/pid" 2>/dev/null || true
  return 0
}

roost_panelock_take() {
  local lock timeout ticks=0
  lock="$(roost_panelock_path "$1" "$2")"
  [ -n "$lock" ] || return 2
  case "$3" in ''|*[!0-9]*) timeout=0 ;; *) timeout="$3" ;; esac
  # Every `&&` list below ends in `|| true`: bin/roost runs under `set -e`,
  # and a failing LAST command of an `&&` list is not exempt from it.
  until roost_panelock__mkdir "$lock"; do
    if roost_panelock__stale "$lock"; then
      [ -n "$(find "$lock.take" -maxdepth 0 -mmin +1 2>/dev/null)" ] && rmdir "$lock.take" 2>/dev/null || true
      if mkdir "$lock.take" 2>/dev/null; then
        roost_panelock__stale "$lock" && rm -rf "$lock" 2>/dev/null || true
        rmdir "$lock.take" 2>/dev/null || true
        continue
      fi
    fi
    [ "$ticks" -lt $((timeout * 10)) ] || return 1
    sleep 0.1 2>/dev/null || sleep 1
    ticks=$((ticks + 1))
  done
  return 0
}

roost_panelock_drop() {
  if [ "$ROOST_PANELOCK_HELD" = 1 ] && [ -n "$ROOST_PANELOCK" ]; then
    rm -rf "$ROOST_PANELOCK" 2>/dev/null || true
    ROOST_PANELOCK_HELD=0
  fi
  return 0
}
