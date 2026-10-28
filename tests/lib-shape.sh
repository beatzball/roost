# tests/lib-shape.sh — the shared setup for the persistent-sessions tests
# (#191: `roost save`, `restore`, `revive`, the saver). Sourced AFTER
# tests/lib.sh. Later parts ADD to this file; they never copy it, so every
# shape test runs on one sandbox and one set of stub harnesses.
#
#   . "$(dirname "$0")/lib.sh"
#   . "$(dirname "$0")/lib-shape.sh"
#   shape_test_setup; trap shape_test_teardown EXIT
#   ...
#   canary_check          # last, so it sees every case above it
#
# WHY A NAMED SERVER. A shape is keyed by the server's socket NAME (`-L NAME`,
# docs/airig/specs/2026-10-24-persistent-sessions-design.md §3.1), because the
# name is what survives a reboot and the socket path is not. A `-S PATH`
# server is keyed by a checksum of its path instead. Testing only path servers
# would leave the key every real user gets — `roost` — unexercised, the same
# reason tests/test-ext.sh drives a `-L` socket.
#
# WHY THE NAME IS `roost`. The plan named it `shp<pid>`, but roost's hooks and
# `roost identify` act only on a server whose socket path ENDS IN /roost
# (scripts/lib/roost-socket.sh, roost_self_socket: what makes a global hook
# safe). On `shp<pid>` the stub's identify was a silent no-op, measured. So the
# name is `roost`, exactly as tests/test-session-context.sh does it, and that
# is safe only because of the TMUX_TMPDIR guard of AGENTS.md §2, which runs
# before the first `-L`: the socket is $TMUX_TMPDIR/tmux-<uid>/roost, a
# throwaway directory of this file's own, never the live one. Everything here
# after the start drives the server by its full socket PATH ($SHAPE_SOCK, read
# back from tmux), and teardown kills it by that path too — so not even a lost
# TMUX_TMPDIR could turn a kill in this file into `tmux -L roost kill-server`
# against the author's real agents. bin/roost itself is run with
# ROOST_SOCKET=roost, so it takes the `-L` path a real user's roost takes.
#
# WHAT IS REDIRECTED, AND WHY EACH. A save lists every project directory and
# every session id, and later parts launch harnesses, so nothing here may reach
# a real home:
#   HOME                  a temp home whose .bash_profile and .bashrc append
#                         "$TMUX_PANE $$" to $HOME/shells.log, so a test can
#                         count the shells restore started in a pane
#                         (shells_for)
#   XDG_STATE_HOME        a temp dir: the default shape root lives under it
#   ROOST_SHAPE_DIR       $SHAPE_TMP/shapes. tests/lib.sh sets it EMPTY for the
#                         whole suite (no test saves a shape by accident); a
#                         shape test turns saving back on here, after sourcing
#                         it, the way tests/test-reply-record.sh does for
#                         ROOST_RECORD_DIR
#   CLAUDE_CONFIG_DIR     a temp dir: stub_store_add writes Claude's project
#                         store under it
#   XDG_CONFIG_HOME, XDG_DATA_HOME, CLAUDE_SETTINGS, CODEX_HOME, COPILOT_HOME,
#   PI_CODING_AGENT_DIR   the CANARY: a directory nothing in a shape test may
#                         write to. These are the homes `roost install` and
#                         the adapters write into (scripts/lib/roost-adapters.sh,
#                         AGENTS.md §8), and none of them is a shape test's
#                         business — so instead of a temp dir each, which
#                         would hide a stray write, they point at the canary
#                         and canary_check fails the file if anything landed
#                         there. The shape of tests/test-install.sh's guard.
#   ZDOTDIR               unset, so no zsh dotfile directory is inherited
#   ROOST_RECORD_DIR      left as tests/lib.sh set it: empty, record nothing
shape_test_setup() {
  SHAPE_TMP="$(mktemp -d)"
  SHAPE_TMP="$(cd -P "$SHAPE_TMP" && pwd)"
  # Short, under /tmp: a -L socket is $TMUX_TMPDIR/tmux-<uid>/<name>, and the
  # ~104-char unix socket limit corrupts a long one silently (tests/lib.sh).
  TMUX_TMPDIR="$(mktemp -d /tmp/amx.XXXX)"
  export TMUX_TMPDIR
  roost_test_tmux_named_guard

  CANARY="$SHAPE_TMP/canary"
  export XDG_CONFIG_HOME="$CANARY/xdg-config"
  export XDG_DATA_HOME="$CANARY/xdg-data"
  export CLAUDE_SETTINGS="$CANARY/claude/settings.json"
  export CODEX_HOME="$CANARY/codex"
  export COPILOT_HOME="$CANARY/copilot"
  export PI_CODING_AGENT_DIR="$CANARY/pi/agent"
  unset ZDOTDIR

  export HOME="$SHAPE_TMP/home"
  export XDG_STATE_HOME="$SHAPE_TMP/state"
  export CLAUDE_CONFIG_DIR="$SHAPE_TMP/claude-config"
  export ROOST_SHAPE_DIR="$SHAPE_TMP/shapes"
  mkdir -p "$HOME" "$XDG_STATE_HOME" "$CLAUDE_CONFIG_DIR"
  # Both rc files, because which one bash reads depends on whether the shell
  # is a login shell, and a test must not care which kind restore started.
  # Single quotes: the pane's own $TMUX_PANE and $$, at the moment it starts.
  printf '%s\n' 'printf "%s %s\n" "$TMUX_PANE" "$$" >> "$HOME/shells.log"' \
    > "$HOME/.bash_profile"
  cp "$HOME/.bash_profile" "$HOME/.bashrc"

  # The harness stubs (spec §8.1's opening). Built before the server starts, so
  # the server's global environment — which every pane inherits — already has
  # the stub directory first on PATH.
  STUB_BIN="$SHAPE_TMP/stub-bin"
  STUB_WRAP="$SHAPE_TMP/stub-wrap"
  export STUB_LOG="$SHAPE_TMP/stub.log"
  export STUB_BIN
  stub_build_bin "$STUB_BIN"
  stub_write_wrappers "$STUB_WRAP"
  export PATH="$STUB_WRAP:$PATH"

  export ROOST_SOCKET="roost"
  tmux -L "$ROOST_SOCKET" -f /dev/null new-session -d -s shp -x 200 -y 50 \
    'ENV= exec /bin/sh'
  SHAPE_SOCK="$(tmux -L "$ROOST_SOCKET" display -p '#{socket_path}')"
  case "$SHAPE_SOCK" in
    */amx.*/tmux-*/roost) ;;
    *) printf '  FAIL: the test server socket is [%s], not under this file'"'"'s TMUX_TMPDIR\n' "$SHAPE_SOCK"
       exit 1 ;;
  esac
  export SHAPE_SOCK

  # The stubs are only worth anything if roost classifies them as the harness
  # they stand for. roost_shape_agree reads #{pane_current_command}, so a stub
  # whose foreground process is named `sleep` would be `other` and every
  # agreement case would test the wrong branch while staying green. Check it
  # once, here, before any case runs, and stop the file if it does not hold.
  local h p got i
  for h in claude codex; do
    p="$(TL new-window -d -P -F '#{pane_id}' -t shp: "$STUB_WRAP/$h")"
    got=""; i=0
    while [ "$i" -lt 30 ]; do
      got="$(TL display -p -t "$p" '#{pane_current_command}')"
      [ "$got" = "$h" ] && break
      sleep 0.1; i=$((i+1))
    done
    if [ "$got" != "$h" ]; then
      printf '  FAIL: the %s stub reads #{pane_current_command} [%s], not [%s] — every agreement case would test the wrong branch\n' \
        "$h" "$got" "$h"
      exit 1
    fi
    TL kill-pane -t "$p"
  done
}

