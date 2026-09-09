# tests/lib.sh — minimal bash test harness. No framework.
# Sourced by tests/test-*.sh. Requires: tmux, mktemp.
: "${ROOST_TESTS_PASS:=0}"
: "${ROOST_TESTS_FAIL:=0}"

roost_test_server() {
  # Short socket dir — the ~104-char unix socket limit silently corrupts long paths.
  ROOST_TEST_SOCKDIR="$(mktemp -d /tmp/amx.XXXX)"
  ROOST_TEST_SOCK="$ROOST_TEST_SOCKDIR/s"
  export ROOST_TEST_SOCK
  # Start the initial pane on a bare shell, NOT the developer's login shell.
  # A login shell sources rc files inside the pane, and every external helper
  # they run becomes #{pane_current_command} for a few milliseconds (observed:
  # stty, grep, awk, ls, mkdir, diff, printf; the tail reached 0.43s on an idle
  # machine, and tests/test-switcher.sh finishes at ~0.9s). That churn flaked
  # the switcher test 3 times in 400 runs. `ENV=` stops /bin/sh sourcing a
  # startup file of its own.
  #
  # This makes the value STABLE, not portable: it no longer changes under a
  # pane that is sitting still, but WHAT it reads is still platform-dependent —
  # macOS /bin/sh is bash in sh-mode and reports "bash", where Linux reports
  # "sh" or "dash". So never assert a literal #{pane_current_command} for a
  # pane running the test shell; it would pass on one OS and fail on the other.
  # A test that needs a known command must pin the pane to one, the way
  # tests/test-switcher.sh pins `exec sleep 600` and asserts "sleep" — that
  # name IS the same everywhere.
  tmux -S "$ROOST_TEST_SOCK" -f /dev/null new-session -d -x 200 -y 50 \
    'ENV= exec /bin/sh'
  # Callers read the exported $ROOST_TEST_SOCK; nothing consumes stdout. Emitting
  # the path here would just be noise in every test file's output.
}

roost_test_teardown() {
  [ -n "${ROOST_TEST_SOCK:-}" ] && tmux -S "$ROOST_TEST_SOCK" kill-server 2>/dev/null
  [ -n "${ROOST_TEST_SOCKDIR:-}" ] && rm -rf "$ROOST_TEST_SOCKDIR"
}

T() { tmux -S "$ROOST_TEST_SOCK" "$@"; }

roost_test_tmux_named_guard() {
  # Call this ONCE, before the first `tmux -L NAME` in a test file. It REFUSES
  # rather than warns: it exits 1, which makes tests/run.sh report the file as
  # died-mid-run and fails the whole suite.
  #
  # Most files here address a socket PATH under mktemp -d and never need this.
  # Three do need a NAME -- test-session-context.sh and test-reply-socket.sh
  # because the bug they pin is roost falling through to the production `-L
  # roost` server, and test-ext.sh because tmux takes -L for a NAME and -S for
  # a PATH, so an extension that hardcoded -S would be green against every
  # path-addressed server in the suite and wrong for every real user.
  #
  # A `-L NAME` socket lands in $TMUX_TMPDIR/tmux-<uid>/<name>, and with
  # TMUX_TMPDIR unset that is /tmp/tmux-<uid>/ -- the directory holding the
  # author's LIVE agents (AGENTS.md §2). Every one of those three files sets
  # TMUX_TMPDIR to a throwaway directory first. This function is what stops
  # that from being a thing an author has to remember: drop the export in a
  # future edit, or copy one of those blocks into a fourth file without it,
  # and the run stops here instead of writing next to real work.
  #
  # Three ways it can be wrong, and all three are refused:
  #
  #   unset      - the default, and the dangerous one
  #   missing    - MEASURED, not assumed: tmux silently falls back to the real
  #                directory when TMUX_TMPDIR names a directory that does not
  #                exist, so "set" is not enough on its own
  #   /tmp       - set, existing, and still resolving `-L NAME` to the REAL
  #                /tmp/tmux-<uid>/. Any bare temp ROOT is refused for this
  #                reason; only a subdirectory under one is accepted
  #
  # The path is resolved with `cd -P` before it is judged, because macOS
  # /tmp is a symlink to /private/tmp and a literal match would accept one
  # spelling and refuse the other.
  local d real
  d="${TMUX_TMPDIR-}"
  if [ -z "$d" ]; then
    printf '  FAIL: TMUX_TMPDIR is unset before a `tmux -L NAME` — that socket would land in the REAL /tmp/tmux-%s/, beside live agents
' "$(id -u)" >&2
    printf '        set it to a throwaway directory first: tmpdir="$(mktemp -d /tmp/amx.XXXX)"; export TMUX_TMPDIR="$tmpdir"
' >&2
    exit 1
  fi
  if [ ! -d "$d" ]; then
    printf '  FAIL: TMUX_TMPDIR=%s does not exist — tmux falls back to the REAL /tmp/tmux-%s/ when it names a missing directory
' "$d" "$(id -u)" >&2
    exit 1
  fi
  real="$(cd -P "$d" 2>/dev/null && pwd)"
  case "$real" in
    # A subdirectory UNDER a temp root, never a temp root itself.
    /tmp/?*|/private/tmp/?*|/var/tmp/?*|/private/var/tmp/?*|/var/folders/?*|/private/var/folders/?*) ;;
    *)
      printf '  FAIL: TMUX_TMPDIR=%s (resolved: %s) is not a throwaway directory under a temp root — refusing to run `tmux -L NAME`
