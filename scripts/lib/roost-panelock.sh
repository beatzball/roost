# roost-panelock.sh — one writer per pane input box at a time (#175).
#
# A pane's input box is a single shared line, and two commands that type into
# it at once destroy each other's work: one's C-u clears the other's paste, one
# presses Enter on what the other typed, and the one whose text never landed
# still sees "the screen changed" and reports success. `send` is the first
# writer and this file is its lock; `answer` (#142), which types a key into a
# blocked pane and then watches the badge, is the second and should take the
# same one, so that a `send --force` and an `answer` aimed at one dialog
# cannot both land. Since #181 it does: `answer` takes the lock just before
# its key, re-checks it at the key, and holds it through its confirm wait.
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
#     is `bash .../bin/roost send …`, so its args always carry the name. A
#     `ps` that answers NOTHING is "cannot tell", and cannot-tell is never
#     gone: a machine with no ps, or one where ps fails, keeps every lock
#     whose pid is alive;
#   - there is NO PID FILE and the directory is a minute old. A holder between
#     its mkdir and its pid write takes microseconds, so a minute is a holder
#     that died in that gap. A holder STOPPED in that gap for a minute would
#     lose its lock and then write its pid into the taker's — known, and not
#     worth a rule that could never take over a lock with no pid at all.
#
# NOTHING LIVE IS EVER DELETED. Neither the lock nor the `.take` guard is
# removed in place: a stale one is RETIRED (roost_panelock__retire) — its
# pid is read ONCE, the gone-ness decided on that read, the directory moved
# with mv (rename(2): of two waiters that decided the same thing, one wins
# and the other's mv fails because the source is gone) to a private name
# that carries the pid it was seen with, and the moved directory's pid READ
# BACK. The same pid means the thing that was judged, and it is removed. A
# different pid means the mv caught a FRESH one that took its place between
# the read and the mv, and it is moved straight back. A directory with no
# pid file is judged by age, and read back by age too: a fresh holder
# between its mkdir and its pid write has an empty pid and is seconds old,
# so it is moved back, not removed. Reading the pid once matters: the first
# version read it for the decision and again for the name, and a guard
# replaced between the two reads was deleted with a matching read-back
# (found by review, reproduced).
#
# What that leaves is the gap between the mv away and the mv back — two
# syscalls, no sleep — in which the fresh one's owner can read its pid file
# and find nothing (roost_panelock_check says 1, and that sender stops with
# nothing submitted: one spurious exit 1, which is the safe side), or in
# which a third process can mkdir the name first. mv(1) onto a name that
# exists and is a directory does not fail, it moves the copy INSIDE it
# (flock review, reproduced: `mv lock.gone lock` with `lock` present gives
# `lock/lock.gone/pid`), so the mv back is tried only while the name is
# free, and a copy that was nested anyway is removed from inside the new
# holder's directory. The fresh one's owner then reads the third process's
# pid at its next check and stops, and the third process is the one
# holder. Two writers never follow from either. The
# `.take` guard carries its taker's pid too, and is an orphan by the same
# three clauses, never by age alone; an orphan is a taker killed between
# its mkdir and its rmdir, and it has to go or no lock on that pane could
# ever be taken over again.
#
# roost_panelock_check is the net under all of it: every holder re-reads its
# pid file before each key it could not take back. A stolen lock is one loud
# exit 1 with nothing submitted, never two senders typing into one box. The
# gap it cannot cover is the one tmux call between the check and the key.
#
# A stale lock that cannot be removed (a permission, a file system in
# trouble) does not spin: every pass of the loop pays one tick toward the
# bound, takeover or not.
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
#       3: the directory could not be made (and does not exist), or was made
#          but could not keep its pid file and was removed again, pid file
#          and all: a lock with no pid would read as stale a minute later and
#          be taken from under a live holder. The caller must not type: a
#          send with no lock is the bug this file exists for.
#   roost_panelock_check
#       0 when this process holds no lock, or still holds the one it took:
#       the pid file reads this process's pid. 1 when the lock was taken
#       from under it — by a takeover that misjudged, or a human's rm. A
#       holder calls this before every keystroke it could not take back, and
#       stops when it says 1: a lost lock means another writer, and one loud
#       failure beats two writers typing over each other.
#   roost_panelock_drop
#       Removes the lock this process holds, if any. Always 0.
#   roost_panelock_timeout RAW
#       Prints the seconds a writer waits for the lock, from the raw value of
#       `@roost-send-lock-timeout`: 60 when unset or not digits, leading zeros
#       stripped, clamped to 600. One place for both verbs, so `send` and
#       `answer` cannot read the same knob two ways.
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

# roost_panelock__pid DIR -> the pid file's content, or nothing.
roost_panelock__pid() {
  cat "$1/pid" 2>/dev/null || true
}

# roost_panelock__gone PID DIR -> 0 when the holder of DIR, whose pid file
# read PID (once, by the caller), is gone. DIR is only looked at when PID is
# empty, for its age.
roost_panelock__gone() {
  local pid="$1" dir="$2" args
  case "$pid" in
    ''|*[!0-9]*) [ -n "$(find "$dir" -maxdepth 0 -mmin +1 2>/dev/null)" ] ;;
    *)
      kill -0 "$pid" 2>/dev/null || return 0
      args="$(ps -o args= -p "$pid" 2>/dev/null || true)"
      [ -n "$args" ] || return 1
      case "$args" in *roost*) return 1 ;; esac
      return 0 ;;
  esac
}

# 0 when the holder of the lock (or guard) at $1 is gone. A gate only: the
# decision that leads to a removal is made inside roost_panelock__retire, on
# a pid read once.
roost_panelock__stale() {
  roost_panelock__gone "$(roost_panelock__pid "$1")" "$1"
}

