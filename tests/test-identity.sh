#!/usr/bin/env bash
# The agent's identity on its pane (#141): the harness's session id, the
# directory it runs in, which harness it is, and its transcript — stamped as
# @roost-session, @roost-cwd, @roost-harness and @roost-transcript-path, shown
# by `roost status --json`, and copied into the pane record.
#
# Three ways in, one writer (scripts/lib/roost-identity.sh):
#   - `roost identify`, the public command opencode, copilot and pi call
#   - scripts/roost-session-context, Claude Code's SessionStart hook
#   - adapters/codex/roost-codex-hook, on codex's UserPromptSubmit
# The node adapters' side of the first one is tests/test-identity-adapters.sh.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

# The hooks act only on a socket path ending in /roost, so build one directly
# rather than via roost_test_server — the shape tests/test-state-cmd.sh uses.
# HOME and the XDG dirs point into the same throwaway directory, so nothing
# here can reach a real config or a real pane record.
sdir="$(mktemp -d /tmp/amx.XXXX)"; s="$sdir/roost"
REAL_TMUX="$(command -v tmux)"
trap '"$REAL_TMUX" -S "$s" kill-server 2>/dev/null; rm -rf "$sdir"' EXIT
export HOME="$sdir/home" XDG_CONFIG_HOME="$sdir/xc" XDG_STATE_HOME="$sdir/xs"
mkdir -p "$HOME"
tmux -S "$s" -f /dev/null new-session -d -x 200 -y 50 'ENV= exec /bin/sh'
pane="$(tmux -S "$s" display -p '#{pane_id}')"
other="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' 'ENV= exec /bin/sh')"
require_pane "$other" "a plain shell pane"

opt() { tmux -S "$s" show-options -pqv -t "${2:-$pane}" "$1"; }
four() { printf '%s|%s|%s|%s' "$(opt @roost-session "${1:-$pane}")" "$(opt @roost-cwd "${1:-$pane}")" \
  "$(opt @roost-harness "${1:-$pane}")" "$(opt @roost-transcript-path "${1:-$pane}")"; }
