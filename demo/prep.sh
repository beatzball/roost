#!/usr/bin/env bash
# Reset the demo environment before a recording that starts outside roost.
#
#   ./demo/prep.sh && vhs demo/first-run.tape
#
# Leaves no server running: the recording starts one on camera.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

demo_reset

# Claude asks whether it trusts a folder it has not seen, and that dialog is
# not something a first-run video should open on. Answer it here, off camera,
# in a throwaway session on the demo server, then take the server down again.
# Safe to answer: demo_reset created this folder a moment ago.
if command -v claude >/dev/null 2>&1; then
  "$ROOST" spawn trust >/dev/null
  demo_tmux send-keys -t "=main:trust" "cd $DEMO_REPO && claude" Enter
  for _ in $(seq 1 30); do
    screen="$(demo_tmux capture-pane -p -t "=main:trust" 2>/dev/null || true)"
    if printf '%s' "$screen" | grep -q "trust this folder"; then
      demo_tmux send-keys -t "=main:trust" Down
      demo_tmux send-keys -t "=main:trust" Enter
      sleep 4
      break
    fi
    # Already trusted: the prompt box is up and there is nothing to answer.
    printf '%s' "$screen" | grep -q -E "for shortcuts|auto mode|bypass permissions" && break
    sleep 1
  done
fi

# Codex asks the same about a folder, and a reviewer stuck on that dialog never
# reviews. Its first option is "Yes, continue", so Enter answers it.
if command -v codex >/dev/null 2>&1; then
  # spawn opens the window in the caller's directory, and the trust being
  # answered is for the demo repo.
  cd "$DEMO_REPO"
  "$ROOST" spawn codex-trust "$DEMO_BIN/codex" >/dev/null
  for _ in $(seq 1 30); do
    screen="$(demo_tmux capture-pane -p -t "=main:codex-trust" 2>/dev/null || true)"
    if printf '%s' "$screen" | grep -q "trust the contents"; then
      demo_tmux send-keys -t "=main:codex-trust" Enter
      sleep 4
      break
    fi
    printf '%s' "$screen" | grep -q "Ask Codex" && break
    sleep 1
  done
fi

demo_stop
echo "demo: reset. Server stopped; repo at $DEMO_REPO; config at $DEMO_XDG."