# roost_panelock__retire DIR SEEN — remove DIR, but only if it is still the
# directory whose pid file read SEEN: mv it aside, read the pid back, and
# remove on a match; on a mismatch mv it straight back (or, if its name was
# taken meanwhile, remove the moved copy — its owner's next check says 1).
# An empty SEEN is matched by age as well as by emptiness, so that a fresh
# holder between its mkdir and its pid write is never the match. 0 when the
# directory was removed.
roost_panelock__retire() {
  local dir="$1" seen="$2" moved
  moved="$dir.gone.${seen:-none}.$$"
  mv "$dir" "$moved" 2>/dev/null || return 1
  if [ "$(roost_panelock__pid "$moved")" = "$seen" ] && { [ -n "$seen" ] || [ -n "$(find "$moved" -maxdepth 0 -mmin +1 2>/dev/null)" ]; }; then
    rm -rf "$moved" 2>/dev/null || true
    return 0
  fi
  if [ ! -e "$dir" ] && mv "$moved" "$dir" 2>/dev/null; then
    # A name that appeared between the test and the mv makes mv nest the
    # copy inside it; that copy is removed from in there, and the moved
    # directory, if it is still outside, with it.
    rm -rf "$dir/${moved##*/}" 2>/dev/null || true
  else
    rm -rf "$moved" 2>/dev/null || true
  fi
  return 1
}

# 0 held, 1 someone else has it, 3 could not be made or could not keep its
# pid. "Someone else has it" is ONLY a name that exists: a mkdir that fails
# with nothing there (a socket directory that cannot be written) used to
# read as held, wait the whole bound, and then name a send that did not
# exist (flock review).
roost_panelock__mkdir() {
  if ! mkdir "$1" 2>/dev/null; then
    [ -e "$1" ] && return 1
    return 3
  fi
  if ! printf '%s\n' "$$" > "$1/pid" 2>/dev/null; then
    # A directory that is GONE was retired from under this process between
    # its mkdir and its write (the age read-back makes that rare, not
    # impossible): that is losing the race, not a broken file system, and
    # the caller tries again. Only a directory that is still there and will
    # not take a file is 3.
    [ -d "$1" ] || return 1
    rm -rf "$1" 2>/dev/null || true
    return 3
  fi
  return 0
}

# One takeover attempt on the stale lock at $1, under the `.take` guard.
# Each pid is read ONCE and that read is what the retirement is judged and
# verified against.
roost_panelock__takeover() {
  local lock="$1" guard="$1.take" seen
  if [ -d "$guard" ]; then
    seen="$(roost_panelock__pid "$guard")"
    if roost_panelock__gone "$seen" "$guard"; then
      roost_panelock__retire "$guard" "$seen" || true
    fi
  fi
  mkdir "$guard" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$guard/pid" 2>/dev/null || true
  if [ -d "$lock" ]; then
    seen="$(roost_panelock__pid "$lock")"
    if roost_panelock__gone "$seen" "$lock"; then
      roost_panelock__retire "$lock" "$seen" || true
    fi
  fi
  rm -rf "$guard" 2>/dev/null || true
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
    case "$rc" in
      0) ROOST_PANELOCK="$lock"; ROOST_PANELOCK_HELD=1; return 0 ;;
      3) return 3 ;;
    esac
    if roost_panelock__stale "$lock" && roost_panelock__takeover "$lock"; then
      # The attempt a takeover earns, so that TIMEOUT 0 can still take over
      # a dead holder's lock. Every pass still pays its tick below.
      rc=0; roost_panelock__mkdir "$lock" || rc=$?
      case "$rc" in
        0) ROOST_PANELOCK="$lock"; ROOST_PANELOCK_HELD=1; return 0 ;;
        3) return 3 ;;
      esac
    fi
    [ "$ticks" -lt $((timeout * 10)) ] || return 1
    sleep 0.1 2>/dev/null || sleep 1
    ticks=$((ticks + 1))
  done
}

# Clamped by LENGTH first — an O(1) test, so this bound can never itself be
# slow, and it caps the work the strip loop could ever be asked to do. Leading
# zeros are stripped the way bin/roost strips its other knobs and for the same
# measured reason: `08` is octal to `$(( ))` and aborts it under set -e, and a
# message should say "8s", not "08s". Stripped BEFORE the value clamp, or
# `0000000` would read as "over the cap" and a configured no-wait would wait
# ten minutes (found by review, tests/test-send-lock.sh pins both).
roost_panelock_timeout() {
  local v="$1"
  case "$v" in ''|*[!0-9]*) v=60 ;; esac
  [ "${#v}" -gt 40 ] && v=600
  while [ "${#v}" -gt 1 ] && [ "${v%${v#?}}" = 0 ]; do
    v="${v#0}"
  done
  case "$v" in ????*) v=600 ;; esac
  [ "$v" -gt 600 ] 2>/dev/null && v=600 || true
  printf '%s\n' "$v"
}

roost_panelock_check() {
  [ "$ROOST_PANELOCK_HELD" = 1 ] || return 0
  [ "$(roost_panelock__pid "$ROOST_PANELOCK")" = "$$" ]
}

roost_panelock_drop() {
  if [ "$ROOST_PANELOCK_HELD" = 1 ] && [ -n "$ROOST_PANELOCK" ]; then
    # Only a lock that is still THIS process's: a lock that was taken over
    # and is now another sender's is theirs to drop.
    if [ "$(roost_panelock__pid "$ROOST_PANELOCK")" = "$$" ]; then
      rm -rf "$ROOST_PANELOCK" 2>/dev/null || true
    fi
    ROOST_PANELOCK_HELD=0
  fi
  return 0
}
