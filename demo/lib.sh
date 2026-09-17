# Shared by every demo recording. Source it; do not run it.
#
#   . "$(dirname "$0")/lib.sh"
#
# Everything a recording touches lives under /tmp, so no username or home path
# can reach a frame, and nothing a recording does can reach the roost you are
# working in. Three separate things have to be redirected for that to be true,
# and each has bitten once:
#
#   - the SERVER. A recording on the real roost server shows your real session
#     names, and its status counts roll up across every session. So: a
#     throwaway server on its own socket.
#   - the CONFIG. roost writes roost.conf (theme, glyphs) and, whenever a
#     server starts, its generated wiring under $XDG_CONFIG_HOME/roost. A demo
#     server started from a worktree without this left wiring folders in the
#     real config pointing at a checkout that was later deleted. And a settings
#     recording would change your real theme.
#   - the PATHS ON SCREEN. A command typed into a pane stays visible above
#     whatever it starts, so anything typed has to name /tmp paths only.

DEMO_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOST="$DEMO_REPO_ROOT/bin/roost"

# The socket PATH has to end in "/roost". scripts/lib/roost-socket.sh only
# recognises a server it is running inside when the path ends that way, and
# scripts/roost-agent-state -- which writes every badge -- takes its socket from
# there, ignoring $ROOST_SOCKET. On any other name every badge write exits 0
# and lands nowhere.
DEMO_SOCK=/tmp/roost-demo-sock/roost
DEMO_REPO=/tmp/roost-demo-repo
DEMO_XDG=/tmp/roost-demo-xdg
DEMO_CLAUDE_SETTINGS=/tmp/roost-demo-sock/claude-settings.json
# A zsh config dir for the panes. Without it every pane loads the author's own
# ~/.zshrc, whose history-based autosuggestions print past commands in grey
# right on camera.
DEMO_ZDOT=/tmp/roost-demo-zdot
# Wrappers that come first on PATH inside a recording, so every agent -- the
# ones typed on camera and the ones another agent starts -- gets the demo
# flags without the flags ever being typed where a frame can see them:
#   claude  --settings: blanks the status line that reports plan usage
#   codex   -c check_for_update_on_startup=false: codex has upgraded its own
#           host mid-test on this machine before
DEMO_BIN=/tmp/roost-demo-bin

# Re-run the calling script under `env -i`, keeping only what a recording
# needs. The shell a recording is started from is rarely clean: inside roost or
# inside an agent it carries TMUX, ROOST_WIRING_DIR and CLAUDE_CODE_* variables,
# and a demo agent that inherits them treats itself as part of that session.
#   demo_reexec_clean "$0" "$@"
demo_reexec_clean() {
  [ "${DEMO_CLEAN:-}" = 1 ] && return 0
  local script="$1"; shift
  local clean_path
  clean_path="$(printf '%s' "$PATH" | tr ':' '\n' \
    | grep -v -E '/roost/shims$|/\.claude/plugins/|/\.claude/worktrees/|^/tmp/roost-demo' \
    | awk '!seen[$0]++' | paste -sd: -)"
  exec env -i \
    HOME="$HOME" USER="$USER" LOGNAME="${LOGNAME:-$USER}" \
    LANG="${LANG:-en_US.UTF-8}" TERM=xterm-256color SHELL=/bin/zsh \
    PATH="$clean_path" DEMO_CLEAN=1 \
    bash "$script" "$@"
}

# Point this shell, and everything it starts, at the demo server and config.
demo_env() {
  export ROOST_SOCKET="$DEMO_SOCK"
  export XDG_CONFIG_HOME="$DEMO_XDG"
  export ZDOTDIR="$DEMO_ZDOT"
  # The demo is a caller from outside, even when this runs inside roost:
  # TMUX_PANE would make roost look for the caller's pane on the demo socket.
  unset TMUX_PANE || true
}

# tmux on the demo socket, and only ever that socket.
demo_tmux() { tmux -S "$DEMO_SOCK" "$@"; }