# Kills ONLY this file's server, by its full socket path under this file's
# TMUX_TMPDIR (read back from tmux at setup). Never by name, never bare.
shape_test_teardown() {
  [ -n "${SHAPE_SOCK:-}" ] && tmux -S "$SHAPE_SOCK" kill-server 2>/dev/null
  [ -n "${TMUX_TMPDIR:-}" ] && rm -rf "$TMUX_TMPDIR"
  [ -n "${SHAPE_TMP:-}" ] && rm -rf "$SHAPE_TMP"
}

# The test's tmux, on this file's server, by its full path (see the header).
# T (tests/lib.sh) is the roost_test_server one.
TL() { tmux -S "$SHAPE_SOCK" "$@"; }

# shells_for %N — the shells.log lines of one pane: one line per shell that
# started in it and read an rc file.
shells_for() { grep "^$1 " "$HOME/shells.log" 2>/dev/null || true; }

# What escaped into the canary, if anything; the whole listing, because the
# path that leaked names the variable that was missed.
canary_leaks() { find "$CANARY" -mindepth 1 2>/dev/null | sort; }

# The detector is checked before it is trusted, as in tests/test-install.sh:
# "found nothing" is also what a detector aimed at the wrong path says.
canary_check() {
  mkdir -p "$CANARY"; : > "$CANARY/detector-check"
  assert_contains "$(canary_leaks)" "detector-check" \
    "the sandbox canary reports a file when there is one"
  rm -f "$CANARY/detector-check"
  assert_eq "$(canary_leaks)" "" "nothing was written to a real-home stand-in (the canary)"
}