R() { env TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/bin/roost" "$@"; }

# A tmux on PATH that logs every call's subcommand, then runs the real one.
# It is how "unchanged costs no write" is seen: the only way to prove a write
# did NOT happen is to watch the calls.
shim="$sdir/shim"; mkdir -p "$shim"; calls="$sdir/tmux-calls"
cat > "$shim/tmux" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$calls"
exec "$REAL_TMUX" "\$@"
EOF
chmod +x "$shim/tmux"
writes() { grep -c 'set-option' "$calls" 2>/dev/null || true; }

printf '\n== roost identify ==\n'
R identify --session sess-1 --cwd /work/one --harness opencode --transcript /work/one/t.jsonl; rc=$?
assert_eq "$rc" "0" "identify exits 0 inside roost"
assert_eq "$(four)" "sess-1|/work/one|opencode|/work/one/t.jsonl" "identify stamps all four options on the calling pane"
assert_eq "$(four "$other")" "|||" "identify leaves every other pane alone"

: > "$calls"
PATH="$shim:$PATH" R identify --session sess-1 --cwd /work/one --harness opencode --transcript /work/one/t.jsonl
assert_eq "$(writes)" "0" "an unchanged identity costs no tmux write"
reads="$(grep -c . "$calls" 2>/dev/null || true)"
assert_eq "$reads" "1" "an unchanged identity costs exactly one tmux call"

: > "$calls"
PATH="$shim:$PATH" R identify --session sess-2 --cwd /work/two --harness opencode
assert_eq "$(four)" "sess-2|/work/two|opencode|" "a new session replaces the old one, and a missing transcript is removed"
assert_eq "$(grep -c . "$calls")" "2" "a changed identity is one read and ONE write"

R identify --session 'id:with.dots_and-dash' --cwd '/path with spaces/ok' --harness my-agent_2
assert_eq "$(four)" "id:with.dots_and-dash|/path with spaces/ok|my-agent_2|" "ordinary punctuation and spaces are accepted where they belong"

out="$(env -u TMUX -u TMUX_PANE "$HERE/bin/roost" identify --session x --cwd /x --harness pi 2>&1)"; rc=$?
assert_eq "$rc:$out" "0:" "outside tmux identify is a silent no-op that exits 0"
out="$(env TMUX=/tmp/not-a-roost-server/default,0,0 TMUX_PANE="$pane" "$HERE/bin/roost" identify --session x --cwd /x --harness pi 2>&1)"; rc=$?
assert_eq "$rc:$out" "0:" "inside a tmux that is not roost's, identify is a silent no-op"
assert_eq "$(opt @roost-session)" "id:with.dots_and-dash" "and it changed nothing"

printf '\n== refusals ==\n'
R identify --session keep --cwd /keep --harness keep --transcript /keep/t
before="$(four)"
refuse() { # WHAT ARGS...
  local what="$1" err rc; shift
  err="$(R identify "$@" 2>&1 >/dev/null)"; rc=$?
  assert_eq "$rc" "2" "refused: $what (exit 2)"
  assert_eq "$(four)" "$before" "refused: $what (nothing written)"
  case "$err" in
    "roost identify: "*|"usage: roost identify "*) err=said ;;
  esac
  assert_eq "$err" "said" "refused: $what (says why on stderr)"
}
long="$(printf '%0129d' 0)"
longp="/$(printf '%01024d' 0)"
refuse "a session id with a newline"     --session $'a\nb' --cwd /x --harness pi
refuse "a session id with a tab"         --session $'a\tb' --cwd /x --harness pi
refuse "a session id with an escape"     --session $'a\033b' --cwd /x --harness pi
refuse "a session id with a space"       --session 'a b' --cwd /x --harness pi
refuse "a session id with a slash"       --session '../x' --cwd /x --harness pi
refuse "a session id ending in ;"        --session 'abc;' --cwd /x --harness pi
refuse "a session id starting with -"    --session '-abc' --cwd /x --harness pi
refuse "a session id of 129 bytes"       --session "$long" --cwd /x --harness pi
refuse "an empty session id"             --session '' --cwd /x --harness pi
refuse "a relative cwd"                  --session a --cwd rel/dir --harness pi
refuse "a cwd with a newline"            --session a --cwd $'/x\n/y' --harness pi
refuse "a cwd with a DEL"                --session a --cwd $'/x\177' --harness pi
refuse "a cwd ending in ;"               --session a --cwd '/x;' --harness pi
refuse "a cwd of 1025 bytes"             --session a --cwd "$longp" --harness pi
refuse "an upper-case harness"           --session a --cwd /x --harness Claude
refuse "a harness with a space"          --session a --cwd /x --harness 'my agent'
refuse "a harness of 33 bytes"           --session a --cwd /x --harness "$(printf 'a%.0s' $(seq 1 33))"
refuse "a relative transcript"           --session a --cwd /x --harness pi --transcript t.jsonl
refuse "a transcript with a newline"     --session a --cwd /x --harness pi --transcript $'/t\n.jsonl'
refuse "a missing --harness"             --session a --cwd /x
refuse "a missing --session"             --cwd /x --harness pi
refuse "a flag with no value"            --session a --cwd /x --harness
refuse "an unknown flag"                 --session a --cwd /x --harness pi --colour red
long_ok="$(printf '%0128d' 0)"
R identify --session "$long_ok" --cwd "/$(printf '%01023d' 0)" --harness "$(printf 'a%.0s' $(seq 1 32))"
assert_eq "$(opt @roost-session)" "$long_ok" "a session id of exactly 128 bytes is accepted"
assert_eq "$before" "keep|/keep|keep|/keep/t" "(control) the refusals above ran against a set identity"

printf '\n== status --json ==\n'
R identify --session sess-json --cwd '/w/a "quoted" dir' --harness claude --transcript /w/t.jsonl
doc="$(ROOST_SOCKET="$s" "$HERE/bin/roost" status --json)"
if command -v python3 >/dev/null 2>&1; then
  got="$(printf '%s' "$doc" | python3 -c '