# A clean slate: no demo server, a fresh repo, and a roost config with the look
# the recordings are meant to show. Does not start a server.
demo_reset() {
  demo_env
  mkdir -p "$(dirname "$DEMO_SOCK")"
  # Only ever the demo socket, which demo_env just pinned.
  "$ROOST" kill >/dev/null 2>&1 || true

  rm -rf "$DEMO_REPO" "$DEMO_XDG" "$DEMO_ZDOT"
  mkdir -p "$DEMO_REPO/src" "$DEMO_XDG" "$DEMO_ZDOT"

  # The panes' shell: no history, no plugins, and the same one-glyph prompt the
  # recordings give the shell outside roost, so going in does not change it.
  cat > "$DEMO_ZDOT/.zshrc" <<'Z'
HISTFILE=/dev/null
SAVEHIST=0
PROMPT=$'%F{#7c6ff0}❯%f '
Z

  (
    cd "$DEMO_REPO"
    g() { git -c user.name=demo -c user.email=demo@example.com "$@"; }
    git init -q -b main .
    cat > src/server.js <<'A'
const http = require("http");

http.createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ ok: true }));
}).listen(3000);
A
    cat > README.md <<'A'
# demo

A throwaway repo, so the recordings have somewhere neutral to stand.
A
    g add -A
    g commit -qm "initial commit"
  )

  # The look, written by roost's own `roost init` rather than by hand, so it
  # stays whatever init writes. Answers in order: OS notifications (no -- a
  # desktop banner mid-recording would land on the author's real screen),
  # triangle separators, dark terminal, the roost theme, the nerd glyph set,
  # skip printing hooks.
  # ROOST_INIT_ANSWERS=- is init's switch for scripted stdin; without it init
  # refuses anything that is not a tty.
  if ! printf 'n\ny\ndark\nroost\nnerd\nskip\n' | ROOST_INIT_ANSWERS=- "$ROOST" init >"$DEMO_XDG/init.log" 2>&1; then
    echo "demo: roost init failed -- see $DEMO_XDG/init.log" >&2
    return 1
  fi

  # Claude's status line reports plan usage across the bottom of every frame.
  # A copy under /tmp, so the path typed to use it names nothing personal.
  cp "$DEMO_REPO_ROOT/demo/claude-demo-settings.json" "$DEMO_CLAUDE_SETTINGS"

  # The wrappers. Each execs the real binary by absolute path, found now on a
  # PATH that excludes the wrappers themselves and roost's claude shim.
  rm -rf "$DEMO_BIN"
  mkdir -p "$DEMO_BIN"
  local real
  real="$(PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -E '^/tmp/roost-demo|/roost/shims$' | paste -sd: -)" command -v claude || true)"
  if [ -n "$real" ]; then
    # --settings goes LAST. Claude honours only the last --settings it is
    # given, and roost's claude shim runs before this wrapper and passes its
    # own; put first, the demo settings were silently ignored and the usage
    # bars and the author's output style came back.
    printf '#!/bin/sh\nexec "%s" "$@" --settings %s\n' "$real" "$DEMO_CLAUDE_SETTINGS" > "$DEMO_BIN/claude"
    chmod +x "$DEMO_BIN/claude"
  fi
  real="$(PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -E '^/tmp/roost-demo' | paste -sd: -)" command -v codex || true)"
  if [ -n "$real" ]; then
    printf '#!/bin/sh\nexec "%s" -c check_for_update_on_startup=false "$@"\n' "$real" > "$DEMO_BIN/codex"
    chmod +x "$DEMO_BIN/codex"
  fi
}

# Search every pane on the demo server, full scrollback, for the home path and
# the username. Returns 1 if either is found, and prints where.
demo_scan_panes() {
  local found=0 pane hist
  for pane in $(demo_tmux list-panes -a -F '#{pane_id}' 2>/dev/null); do
    hist="$(demo_tmux capture-pane -p -J -S -100000 -t "$pane" 2>/dev/null || true)"
    if printf '%s' "$hist" | grep -q -F "$HOME"; then
      echo "demo: pane $pane shows the home path" >&2; found=1
    fi
    if [ -n "${USER:-}" ] && printf '%s' "$hist" | grep -q -w -F "$USER"; then
      echo "demo: pane $pane shows the username" >&2; found=1
    fi
    # An agent's header can name the signed-in account. Any email address
    # other than the seeded repo's placeholder is treated as one.
    if printf '%s' "$hist" | grep -E -o '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' | grep -v -q -x -F 'demo@example.com'; then
      echo "demo: pane $pane shows an email address" >&2; found=1
    fi
  done
  [ "$found" = 0 ]
}

# Stop the demo server. Leaves /tmp in place for inspection.
demo_stop() {
  demo_env
  "$ROOST" kill >/dev/null 2>&1 || true
}
