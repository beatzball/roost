#!/usr/bin/env bash
# Drive REAL OpenAI Codex CLI against a local model and assert the pane badges.
#
# NOT part of the suite: this directory is deliberately outside tests/'s flat
# test-*.sh glob, so tests/run.sh cannot pick it up. Run it by hand before
# merging adapter changes, and after any codex upgrade.
#
#   bash tests/live/codex-smoke.sh
#
# Needs codex, python3 and a local ollama serving a tool-capable model. No
# OpenAI account and no quota: codex is pointed at a custom model_providers
# entry and never asks for a login — verified, a full turn ran with no
# credential present anywhere. Skips — never fails — if anything is missing.
#
# Isolation: its own tmux socket, its own CODEX_HOME, its own XDG homes. The
# live -L roost server is never contacted.
#
# ---------------------------------------------------------------------------
# THE RIG IS THE HARD PART, and three pieces of it are not obvious.
#
# 1. Codex cannot drive ollama out of the box. It sends tool definitions of
#    type "namespace" and "web_search" that ollama rejects with HTTP 500, and
#    reports that as "We're currently experiencing high demand". Everything goes
#    through tests/live/codex-tool-proxy.py, which carries the measurements.
#
# 2. Trust. Codex skips every hook until a human answers "Trust all and
#    continue", and says nothing when it skips them. That gate is not routed
#    around here — no --dangerously-bypass-hook-trust — it is DRIVEN, with
#    send-keys, because it is the path that can silently fail and therefore the
#    path worth testing. Case 0 below runs a whole turn before granting it, on
#    purpose.
#
# 3. codex updates itself. Observed on this machine while writing this file: a
#    codex TUI being driven inside an isolated tmux socket ran
#    `brew upgrade --cask codex` and replaced the host's binary, 0.150.1 ->
#    0.151.0, mid-test. tmux, CODEX_HOME and the XDG dirs were all isolated and
#    all held; the system package manager is not something a scratch directory
#    can contain. check_for_update_on_startup=false is set below for that reason
#    and is not cosmetic — without it this test can change the version of the
#    thing it is testing, halfway through testing it.
#
# `codex exec` additionally blocks on stdin (every invocation here passes
# < /dev/null) and forces approval: never, so `blocked` can only be exercised
# through the TUI.
set -u
HERE="$(cd "$(dirname "$0")/../.." && pwd)"

# Same default and the same reasoning as tests/live/opencode-smoke.sh: chosen
# for SIZE first, because this is a test a contributor has to pull a model to
# run at all. granite4.2:3b answers a plain turn reliably.
MODEL="${ROOST_LIVE_MODEL:-granite4.2:3b}"
# The permission case needs a model that will actually ASK for escalation.
# Measured: granite4.2:3b never requests it — it either runs what the sandbox
# allows or gives up — so case 3 would silently test nothing on the default
# model. granite4.2:8b requested escalation and put the real dialog on screen.
BIGMODEL="${ROOST_LIVE_BIG_MODEL:-granite4.2:8b}"

skip() { printf '  SKIP: %s\n' "$1"; exit 0; }
command -v codex   >/dev/null 2>&1 || skip "codex not installed"
command -v python3 >/dev/null 2>&1 || skip "python3 not found (the tool-stripping proxy needs it)"
command -v ollama  >/dev/null 2>&1 || skip "ollama not installed"
curl -s -m 5 http://localhost:11434/api/tags >/dev/null 2>&1 \
  || skip "ollama is not responding on :11434"
ollama list 2>/dev/null | grep -q "^${MODEL} " \
  || skip "model $MODEL not pulled (override with ROOST_LIVE_MODEL)"

pass=0; fail=0
ok()      { pass=$((pass+1)); printf '  PASS: %s\n' "$1"; }
no()      { fail=$((fail+1)); printf '  FAIL: %s\n' "$1"; }
# A case the local model refused to set up is not an adapter failure. Case 3
# needs the model to request escalation, and a small local model sometimes just
# answers instead; that must read as SKIP or the suite cries wolf about code
# that was never exercised.
skipped() { printf '  SKIP: %s\n' "$1"; }
note()    { printf '  NOTE: %s\n' "$1"; }
# A readiness timeout means the rig could not be set up, not that a badge was
# wrong. Continuing would send input at a TUI that was never listening, which
# reads as an adapter regression — that has happened in this repo before and
# cost a manual reproduction to rule out.
die()     { fail=$((fail+1)); printf '  FAIL: %s\n' "$1"; printf '\n  %d passed, %d failed\n' "$pass" "$fail"; exit 1; }