import sys, json
d = json.load(sys.stdin)
p = {x["id"]: x for x in d["panes"]}
a, b = p[sys.argv[1]], p[sys.argv[2]]
print(d["schema"])
print("|".join(str(a[k]) for k in ("session_id", "cwd", "harness", "transcript")))
print("|".join(repr(b[k]) for k in ("session_id", "cwd", "harness", "transcript")))
print(a["session"] == b["session"] and isinstance(a["session"], str))' "$pane" "$other")"
  assert_eq "$(printf '%s' "$got" | sed -n 1p)" "1" "status --json keeps schema 1"
  assert_eq "$(printf '%s' "$got" | sed -n 2p)" 'sess-json|/w/a "quoted" dir|claude|/w/t.jsonl' "an identified pane carries all four fields"
  assert_eq "$(printf '%s' "$got" | sed -n 3p)" "None|None|None|None" "a plain shell pane carries four nulls"
  assert_eq "$(printf '%s' "$got" | sed -n 4p)" "True" "the tmux session name keeps its own key"
else
  printf '  SKIP: python3 not found — status --json fields not checked\n'
fi

printf '\n== the pane record ==\n'
rec="$sdir/records"
env ROOST_RECORD_DIR="$rec" TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/bin/roost" identify --session rec-1 --cwd /r/one --harness pi
boot="$(tmux -S "$s" display-message -p '#{start_time}-#{pid}')"
d="$rec/$boot/${pane#%}"
assert_eq "$(cat "$d/session_id" 2>/dev/null)" "rec-1" "the record holds session_id"
assert_eq "$(cat "$d/cwd" 2>/dev/null)" "/r/one" "the record holds cwd"
assert_eq "$(cat "$d/harness" 2>/dev/null)" "pi" "the record holds harness"
assert_eq "$(cat "$d/schema" 2>/dev/null)" "1" "the record has its schema"
assert_eq "$(cat "$d/socket" 2>/dev/null)" "$s" "the record names its server"
mode="$(ls -ld "$d" | cut -c1-10)"
assert_eq "$mode" "drwx------" "the record directory is private"
env ROOST_RECORD_DIR="$rec" TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/bin/roost" identify --session rec-2 --cwd /r/one --harness pi
assert_eq "$(cat "$d/session_id" 2>/dev/null)" "rec-2" "a new session id replaces the old one in the record"
ls "$d" | grep -q '^\.tmp' && no_tmp=1 || no_tmp=0
assert_eq "$no_tmp" "0" "no temp file is left in the record"

# The 30-day sweep (ROOST_RECORD_DAYS) runs when a pane's record directory is
# CREATED. Identity now creates it, at session start, before the pane's first
# turn — so identity must run the sweep, or no identified pane ever would.
# Planted: a record whose server is gone (its socket does not exist) and whose
# replies/ is years old.
plant() {
  mkdir -p "$rec/1000000000-9/7/replies"
  printf '1\n' > "$rec/1000000000-9/7/schema"
  printf '%s\n' "$sdir/no-such-server" > "$rec/1000000000-9/7/socket"
  touch -t 202001010000 "$rec/1000000000-9/7/replies"
}
# `roost reply` checks that $TMUX names this server's own pid, so these calls
# carry the real one rather than the 0 the calls above use.
spid="$(tmux -S "$s" display-message -p '#{pid}')"
plant
fresh="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' 'ENV= exec /bin/sh')"
require_pane "$fresh" "a fresh pane for the sweep"
env ROOST_RECORD_DIR="$rec" TMUX="$s,0,0" TMUX_PANE="$fresh" "$HERE/bin/roost" identify --session sw-1 --cwd /sw --harness pi
env ROOST_RECORD_DIR="$rec" TMUX="$s,$spid,0" TMUX_PANE="$fresh" "$HERE/bin/roost" reply "FIRST TURN"
[ -d "$rec/1000000000-9/7" ] && swept=no || swept=yes
assert_eq "$swept" "yes" "a pane identified before its first turn still sweeps a gone, old record"
plant
ctl="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' 'ENV= exec /bin/sh')"
env ROOST_RECORD_DIR="$rec" TMUX="$s,$spid,0" TMUX_PANE="$ctl" "$HERE/bin/roost" reply "FIRST TURN"
[ -d "$rec/1000000000-9/7" ] && swept=no || swept=yes
assert_eq "$swept" "yes" "(control) a pane that only replies sweeps the same planted record"

