# tests/lib.sh — minimal bash test harness. No framework.
# Sourced by tests/test-*.sh. Requires: tmux, mktemp.
: "${AMUX_TESTS_PASS:=0}"
: "${AMUX_TESTS_FAIL:=0}"

amux_test_server() {
  # Short socket dir — the ~104-char unix socket limit silently corrupts long paths.
  AMUX_TEST_SOCKDIR="$(mktemp -d /tmp/amx.XXXX)"
  AMUX_TEST_SOCK="$AMUX_TEST_SOCKDIR/s"
  export AMUX_TEST_SOCK
  # Start the initial pane on a bare shell, NOT the developer's login shell.
  # A login shell sources rc files inside the pane, and every external helper
  # they run becomes #{pane_current_command} for a few milliseconds (observed:
  # stty, grep, awk, ls, mkdir, diff, printf; the tail reached 0.43s on an idle
  # machine, and tests/test-switcher.sh finishes at ~0.9s). That churn flaked
  # the switcher test 3 times in 400 runs. It also makes the reported command
  # depend on whose machine is running, so a local pass proves little about CI.
  # `ENV=` stops /bin/sh sourcing a startup file of its own.
  tmux -S "$AMUX_TEST_SOCK" -f /dev/null new-session -d -x 200 -y 50 \
    'ENV= exec /bin/sh'
  # Callers read the exported $AMUX_TEST_SOCK; nothing consumes stdout. Emitting
  # the path here would just be noise in every test file's output.
}

amux_test_teardown() {
  [ -n "${AMUX_TEST_SOCK:-}" ] && tmux -S "$AMUX_TEST_SOCK" kill-server 2>/dev/null
  [ -n "${AMUX_TEST_SOCKDIR:-}" ] && rm -rf "$AMUX_TEST_SOCKDIR"
}

T() { tmux -S "$AMUX_TEST_SOCK" "$@"; }

assert_eq() {
  if [ "$1" = "$2" ]; then
    AMUX_TESTS_PASS=$((AMUX_TESTS_PASS+1)); printf '  PASS: %s\n' "$3"
  else
    AMUX_TESTS_FAIL=$((AMUX_TESTS_FAIL+1)); printf '  FAIL: %s\n       want [%s] got [%s]\n' "$3" "$2" "$1"
  fi
}

assert_contains() {
  case "$1" in
    *"$2"*) AMUX_TESTS_PASS=$((AMUX_TESTS_PASS+1)); printf '  PASS: %s\n' "$3" ;;
    *)      AMUX_TESTS_FAIL=$((AMUX_TESTS_FAIL+1)); printf '  FAIL: %s\n       [%s] does not contain [%s]\n' "$3" "$1" "$2" ;;
  esac
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