D="$(mktemp -d /tmp/amx.XXXX)"
# The socket path MUST end in /roost — roost state is a no-op on any other
# socket, which is exactly the property that keeps it safe to leave
# ~/.codex/hooks.json wired while running codex anywhere else.
S="$D/roost"
L="$(mktemp -d /tmp/amx-codex.XXXX)"
PROXY_PID=""
keep_logs() {
  if [ "$fail" -eq 0 ]; then rm -rf "$L"
  else printf '  logs kept in %s\n' "$L"; fi
}
# The proxy is killed by pid, never by name: `pkill -f codex-tool-proxy` on a
# developer's machine is a pattern that can match more than it means to.
trap 'tmux -S "$S" kill-server 2>/dev/null; [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null; rm -rf "$D"; keep_logs' EXIT

export XDG_CONFIG_HOME="$D/config" XDG_DATA_HOME="$D/data" XDG_CACHE_HOME="$D/cache"
# CODEX_HOME is codex's own home variable and the only one that moves its
# config, its hook trust and its session transcripts. AGENTS.md §8's rule is
# per harness — find the harness's OWN home variable, do not assume the XDG one
# isolates it — and codex is the same shape as copilot's COPILOT_HOME.
#
# One honest note, because it is the kind of thing this file exists to record:
# with CODEX_HOME set to a scratch path, codex still creates ~/.codex/tmp. It is
# empty — no config, no hooks, no credential — but the isolation is not total.
export CODEX_HOME="$D/cxhome"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$CODEX_HOME" "$D/proj"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
python3 "$HERE/tests/live/codex-tool-proxy.py" "$PORT" http://127.0.0.1:11434 "$L/proxy.log" >/dev/null 2>&1 &
PROXY_PID=$!
for _ in $(seq 1 40); do
  curl -s -m 2 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && break
  sleep 0.25
done
curl -s -m 2 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 \
  || die "the tool-stripping proxy did not come up on :$PORT"

write_config() {  # write_config <model>
  cat > "$CODEX_HOME/config.toml" <<TOML
model = "$1"
model_provider = "localllm"
approval_policy = "never"
sandbox_mode = "workspace-write"
# See the header: codex will otherwise upgrade the binary this test is testing,
# from inside the test.
check_for_update_on_startup = false

[model_providers.localllm]
name = "local ollama via the roost tool-stripping proxy"
base_url = "http://127.0.0.1:$PORT/v1"
# "responses", not "chat": wire_api = "chat" was removed in 0.150.1.
# "ollama" is a RESERVED built-in provider id and cannot be overridden, which is
# why this one is called localllm.
wire_api = "responses"

# Pre-trusting the working directory keeps the TUI's own first-run trust prompt
# out of the way, so the only prompt this test has to drive is the hooks one.
[projects."$D/proj"]
trust_level = "trusted"
TOML
}
write_config "$MODEL"

# Install the adapter exactly as a user installs it: the frozen registration
# `roost hooks codex` prints, with the comment lines dropped. Writing anything
# else here would test a shortcut around the path that can fail silently.
"$HERE/bin/roost" hooks codex | sed -n '/^{/,$p' > "$CODEX_HOME/hooks.json"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CODEX_HOME/hooks.json" \
  || die "roost hooks codex did not produce loadable JSON"

tmux -S "$S" -f "$HERE/tmux/roost.conf" new-session -d -x 200 -y 50 -c "$D/proj"
base="$(tmux -S "$S" display -p '#{pane_id}')"
pstate()  { tmux -S "$S" show-options -pqv -t "$1" @agent_state; }
# A TUI pane gets a whole WINDOW, not a split. Codex draws a welcome panel, a
# tip line and its input box; in a half-height split the box is pushed off the
# bottom and the readiness string this file waits for never appears, which reads
# as a hang rather than as "the pane is too small". Windows are also how roost
# actually runs agents (`roost spawn`), so this matches the real shape.
newpane() {  # newpane <name> <command...>
  tmux -S "$S" new-window -d -P -F '#{pane_id}' -n "$1" -c "$D/proj" "${@:2}"
}
# Every readiness failure prints the screen it gave up on. Without it the only
# evidence is "never appeared", which is the one message that cannot be acted on.
dump() { printf '    --- pane %s ---\n' "$1"; tmux -S "$S" capture-pane -p -t "$1" 2>/dev/null | grep -v '^$' | sed 's/^/    /'; }
rread()   { ROOST_SOCKET="$S" "$HERE/bin/roost" read "$1" 2>/dev/null; }
rscreen() { ROOST_SOCKET="$S" "$HERE/bin/roost" screen "$1" 2>/dev/null; }