printf '\n== Claude Code: SessionStart ==\n'
ctx() { env TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/scripts/roost-session-context"; }
R identify --session x --cwd /x --harness x
payload='{"session_id":"c-1111","transcript_path":"/h/.claude/projects/p/c-1111.jsonl","cwd":"/work/proj","hook_event_name":"SessionStart","source":"startup"}'
out="$(printf '%s' "$payload" | ctx)"; rc=$?
assert_eq "$rc" "0" "the SessionStart hook still exits 0"
assert_eq "$(four)" "c-1111|/work/proj|claude|/h/.claude/projects/p/c-1111.jsonl" "SessionStart stamps all four from its payload"
if command -v python3 >/dev/null 2>&1; then
  ev="$(printf '%s' "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["hookSpecificOutput"]["hookEventName"])' 2>&1)"
  assert_eq "$ev" "SessionStart" "the context it prints is still valid JSON"
fi
printf '%s' '{"session_id":"c-2222","transcript_path":"/h/.claude/projects/p/c-2222.jsonl","cwd":"/work/proj","source":"clear"}' | ctx >/dev/null
assert_eq "$(four)" "c-2222|/work/proj|claude|/h/.claude/projects/p/c-2222.jsonl" "a /clear's new session id replaces the old one"
printf '%s' '{"session_id":"c-3333","transcript_path":"relative.jsonl","cwd":"/work/proj"}' | ctx >/dev/null
assert_eq "$(four)" "c-3333|/work/proj|claude|" "a bad transcript path is dropped, and the other three still land"
printf '%s' '{"session_id":"sub-1","transcript_path":"/t.jsonl","cwd":"/sub","agent_id":"a1"}' | ctx >/dev/null
assert_eq "$(opt @roost-session)" "c-3333" "a subagent's payload changes nothing"
printf '%s' '{"session_id":"bad id","cwd":"/work/proj"}' | ctx >/dev/null
assert_eq "$(opt @roost-session)" "c-3333" "a payload with a bad session id changes nothing"
printf '%s' 'not json' | ctx >/dev/null; rc=$?
assert_eq "$rc:$(opt @roost-session)" "0:c-3333" "a payload that is not JSON changes nothing and still exits 0"
out="$(printf '%s' "$payload" | env TMUX=/tmp/not-roost/default,0,0 TMUX_PANE="$pane" "$HERE/scripts/roost-session-context")"
assert_eq "$out:$(opt @roost-session)" ":c-3333" "outside roost the hook prints nothing and stamps nothing"

