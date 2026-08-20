#!/usr/bin/env bash
# Drive REAL opencode against a local model and assert the pane badges.
#
# NOT part of the suite: this directory is deliberately outside tests/'s flat
# test-*.sh glob, so tests/run.sh cannot pick it up. Run it by hand before
# merging adapter changes, and after any opencode upgrade.
#
#   bash tests/live/opencode-smoke.sh
#
# Needs opencode and a local ollama serving a tool-capable model. No account
# and no quota: every XDG home is redirected to a scratch directory, so no
# stored credential is even reachable. Skips -- never fails -- if either is
# missing.
#
# Isolation: its own tmux socket. The live -L amux server is never contacted.
set -u
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
MODEL="${AMUX_LIVE_MODEL:-ornith:35b}"

skip() { printf '  SKIP: %s\n' "$1"; exit 0; }
command -v opencode >/dev/null 2>&1 || skip "opencode not installed"
command -v ollama   >/dev/null 2>&1 || skip "ollama not installed"
curl -s -m 5 http://localhost:11434/api/tags >/dev/null 2>&1 \
  || skip "ollama is not responding on :11434"
ollama list 2>/dev/null | grep -q "^${MODEL} " \
  || skip "model $MODEL not pulled (override with AMUX_LIVE_MODEL)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  PASS: %s\n' "$1"; }
no()  { fail=$((fail+1)); printf '  FAIL: %s\n' "$1"; }

# A readiness timeout is not a badge assertion, so it does not fit ok/no --
# it means the harness itself could not get set up, and continuing would just
# send input at a TUI that was never listening. Fail loudly and stop instead
# of letting that read as a plugin regression (it has, and cost a manual
# reproduction to rule out).
die() { printf '  FAIL: %s\n' "$1"; printf '\n  %d passed, %d failed\n' "$pass" "$((fail+1))"; exit 1; }

D="$(mktemp -d /tmp/amx.XXXX)"
# The socket path MUST end in /amux -- amux state is a no-op on any other
# socket, which is exactly what keeps it safe to wire into global hooks.
S="$D/amux"
trap 'tmux -S "$S" kill-server 2>/dev/null; rm -rf "$D"' EXIT

export XDG_CONFIG_HOME="$D/config" XDG_DATA_HOME="$D/data" XDG_CACHE_HOME="$D/cache"
mkdir -p "$XDG_CONFIG_HOME/opencode/plugin" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$D/proj"

# A SYMLINK, matching how a user installs it -- so this also proves opencode
# still follows symlinks when discovering plugins.
ln -s "$HERE/adapters/opencode/amux.js" "$XDG_CONFIG_HOME/opencode/plugin/amux.js"

write_config() {  # write_config <baseURL>
  cat > "$XDG_CONFIG_HOME/opencode/opencode.json" <<JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama local",
      "options": { "baseURL": "$1" },
      "models": { "$MODEL": { "name": "$MODEL" } }
    }
  },
  "model": "ollama/$MODEL",
  "permission": { "bash": "ask" }
}
JSON
}

tmux -S "$S" -f /dev/null new-session -d -x 160 -y 45
tmux -S "$S" source-file "$HERE/tmux/amux.conf"
tmux -S "$S" set-option -g @amux-home "$HERE"

state() { tmux -S "$S" show-options -pqv -t "$1" @agent_state; }

# wait_state PANE WANT TIMEOUT -> 0 if the pane reaches WANT in time
wait_state() {
  local p="$1" want="$2" t="$3" n=0
  while [ "$n" -lt "$t" ]; do
    [ "$(state "$p")" = "$want" ] && return 0
    sleep 1; n=$((n+1))
  done
  return 1
}

# wait_ready PANE TIMEOUT -> 0 once opencode's TUI is actually accepting
# input. A fixed sleep before the first send-keys is long enough on an idle
# machine and not on one loaded by repeated 21GB model runs -- the prompt
# gets typed at a TUI that has not rendered yet and is silently dropped, so
# the pane never leaves its empty state and the failure reads as a plugin
# regression. "ctrl+p commands" is part of the TUI's footer and is present
# once (and only once) the prompt box is live; verified by capturing a real
# pane and grepping for it before wiring this in.
wait_ready() {
  local p="$1" t="$2" n=0
  while [ "$n" -lt "$t" ]; do
    tmux -S "$S" capture-pane -p -t "$p" 2>/dev/null | grep -q "ctrl+p commands" && return 0
    sleep 1; n=$((n+1))
  done
  return 1
}

# amux must be on PATH inside opencode's process, exactly as it is for a real
# user whose shell has bin/ on PATH.
launch() {  # launch -> prints the pane id
  tmux -S "$S" new-window -d -P -F '#{pane_id}' -c "$D/proj" \
    "PATH=$HERE/bin:$PATH opencode"
}

# --- case 1: a normal turn that must ask permission ---
write_config "http://localhost:11434/v1"
p="$(launch)"

wait_ready "$p" 60 || die "opencode's TUI never became interactive (case 1, waited 60s for the ctrl+p commands footer)"
tmux -S "$S" send-keys -t "$p" 'Use the bash tool to run: echo hello'
sleep 1
tmux -S "$S" send-keys -t "$p" Enter

if wait_state "$p" working 90; then ok "pane reaches working when the turn starts"
else no "pane reaches working when the turn starts (got '$(state "$p")')"; fi

if wait_state "$p" blocked 180; then ok "pane reaches blocked at the permission prompt"
else no "pane reaches blocked at the permission prompt (got '$(state "$p")')"; fi

tmux -S "$S" send-keys -t "$p" Enter    # approve: "Allow once" is the default

if wait_state "$p" done 180; then ok "pane reaches done when the turn ends"
else no "pane reaches done when the turn ends (got '$(state "$p")')"; fi

# the adapter must also label the pane, so the border stops showing a version
# string -- same gap the Claude hook fills. It must read "opencode", not
# amux-agent-state's Claude-flavoured "claude" default: the adapter passes
# AMUX_AGENT_NAME=opencode precisely so this doesn't happen.
nm="$(tmux -S "$S" show-options -pqv -t "$p" @amux-name)"
[ "$nm" = "opencode" ] && ok "the adapter labels its pane opencode" || no "the adapter labels its pane opencode (got '$nm')"
tmux -S "$S" kill-window -t "$p" 2>/dev/null

# --- case 2: an unreachable provider must reach error ---
# This is the retry path. It is the only way to produce `error` on demand:
# opencode does not emit session.error for a provider it cannot reach, it
# retries forever (opencode#17648).
write_config "http://127.0.0.1:1/v1"
p2="$(launch)"
wait_ready "$p2" 60 || die "opencode's TUI never became interactive (case 2, waited 60s for the ctrl+p commands footer)"
tmux -S "$S" send-keys -t "$p2" 'Write a haiku about tmux.'
sleep 1
tmux -S "$S" send-keys -t "$p2" Enter

if wait_state "$p2" error 120; then ok "an unreachable provider drives the pane to error"
else no "an unreachable provider drives the pane to error (got '$(state "$p2")')"; fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