# wait_state PANE STATE TENTHS — poll for a badge. Polling rather than
# sleeping: `working` exists only while the turn runs, and on a 3B model that
# can be under a second.
wait_state() {
  local p="$1" want="$2" n="${3:-600}" i=0
  while [ "$i" -lt "$n" ]; do
    [ "$(pstate "$p")" = "$want" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
# wait_screen PANE TEXT SECONDS
wait_screen() {
  local p="$1" want="$2" n="${3:-60}" i=0
  while [ "$i" -lt "$n" ]; do
    tmux -S "$S" capture-pane -p -t "$p" 2>/dev/null | grep -qF "$want" && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

printf '\n== case 0: hooks wired but NOT trusted ==\n'
# spec §5 T6, and the reason roost doctor checks consent instead of inferring
# it. The registration is on disk and correct; nobody has trusted it. Codex runs
# the turn perfectly and says nothing about having skipped four hooks, so the
# ONLY observable difference is an unbadged pane — which roost renders exactly
# like a shell.
c0="$(tmux -S "$S" split-window -d -P -F '#{pane_id}' -t "$base" -c "$D/proj" \
  "codex exec --skip-git-repo-check 'Reply with exactly one word: alpha' < /dev/null > $L/c0.txt 2>&1; sleep 600")"
[ -n "$c0" ] || die "case 0: split-window produced no pane id"
# Wait for the TURN, not for a badge: there is no badge coming. "tokens used" is
# codex's own end-of-turn line and is the only marker here that a failed turn
# does not also produce — the prompt is echoed back verbatim, so grepping for a
# word in it would pass on a turn that never reached the model. That was a real
# bug in an earlier draft of this file, and it reported PASS on a turn whose log
# said "ERROR: Reconnecting... waiting for network" five times.
for _ in $(seq 1 240); do grep -q 'tokens used' "$L/c0.txt" 2>/dev/null && break; sleep 1; done
if grep -q 'tokens used' "$L/c0.txt" 2>/dev/null; then
  ok "an untrusted codex still completes its turn normally"
else
  die "case 0: the turn never completed, so nothing below it means anything — see $L/c0.txt"
fi
if [ -z "$(pstate "$c0")" ]; then
  ok "an untrusted codex pane is left completely unbadged"
else
  no "an untrusted codex pane was badged '$(pstate "$c0")' — expected nothing at all"
fi
if grep -qiE 'hooks\.json|/hooks|need review|trusted' "$L/c0.txt" 2>/dev/null; then
  note "codex mentioned hooks or trust in this run — re-read T6, its silence may have been fixed upstream"
else
  ok "codex says nothing at all about the four hooks it skipped (T6)"
fi
tmux -S "$S" kill-pane -t "$c0" 2>/dev/null

printf '\n== granting hook trust, through the real TUI prompt ==\n'
trustpane="$(newpane codex "codex 2>$L/trust-err.txt; sleep 600")"
[ -n "$trustpane" ] || die "trust: new-window produced no pane id"
wait_screen "$trustpane" "Hooks need review" 60 || {
  dump "$trustpane"
  die "the 'Hooks need review' prompt never appeared — see $L/trust-err.txt"
}
ok "codex asks a human to review the hooks before running any of them"
# "2" is "Trust all and continue". Whether it needs an Enter afterwards is a
# version difference, not a guess: on 0.150.1 the digit both selected and
# confirmed, and on 0.151.0 the same keystroke only moves the cursor and the
# prompt sits there saying "Press enter to confirm". Sending Enter
# unconditionally would submit an empty prompt to the model on the older
# behaviour, so it is sent only while the prompt is still on screen.
tmux -S "$S" send-keys -t "$trustpane" "2"
sleep 2
if tmux -S "$S" capture-pane -p -t "$trustpane" 2>/dev/null | grep -qF "Hooks need review"; then
  tmux -S "$S" send-keys -t "$trustpane" Enter
fi
wait_screen "$trustpane" "Ask Codex" 90 || {
  dump "$trustpane"
  die "the TUI never reached its prompt after trusting — see $L/trust-err.txt"
}
trusted=0
for ev in user_prompt_submit post_tool_use permission_request stop; do
  grep -qF "$CODEX_HOME/hooks.json:$ev:0:0" "$CODEX_HOME/config.toml" 2>/dev/null \
    && trusted=$((trusted + 1))
done
if [ "$trusted" -eq 4 ]; then
  ok "all four handlers got a trust entry in config.toml"
else
  no "only $trusted of 4 handlers were trusted — the rest will be skipped in silence"
fi

printf '\n== case 1: a plain TUI turn badges working then done, and records its reply ==\n'
tmux -S "$S" send-keys -t "$trustpane" "Reply with exactly one word: alpha"
sleep 1
tmux -S "$S" send-keys -t "$trustpane" Enter
if wait_state "$trustpane" working 100; then
  ok "UserPromptSubmit badges the pane working"
else
  no "the pane never showed working (badge was '$(pstate "$trustpane")')"
fi
if wait_state "$trustpane" done 1800; then
  ok "Stop badges the pane done"
else
  no "the pane never reached done (badge was '$(pstate "$trustpane")')"
fi
reply="$(rread "$trustpane")"
case "$reply" in
  *alpha*) ok "roost read returns the agent's own answer ($(printf '%s' "$reply" | head -c 40))" ;;
  *)       no "roost read did not return the reply — got: $(printf '%s' "$reply" | head -c 120)" ;;
esac
# The other half of the same claim, and the one that found #14 after 529 green
# assertions did not: a scrape of a full-screen TUI returns its furniture.
screen="$(rscreen "$trustpane")"
case "$screen" in
  *"Ask Codex"*) ok "roost screen returns the TUI's chrome, which is what roost read exists to replace" ;;
  *)             note "the pane's screen did not show the input box; the read/screen contrast was not demonstrated" ;;
