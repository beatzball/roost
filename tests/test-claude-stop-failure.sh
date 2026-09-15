#!/usr/bin/env bash
# A Claude Code turn that ends on an API error — a rate limit, an overload, a
# model that does not exist — badges 💥 error, not ⏳ working forever (#55).
#
# Measured on Claude Code 2.1.272, with a logger on all 33 hook events and a
# throwaway -S server. Every failure was triggered on demand, never a real rate
# limit: a model name that does not exist (against the real API), a local fake
# API answering 429, 500 or 529, and a base URL nobody listens on.
#
#   case                         events after UserPromptSubmit      `error`
#   healthy haiku turn           Stop                               -
#   --model <nonexistent>        StopFailure                        model_not_found
#   fake API 429, no retries     StopFailure                        rate_limit
#   fake API 429, retries on     (3 min of retries) StopFailure     rate_limit
#   fake API 500                 StopFailure                        server_error
#   fake API 529                 StopFailure                        server_error
#   connection refused           StopFailure                        server_error
#   Esc while the model streams  nothing                            -
#
# StopFailure fires INSTEAD of Stop, exactly once, within ~60 ms of the failure.
# Nothing else fires for about 60 s, and then only an idle_prompt Notification,
# which roost's permission_prompt matcher ignores. So before this, no hook ran
# after UserPromptSubmit's ⏳ and the badge stayed working on an idle pane.
#
# Claude's own source (2.1.272) builds the payload from the same fields every
# hook gets, plus `agent_id` when the failing loop belongs to a subagent. A
# subagent's API error does not end the main turn, so that payload must leave
# the pane alone. That case is read from the source, not measured live.
#
# The payloads below are the real rate_limit and model_not_found captures with
# every id replaced by a fake of the same shape and the home path dropped.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"
HOOK="$HERE/scripts/roost-agent-state"

# The payloads below are built and edited with python3. Without it several
# assertions would pass on empty payloads, so skip loudly instead (found by
# review). The hook's own no-python3 paths are covered in docs/known-gaps.md.
if ! command -v python3 >/dev/null 2>&1; then
  echo "  SKIP: python3 not available (this file builds its payloads with it)"
  exit 0
fi

# roost-agent-state only acts on a socket path ending in /roost.
sdir="$(mktemp -d /tmp/amx.XXXX)"; s="$sdir/roost"
trap 'tmux -S "$s" kill-server 2>/dev/null; rm -rf "$sdir"' EXIT
tmux -S "$s" -f /dev/null new-session -d -x 200 -y 50 'sh -c "while :; do sleep 5; done"'
pane="$(tmux -S "$s" display -p '#{pane_id}')"
export ROOST_SOCKET="$s"

pstate() { tmux -S "$s" show-options -pqv -t "$pane" @agent_state; }
preply() { tmux -S "$s" show-options -pqv -t "$pane" @roost-reply; }
reason() { tmux -S "$s" show-options -pqv -t "$pane" @roost-error-reason; }
# The hook exactly as `roost hooks` wires it: the command, and the payload on a
# stdin that is not a tty.
hook() { # hook ARGS... <<< PAYLOAD
  env TMUX="$s,0,0" TMUX_PANE="$pane" "$HOOK" "$@"
}

UPS='{"session_id":"00000000-0000-4000-8000-000000000551","transcript_path":"/tmp/roost-fixture/00000000-0000-4000-8000-000000000551.jsonl","cwd":"/tmp/roost-fixture/proj","prompt_id":"00000000-0000-4000-8000-0000000005a1","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"Reply with exactly the word PONG and nothing else."}'
STOP_OK='{"session_id":"00000000-0000-4000-8000-000000000551","transcript_path":"/tmp/roost-fixture/00000000-0000-4000-8000-000000000551.jsonl","cwd":"/tmp/roost-fixture/proj","prompt_id":"00000000-0000-4000-8000-0000000005a1","permission_mode":"default","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"PONG","background_tasks":[],"session_crons":[]}'
STOP_OK2="${STOP_OK/\"PONG\"/\"PONG AGAIN\"}"
RATE_LIMIT='{"session_id":"00000000-0000-4000-8000-000000000551","transcript_path":"/tmp/roost-fixture/00000000-0000-4000-8000-000000000551.jsonl","cwd":"/tmp/roost-fixture/proj","scratchpad_dir":"/tmp/roost-fixture/scratchpad","prompt_id":"00000000-0000-4000-8000-0000000005a2","hook_event_name":"StopFailure","error":"rate_limit","last_assistant_message":"API Error: Server is temporarily limiting requests (not your usage limit) · Number of request tokens has exceeded your per-minute rate limit"}'
MODEL_NOT_FOUND='{"session_id":"00000000-0000-4000-8000-000000000551","transcript_path":"/tmp/roost-fixture/00000000-0000-4000-8000-000000000551.jsonl","cwd":"/tmp/roost-fixture/proj","scratchpad_dir":"/tmp/roost-fixture/scratchpad","prompt_id":"00000000-0000-4000-8000-0000000005a3","effort":{"level":"high"},"hook_event_name":"StopFailure","error":"model_not_found","last_assistant_message":"There'"'"'s an issue with the selected model (claude-nonexistent-model-0). It may not exist or you may not have access to it. Run /model to pick a different model."}'
# Built from the capture, so the only difference is the field under test.
SUBAGENT="${RATE_LIMIT/\"hook_event_name\"/\"agent_id\":\"a0000000000000551\",\"agent_type\":\"general-purpose\",\"hook_event_name\"}"
assert_contains "$SUBAGENT" '"agent_id":"a0000000000000551"' "the subagent fixture really carries an agent_id"