' "$d" "$real" >&2
      printf '        if this is a legitimate temp root on a platform this list does not cover, add it HERE rather than skipping the guard
' >&2
      exit 1 ;;
  esac
}

assert_eq() {
  if [ "$1" = "$2" ]; then
    ROOST_TESTS_PASS=$((ROOST_TESTS_PASS+1)); printf '  PASS: %s\n' "$3"
  else
    ROOST_TESTS_FAIL=$((ROOST_TESTS_FAIL+1)); printf '  FAIL: %s\n       want [%s] got [%s]\n' "$3" "$2" "$1"
  fi
}

assert_contains() {
  case "$1" in
    *"$2"*) ROOST_TESTS_PASS=$((ROOST_TESTS_PASS+1)); printf '  PASS: %s\n' "$3" ;;
    *)      ROOST_TESTS_FAIL=$((ROOST_TESTS_FAIL+1)); printf '  FAIL: %s\n       [%s] does not contain [%s]\n' "$3" "$1" "$2" ;;
  esac
}

assert_prefix() {
  # assert_prefix <string> <expected-prefix> <label>
  # Written as a helper rather than inline, because the obvious inline form is
  # a `case "$out" in E*) assert_eq ok ok ...` — which compares "ok" to "ok" on
  # the pass path, so the PASS line it prints is not evidence of the thing it
  # names. Here the comparison IS the assertion, and the FAIL line can print
  # the string that actually arrived.
  case "$1" in
    "$2"*) ROOST_TESTS_PASS=$((ROOST_TESTS_PASS+1)); printf '  PASS: %s\n' "$3" ;;
    *)     ROOST_TESTS_FAIL=$((ROOST_TESTS_FAIL+1)); printf '  FAIL: %s\n       [%s] does not start with [%s]\n' "$3" "$1" "$2" ;;
  esac
}

assert_true() {
  # assert_true <exit-status> <label>
  # For a boolean condition that has no two values worth naming (an
  # `assert_eq ok ok` reads as passing no matter what the condition was —
  # tests/lib.sh already rejects that shape in assert_prefix's own comment).
  # Pass the status of the actual test command, evaluated immediately
  # before the call: `[ -z "$x" ]; assert_true $? "x is empty"`.
  if [ "$1" -eq 0 ] 2>/dev/null; then
    ROOST_TESTS_PASS=$((ROOST_TESTS_PASS+1)); printf '  PASS: %s\n' "$2"
  else
    ROOST_TESTS_FAIL=$((ROOST_TESTS_FAIL+1)); printf '  FAIL: %s\n       exit status was [%s], wanted 0\n' "$2" "$1"
  fi
}

assert_file_absent() {
  # assert_file_absent <path> <label> -- <path> may be an unquoted glob; a
  # pattern that matches nothing stays literal and -e on it correctly reads
  # false, which is exactly the "no backup file exists" case callers use
  # this for.
  if [ ! -e "$1" ]; then
    ROOST_TESTS_PASS=$((ROOST_TESTS_PASS+1)); printf '  PASS: %s\n' "$2"
  else
    ROOST_TESTS_FAIL=$((ROOST_TESTS_FAIL+1)); printf '  FAIL: %s\n       [%s] exists\n' "$2" "$1"
  fi
}

require_pane() {
  # require_pane <pane-id> <label>
  # A split-window (or new-window) that runs out of room prints an EMPTY pane
  # id on stdout rather than failing visibly, and every `-t ""` that follows
  # silently resolves to the ACTIVE pane instead of erroring. An assertion
  # aimed at the pane that was never created then reads some other pane's
  # state and can pass for the wrong reason — masking that has already been
  # found twice in this suite. So check the id at the point of the split
  # instead of drifting into that trap: exiting non-zero makes tests/run.sh
  # name the file as died-mid-run, which no PASS/FAIL count would have shown.
  [ -n "$1" ] || { printf '  FAIL: split for %s produced no pane id\n' "$2"; exit 1; }
}

with_path_shim() {
  # with_path_shim <name> <marker> -- <cmd...>
  local name="$1" marker="$2"; shift 3   # drop name, marker, and the "--"
  local dir; dir="$(mktemp -d /tmp/amx.XXXX)"
  cat > "$dir/$name" <<EOF
#!/bin/sh
printf '%s\n' "$name" >> "$marker"
EOF
  chmod +x "$dir/$name"
  PATH="$dir:$PATH" "$@"
  rm -rf "$dir"
}