# --- the jq reader, on a PATH with no python3 ---------------------------------
# Every machine this suite runs on has python3, so without this block the jq
# arm of roost_identity_from_payload never runs. Exec wrappers, never symlinks
# to the real binaries — the shape tests/test-claude-stop-failure.sh uses, and
# for its reason: a later `>` into a shim entry would follow a symlink.
if command -v jq >/dev/null 2>&1; then
  jshim="$sdir/jq-only-bin"; mkdir -p "$jshim"
  for c in tmux jq cat date dirname readlink sh bash env mktemp mv rm mkdir chmod; do
    real="$(command -v "$c")" || continue
    printf '#!/bin/sh\nexec %s "$@"\n' "$real" > "$jshim/$c"; chmod +x "$jshim/$c"
  done
  # A positive control first: the same probe finds python3 once its directory
  # is added, so the absence check below is not a probe that cannot run.
  # Only where there is a python3 to find: on a machine with jq and no python3,
  # the one this block exists for, there is nothing for the control to show,
  # and the absence probe below is the whole proof.
  if command -v python3 >/dev/null 2>&1; then
    pydir="$(dirname "$(command -v python3)")"
    env PATH="$jshim:$pydir" sh -c 'command -v python3' >/dev/null 2>&1
    assert_eq "$?" "0" "positive control: the shim's sh finds python3 when its directory is on PATH"
  fi
  env PATH="$jshim" sh -c 'command -v python3' >/dev/null 2>&1
  jrc=$?
  [ "$jrc" -ne 0 ]; assert_true $? "the jq-only PATH really has no python3 (probe exit $jrc)"
  jctx() { env PATH="$jshim" TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/scripts/roost-session-context" >/dev/null; }
  printf '%s' '{"session_id":"j-1","transcript_path":"/j/t.jsonl","cwd":"/j/proj","source":"startup"}' | jctx
  assert_eq "$(four)" "j-1|/j/proj|claude|/j/t.jsonl" "jq reader: SessionStart stamps all four"
  printf '%s' '{"session_id":"j-sub","transcript_path":"/j/s.jsonl","cwd":"/j/sub","agent_id":"a1"}' | jctx
  assert_eq "$(opt @roost-session)" "j-1" "jq reader: a subagent's payload changes nothing"
  printf '%s' '{"session_id":"j-2","transcript_path":"/j/t.jsonl","cwd":"/j/a\nb"}' | jctx
  assert_eq "$(opt @roost-session)" "j-1" "jq reader: a newline in cwd changes nothing"
  printf '%s' '{"session_id":"j-2","transcript_path":"/j/t.jsonl","cwd":"/j/a\u007fb"}' | jctx
  assert_eq "$(opt @roost-session)" "j-1" "jq reader: a DEL in cwd changes nothing"
  printf '%s' '["j-2"]' | jctx
  assert_eq "$(opt @roost-session)" "j-1" "jq reader: an array changes nothing"
  printf '%s' '{"session_id":"j-3","transcript_path":"rel.jsonl","cwd":"/j/proj"}' | jctx
  assert_eq "$(four)" "j-3|/j/proj|claude|" "jq reader: a relative transcript is dropped and the rest lands"
else
  printf '  SKIP: jq not found — the jq reader is not checked\n'
fi

printf '\n== codex: UserPromptSubmit ==\n'
cx() { env TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/adapters/codex/roost-codex-hook" "$@"; }
cpay='{"session_id":"01a0f0f6-4a8b-7c71","transcript_path":"/cx/sessions/rollout-01a0f0f6.jsonl","cwd":"/work/cx","hook_event_name":"UserPromptSubmit","prompt":"hi"}'
tmux -S "$s" set-option -pu -t "$pane" @agent_state
printf '%s' "$cpay" | cx UserPromptSubmit; rc=$?
assert_eq "$rc" "0" "the codex hook still exits 0"
assert_eq "$(four)" "01a0f0f6-4a8b-7c71|/work/cx|codex|/cx/sessions/rollout-01a0f0f6.jsonl" "UserPromptSubmit stamps all four from its payload"
assert_eq "$(opt @agent_state)" "working" "and still badges working"
# The badge goes first: the identity work (a `cat`, a `ps`, a reader and a tmux
# read) must not delay the `working` the human is watching for.
R identify --session other --cwd /other --harness codex
tmux -S "$s" set-option -pu -t "$pane" @agent_state
: > "$calls"
printf '%s' "$cpay" | PATH="$shim:$PATH" cx UserPromptSubmit
badge_at="$(grep -n '@agent_state working' "$calls" | head -1 | cut -d: -f1)"
ident_at="$(grep -n '@roost-session' "$calls" | head -1 | cut -d: -f1)"
[ -n "$badge_at" ] && [ -n "$ident_at" ] && [ "$badge_at" -lt "$ident_at" ] && order=badge-first || order="badge=$badge_at identity=$ident_at"
assert_eq "$order" "badge-first" "codex: the working badge is sent before the identity is read"
: > "$calls"
printf '%s' "$cpay" | PATH="$shim:$PATH" cx UserPromptSubmit
assert_eq "$(writes)" "0" "a second prompt in the same session costs no tmux write"
R identify --session keep --cwd /keep --harness keep
printf '%s' "$cpay" | cx PostToolUse
assert_eq "$(opt @roost-session)" "keep" "PostToolUse never reads identity"
# Codex 0.157.1 runs every hook inside ONE shared app-server process, started
# by whichever codex came first, so $TMUX_PANE names THAT codex's pane for all
# of them (measured; see the adapter). A hook whose parent is that process
# cannot know its pane, and must not write another pane's identity.
mkdir -p "$sdir/bin"
cat > "$sdir/bin/app-server" <<EOF
#!/usr/bin/env bash
"$HERE/adapters/codex/roost-codex-hook" "\$@"
EOF
chmod +x "$sdir/bin/app-server"
printf '%s' "$cpay" | env TMUX="$s,0,0" TMUX_PANE="$pane" "$sdir/bin/app-server" UserPromptSubmit
assert_eq "$(opt @roost-session)" "keep" "a hook run by codex's shared app-server writes no identity"
printf '%s' "$cpay" | env TMUX="$s,0,0" TMUX_PANE="$pane" bash -c '"$0" UserPromptSubmit' "$HERE/adapters/codex/roost-codex-hook"
assert_eq "$(opt @roost-session)" "01a0f0f6-4a8b-7c71" "(control) the same payload through an ordinary parent does write it"