# --- the wiring --------------------------------------------------------------
hooks_out="$("$ROOST" hooks)"
assert_contains "$hooks_out" '"StopFailure"' "roost hooks wires Claude's StopFailure event"
assert_contains "$hooks_out" "$HOOK error --stop-failure-hook" \
  "...to roost-agent-state error --stop-failure-hook"
# No matcher: every value Claude lists for `error` ends a turn that did not
# finish, and a matcher naming some of them would miss whichever it adds next.
sf_matcher="$(printf '%s' "$hooks_out" | sed -n '/^{/,$p' | python3 -c 'import json,sys
print([e.get("matcher") for e in json.load(sys.stdin)["hooks"]["StopFailure"]])' 2>/dev/null)"
assert_eq "$sf_matcher" "[None]" "the StopFailure entry has no matcher, so every error kind reaches it"

# --- a healthy turn still reaches done ---------------------------------------
hook working <<< "$UPS"
assert_eq "$(pstate)" "working" "a healthy turn starts working"
hook done --stop-hook <<< "$STOP_OK"
assert_eq "$(pstate)" "done" "a healthy turn reaches done"
assert_eq "$(preply)" "PONG" "...with its reply"

# --- a rate-limited turn badges error ----------------------------------------
hook working <<< "$UPS"
hook error --stop-failure-hook <<< "$RATE_LIMIT"; rc=$?
assert_eq "$rc" "0" "the StopFailure hook exits 0"
assert_eq "$(pstate)" "error" "a turn that ends on a rate limit badges error, not working"
assert_contains "$(reason)" "rate_limit" "...and the pane records the kind of error"
assert_contains "$(reason)" "API error" "...in a sentence that says it was an API error"
# The previous turn's PONG is not this turn's answer, and neither is Claude's
# error banner: last_assistant_message on a StopFailure is the error text.
assert_eq "$(preply)" "" "...and the previous turn's reply is cleared, not served as this one's"

werr="$("$ROOST" wait-done "$pane" 2 2>&1 >/dev/null)"; rc=$?
assert_eq "$rc" "1" "wait-done on a rate-limited Claude pane exits 1"
assert_contains "$werr" "error state" "...naming the state"
assert_contains "$werr" "rate_limit" "...and the reason"
rerr="$("$ROOST" read "$pane" 5 2>&1 >/dev/null)"
assert_contains "$rerr" "rate_limit" "read on a rate-limited Claude pane names the reason"

# --- the next healthy turn recovers completely -------------------------------
hook working <<< "$UPS"
assert_eq "$(pstate)" "working" "the turn after a failed one starts working"
assert_eq "$(reason)" "" "...and the failed turn's reason is cleared"
hook done --stop-hook <<< "$STOP_OK2"
assert_eq "$(pstate)" "done" "...and a healthy turn after a failed one reaches done"
assert_eq "$(preply)" "PONG AGAIN" "...with its own reply"
"$ROOST" wait-done "$pane" 2 >/dev/null 2>&1
assert_eq "$?" "0" "wait-done on the recovered pane exits 0"

# --- another kind, from the real API -----------------------------------------
hook working <<< "$UPS"
hook error --stop-failure-hook <<< "$MODEL_NOT_FOUND"
assert_eq "$(pstate)" "error" "a turn on a model that does not exist badges error"
assert_contains "$(reason)" "model_not_found" "...and names model_not_found"

# --- a subagent's API error leaves the main turn alone -----------------------
hook working <<< "$UPS"
hook done --stop-hook <<< "$STOP_OK"
hook working <<< "$UPS"
hook error --stop-failure-hook <<< "$SUBAGENT"; rc=$?
assert_eq "$rc" "0" "a subagent's StopFailure exits 0"
assert_eq "$(pstate)" "working" "a subagent's StopFailure does not badge the main turn error"
assert_eq "$(reason)" "" "...records no reason"
assert_eq "$(preply)" "PONG" "...and does not clear the last finished turn's reply"