# stub_build_bin DIR — a real executable FILE named `claude`, and a copy named
# `codex`, that sleeps (600 s, or argv[1]).
#
# The NAME is the point. roost classifies a pane by #{pane_current_command},
# which tmux reads from the foreground process's own name, so the stub must
# BE a process called `claude`. Measured for the plan (2026-10-26, once each):
# a file named `claude` reads `claude` and one named `codex` reads `codex`, on
# macOS (tmux 3.6) and in ubuntu:24.04 (tmux 3.4); a shell wrapper that execs
# the file reads the same. A script would read as its interpreter, and a stub
# ending in `exec sleep 600` reads `sleep`.
#
# On macOS a copy of a system binary (`cp /bin/sleep`) is killed at exec
# (status 137, also after an ad-hoc codesign), so there it is compiled. No `cc`
# on a Mac stops the file: a silent skip would leave every agreement case
# untested and green.
stub_build_bin() {
  local d="$1"
  mkdir -p "$d"
  if [ "$(uname -s)" = Darwin ]; then
    if ! command -v cc >/dev/null 2>&1; then
      printf '  FAIL: needs cc for the harness stub (a copy of /bin/sleep is killed at exec on macOS)\n'
      exit 1
    fi
    printf '%s\n' '#include <stdlib.h>' '#include <unistd.h>' \
      'int main(int c, char **v) { sleep(c > 1 ? atoi(v[1]) : 600); return 0; }' \
      > "$d/stub.c"
    cc -o "$d/claude" "$d/stub.c" || { printf '  FAIL: cc could not build the harness stub\n'; exit 1; }
  else
    cp "$(command -v sleep)" "$d/claude"
  fi
  cp "$d/claude" "$d/codex"
}

# stub_write_wrappers DIR — the `claude` and `codex` a pane finds on PATH.
#
# Each appends "<epoch> <cwd> <argv>" to $STUB_LOG, so a test can see exactly
# what roost launched and where. It reports an identity only when asked —
# STUB_IDENTIFY=1 reports the id it was resumed with, STUB_IDENTIFY_AS=<id>
# reports that id instead (a harness that came back under a different id) —
# because a real harness identifies at its session start and a test of the
# "never identified" path needs one that does not. Then it execs the compiled
# stub, so the pane's foreground process is named after the harness.
#
# STUB_IDENTIFY and STUB_IDENTIFY_AS are read from the PANE's environment: set
# them with `new-window -e` / `respawn-pane -e` or `set-environment -g` on the
# test server, not in the test's shell after the server started.
#
# claude-exit1 exits 1 at once (a harness that failed to start);
# claude-exit0 exits 0 at once without identifying (a person who quit). A test
# that needs one installs it as `claude` in its own PATH directory.
stub_write_wrappers() {
  local d="$1" roost
  roost="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/roost"
  mkdir -p "$d"
  # claude: --resume <id>. codex: `codex resume <id>`.
  cat > "$d/claude" <<EOF
#!/bin/sh
printf '%s %s %s\n' "\$(date +%s)" "\$PWD" "claude \$*" >> "\$STUB_LOG"
id=""
while [ \$# -gt 0 ]; do
  case "\$1" in --resume) id="\${2:-}"; shift ;; esac
  shift
done
if [ -n "\${STUB_IDENTIFY_AS:-}" ]; then
  "$roost" identify --session "\$STUB_IDENTIFY_AS" --cwd "\$PWD" --harness claude
elif [ "\${STUB_IDENTIFY:-}" = 1 ] && [ -n "\$id" ]; then
  "$roost" identify --session "\$id" --cwd "\$PWD" --harness claude
fi
exec "\$STUB_BIN/claude" 600
EOF
  cat > "$d/codex" <<EOF
#!/bin/sh
printf '%s %s %s\n' "\$(date +%s)" "\$PWD" "codex \$*" >> "\$STUB_LOG"
id=""
[ "\${1:-}" = resume ] && id="\${2:-}"
if [ -n "\${STUB_IDENTIFY_AS:-}" ]; then
  "$roost" identify --session "\$STUB_IDENTIFY_AS" --cwd "\$PWD" --harness codex
elif [ "\${STUB_IDENTIFY:-}" = 1 ] && [ -n "\$id" ]; then
  "$roost" identify --session "\$id" --cwd "\$PWD" --harness codex
fi
exec "\$STUB_BIN/codex" 600
EOF
  cat > "$d/claude-exit1" <<'EOF'
#!/bin/sh
printf '%s %s %s\n' "$(date +%s)" "$PWD" "claude $*" >> "$STUB_LOG"
exit 1
EOF
  cat > "$d/claude-exit0" <<'EOF'
#!/bin/sh
printf '%s %s %s\n' "$(date +%s)" "$PWD" "claude $*" >> "$STUB_LOG"
exit 0
EOF
  chmod +x "$d/claude" "$d/codex" "$d/claude-exit1" "$d/claude-exit0"
}

# stub_store_add ID CWD — a conversation in the stub Claude store:
# $CLAUDE_CONFIG_DIR/projects/<folder>/<ID>.jsonl holding one "cwd" line.
# The folder is CWD with every `/` and `.` written as `-` (the measured rule,
# spec §2.1: the project folder's name is not "`/` as `-`" alone).
stub_store_add() {
  local id="$1" cwd="$2" folder
  folder="$(printf '%s' "$cwd" | tr '/.' '--')"
  mkdir -p "$CLAUDE_CONFIG_DIR/projects/$folder"
  printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$cwd" "$id" \
    > "$CLAUDE_CONFIG_DIR/projects/$folder/$id.jsonl"
}