esac

printf '\n== case 2: the SessionEnd that lands 22ms after Stop must not erase done ==\n'
# The measured trap, and the one thing in this adapter that a reasonable reading
# of the scout's costing table would have got wrong. Under `codex exec`,
# SessionEnd fires in the same process 22-40ms after Stop (three captures). A
# SessionEnd -> idle mapping would replace the ✅ this turn just earned with 💤,
# and 💤 is the badge that means "nothing to look at here".
#
# This is checked in a pane where codex has EXITED, which is the only place the
# clobber can be observed at rest.
c2="$(tmux -S "$S" split-window -d -P -F '#{pane_id}' -t "$base" -c "$D/proj" \
  "codex exec --skip-git-repo-check 'Reply with exactly one word: bravo' < /dev/null > $L/c2.txt 2>&1; sleep 600")"
[ -n "$c2" ] || die "case 2: split-window produced no pane id"
if wait_state "$c2" done 1800; then
  ok "a codex exec turn badges the pane done"
  # Long enough for a SessionEnd 22ms behind Stop to have landed many times over.
  sleep 3
  st="$(pstate "$c2")"
  if [ "$st" = "done" ]; then
    ok "the badge is still done after codex has exited (SessionEnd is not mapped)"
  else
    no "the badge became '$st' after the turn ended — SessionEnd overwrote done"
  fi
  r2="$(rread "$c2")"
  case "$r2" in
    *bravo*) ok "the exec turn's reply survives too" ;;
    *)       no "the exec turn recorded no reply — got: $(printf '%s' "$r2" | head -c 120)" ;;
  esac
else
  no "the exec turn never badged done — see $L/c2.txt"
fi
tmux -S "$S" kill-pane -t "$c2" 2>/dev/null

printf '\n== case 3: a real permission dialog badges blocked, and PostToolUse clears it ==\n'
if ! ollama list 2>/dev/null | grep -q "^${BIGMODEL} "; then
  skipped "model $BIGMODEL not pulled — the escalation case needs a model that asks (override with ROOST_LIVE_BIG_MODEL)"
else
  # A read-only sandbox with on-request approval, so a write anywhere is an
  # escalation the human has to answer. `codex exec` cannot be used: it forces
  # approval: never, and -a is not one of its flags.
  c3="$(newpane codex-perm "codex -m $BIGMODEL -a on-request -s read-only 2>$L/c3-err.txt; sleep 600")"
  [ -n "$c3" ] || die "case 3: new-window produced no pane id"
  if ! wait_screen "$c3" "Ask Codex" 60; then
    dump "$c3"
    die "case 3: the TUI never became ready — see $L/c3-err.txt"
  fi
  tmux -S "$S" send-keys -t "$c3" "The sandbox is read-only. Use the shell tool with escalated permissions to run exactly: echo escalate-me > $D/esc.txt"
  sleep 1
  tmux -S "$S" send-keys -t "$c3" Enter
  if wait_state "$c3" blocked 4000; then
    ok "PermissionRequest badges the pane blocked"
    if wait_screen "$c3" "Would you like to run" 10; then
      ok "...with the approval dialog genuinely on screen at that moment"
    else
      note "the badge said blocked but the dialog text was not captured; the screen may have scrolled"
    fi
    # roost never answers a permission dialog — this test answers it as the
    # human, with the same keystroke a human would use, which is also what
    # proves the adapter only OBSERVED it.
    tmux -S "$S" send-keys -t "$c3" "1"
    sleep 1
    tmux -S "$S" send-keys -t "$c3" Enter
    if wait_state "$c3" working 600; then
      ok "PostToolUse clears blocked once the human answers"
    else
      no "the badge stayed '$(pstate "$c3")' after approval — nothing cleared blocked"
    fi
    if wait_state "$c3" done 3000; then
      ok "and the turn still finishes done"
    else
      no "the turn never reached done after approval (badge '$(pstate "$c3")')"
    fi
  else
    skipped "$BIGMODEL never requested escalation, so blocked was not exercised — see $L/c3-err.txt"
  fi
  tmux -S "$S" kill-pane -t "$c3" 2>/dev/null
fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