# --- the reason is a fixed sentence, never text out of the payload ------------
for bad in 'rate_limit; set-option -g status off' 'RATE_LIMIT' 'rate limit' \
           "$(printf 'rate_limit\nsecond line')" "$(printf 'a%.0s' $(seq 60))" ''; do
  payload="$(python3 -c 'import json,sys
d=json.loads(sys.argv[1]); d["error"]=sys.argv[2]; print(json.dumps(d))' "$RATE_LIMIT" "$bad")"
  hook working <<< "$UPS"
  hook error --stop-failure-hook <<< "$payload"
  assert_eq "$(pstate)" "error" "an unexpected error value still badges error [$bad]"
  assert_contains "$(reason)" "unknown" "...with the kind given as unknown [$bad]"
  case "$(reason)" in
    *set-option*|*RATE*|*"rate limit"*|*$'\n'*|*aaaaaaaaaa*) assert_eq echoed fixed "...and none of the value is echoed [$bad]" ;;
    *) assert_eq ok ok "...and none of the value is echoed [$bad]" ;;
  esac
done
# A number, an object, no field at all, a JSON value that is not an object,
# and no JSON.
odd() { python3 -c 'import json,sys
d=json.loads(sys.argv[1])
if sys.argv[2] == "drop": del d["error"]
elif sys.argv[2] == "newline": d["error"]="rate_limit"+chr(10)
elif sys.argv[2] == "nul": d["error"]="x"+chr(0)+"y"
else: d["error"]=json.loads(sys.argv[2])
print(json.dumps(d))' "$RATE_LIMIT" "$1"; }
# Also two strings the shell would clean before it could check them: $(...)
# strips a trailing newline and bash drops a NUL, so without a check in the
# reader these came back as "rate_limit" and "xy" (found by review).
# The two values are built inside python with chr(), never written here as
# escape text: an editor can turn that text into the real byte, and then the
# shell drops it before the test runs. The detectors prove each one arrives.
nulesc="$(printf 'x\\u%sy' 0000)"; nlesc="$(printf 'rate_limit\\%s' n)"
assert_contains "$(odd nul)" "$nulesc" "the NUL fixture really carries an escaped NUL"
assert_contains "$(odd newline)" "$nlesc" "the newline fixture really carries an escaped newline"
for payload in "$(odd 429)" "$(odd '{}')" "$(odd drop)" "$(odd newline)" "$(odd nul)" \
               '["rate_limit"]' 'not json at all' ''; do
  hook working <<< "$UPS"
  hook error --stop-failure-hook <<< "$payload"
  assert_eq "$(pstate)" "error" "a StopFailure whose payload cannot be read still badges error [${payload:0:40}]"
  assert_contains "$(reason)" "unknown" "...with the kind given as unknown [${payload:0:40}]"
done

# --- the jq reader, on a PATH with no python3 ----------------------------------
# Every machine this suite has run on has python3, so without this section the
# jq branch is never run. Mutation showed why it matters: with ^ and $ in place
# of \A and \z, jq's $ also matches before a trailing newline, and
# "rate_limit\n" came back as rate_limit again with every test above green.
#
# The shim holds small exec wrappers, never symlinks to the real binaries: a
# later `>` into a shim entry would follow a symlink and overwrite the real
# tool. Only the commands the hook needs are in it, and python3 is not.
if command -v jq >/dev/null 2>&1; then
  shim="$sdir/jq-only-bin"; mkdir -p "$shim"
  for c in tmux jq cat date dirname readlink sh bash env; do
    real="$(command -v "$c")" || continue
    printf '#!/bin/sh\nexec %s "$@"\n' "$real" > "$shim/$c"; chmod +x "$shim/$c"
  done
  env PATH="$shim" sh -c 'command -v python3' >/dev/null 2>&1
  assert_eq "$?" "1" "the jq-only PATH really has no python3"
  jhook() { env PATH="$shim" TMUX="$s,0,0" TMUX_PANE="$pane" "$HOOK" "$@"; }
  hook working <<< "$UPS"
  jhook error --stop-failure-hook <<< "$RATE_LIMIT"
  assert_eq "$(pstate)" "error" "jq reader: a rate-limited turn badges error"
  assert_contains "$(reason)" "rate_limit" "jq reader: ...and names rate_limit"
  for v in newline nul; do
    hook working <<< "$UPS"
    jhook error --stop-failure-hook <<< "$(odd "$v")"
    assert_contains "$(reason)" "unknown" "jq reader: a $v in the kind gives unknown"
  done
  hook done --stop-hook <<< "$STOP_OK"
  hook working <<< "$UPS"
  jhook error --stop-failure-hook <<< "$SUBAGENT"
  assert_eq "$(pstate)" "working" "jq reader: a subagent's StopFailure leaves the main turn working"
else
  echo "  SKIP: jq not available, so the jq reader is not run here"
fi

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
