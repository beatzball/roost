#!/usr/bin/env bash
# `--json` on status, read, screen, whoami and state (#41).
#
# Contract: docs/airig/specs/2026-09-15-json-output-design.md. The encoder and
# the delimiter-free tmux reads live in scripts/lib/roost-jsonout.sh.
#
# Four things are pinned here, in this order:
#   1. every human invocation is BYTE-IDENTICAL to the output captured from the
#      commit before --json existed (tests/fixtures/json-human-output.txt)
#   2. every document is one line of valid JSON with exactly the fields and
#      values the design names
#   3. pathological bytes -- quotes, backslashes, control bytes, emoji, invalid
#      UTF-8, a trailing semicolon -- survive the round trip through the reply
#      channel and through a pane name. NUL cannot reach roost at all (argv and
#      bash strings cannot carry it); the NUL cases only pin that shell fact
#   4. the encoder itself, fuzzed with every single byte and random mixtures
#
# python3 is this file's JSON ORACLE and nothing more: roost never runs it.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"
GOLDEN="$HERE/tests/fixtures/json-human-output.txt"

# A missing oracle must never read as green where it matters. On CI it is a
# failure; on a contributor's machine it is a visible SKIP, never silence.
if ! command -v python3 >/dev/null 2>&1; then
  if [ -n "${CI:-}" ]; then
    printf '  FAIL: python3 is the JSON oracle for tests/test-json-output.sh and CI must provide it\n'
    exit 1
  fi
  printf '  SKIP: tests/test-json-output.sh needs python3 as its JSON oracle (roost itself does not)\n'
  exit 0
fi

# roost-agent-state acts only on a socket path ending in /roost, and `state`
# is under test, so the server is built by hand the way
# tests/test-reply-channel.sh builds its own.
work="$(mktemp -d /tmp/amx.XXXX)"; s="$work/roost"
trap 'tmux -S "$s" kill-server 2>/dev/null; rm -rf "$work"' EXIT
export HOME="$work/home" XDG_CONFIG_HOME="$work/xdg" XDG_STATE_HOME="$work/xstate" XDG_DATA_HOME="$work/xdata"
export ROOST_NO_EXT=1 ROOST_SOCKET="$s"
mkdir -p "$HOME"
unset TMUX TMUX_PANE
T() { tmux -S "$s" "$@"; }

# A UTF-8 locale this machine accepts, found by asking bash to count one
# two-byte character rather than by `locale -a`, which musl systems lack.
json_utf8=""
for cand in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
  if [ "$(LC_ALL="$cand" bash -c 'x="é"; printf %s "${#x}"' 2>/dev/null)" = 1 ]; then json_utf8="$cand"; break; fi
done
# with_utf8 CMD... -- run CMD with LC_ALL EXPORTED as that locale. macOS CI
# exports LC_ALL, and a roost function that ran tmux under `local LC_ALL=C`
# then handed tmux a C locale, so tmux 3.4 and 3.7c sanitised every tab, newline
# and non-ASCII byte of its OUTPUT to `_` (measured on 3.4, 3.6 and 3.7c). A
# test that never exported LC_ALL was green on the author's machine, which does
# not export it, and red on macOS CI, which does.
with_utf8() { if [ -n "$json_utf8" ]; then env LC_ALL="$json_utf8" "$@"; else "$@"; fi; }

# cap NAME CMD... -> $work/NAME.out, .err, .rc
cap() { local p="$work/$1"; shift; "$@" >"$p.out" 2>"$p.err"; printf '%s' "$?" >"$p.rc"; }
rc()  { cat "$work/$1.rc"; }

# as_pane PANE CMD... -- run as if from inside PANE on this server. `reply`
# checks the server pid inside $TMUX, and `state` checks the socket path.
as_pane() { local p="$1"; shift; env TMUX="$s,$spid,0" TMUX_PANE="$p" "$@"; }

# gold LABEL CMD... -- run a HUMAN invocation and append stdout, stderr and the
# exit status to the transcript that is compared with the golden file at the end.
gold() {
  local label="$1"; shift
  cap g "$@"
  python3 - "$work/g" "$label" "$s" >>"$work/human.txt" <<'PY'
import sys
p, label, sock = sys.argv[1], sys.argv[2], sys.argv[3].encode()
out = open(p + '.out', 'rb').read().replace(sock, b'<SOCK>')
err = open(p + '.err', 'rb').read().replace(sock, b'<SOCK>')
rc = open(p + '.rc').read()
sys.stdout.buffer.write(b'=== %s\nrc=%s\n--- stdout %d bytes\n' % (label.encode(), rc.encode(), len(out))
                        + out + b'\n--- stderr %d bytes\n' % len(err) + err + b'\n')
PY
}

# jv NAME PYEXPR -> NAME.out must be exactly ONE line of strict-UTF-8 JSON and
# nothing else; prints PYEXPR evaluated with the document bound to d.
jv() {
  python3 - "$work/$1.out" "$2" <<'PY'
import sys, json
raw = open(sys.argv[1], 'rb').read()
if not raw.endswith(b'\n') or raw.count(b'\n') != 1:
    print('NOT ONE LINE: %r' % raw[:200]); sys.exit()
try:
    text = raw[:-1].decode('utf-8')
    d = json.loads(text)
except Exception as e:
    print('INVALID: %s %r' % (e, raw[:200])); sys.exit()
if any(ord(c) < 0x20 or c == '\x7f' for c in text):
    print('RAW CONTROL BYTE: %r' % text[:200]); sys.exit()
print(eval(sys.argv[2]))
PY
}
# canon JSON -> the same document with sorted keys, for an equality that prints
# both sides on failure.
canon() { python3 -c 'import sys, json; print(json.dumps(json.loads(sys.argv[1]), sort_keys=True))' "$1"; }
doc_is() { assert_eq "$(jv "$1" 'json.dumps(d, sort_keys=True)')" "$(canon "$2")" "$3"; }

# --- the fleet ------------------------------------------------------------------

gold 'status, no server' "$ROOST" status
cap st0 "$ROOST" status --json

cat >"$work/show.sh" <<'EOF'
printf 'screen-line-one\nscreen-line-two\n'
exec sleep 600
EOF
# Every pane runs a known command, so #{pane_current_command} is `sleep` on
# every platform (tests/lib.sh explains why a shell's name is not portable).
T -f /dev/null new-session -d -s main -n api -x 200 -y 50 "sh $work/show.sh"
T set -g @roost-notify-backend none
T new-window -t main: -n web "sh $work/show.sh"
T split-window -t main:web "sh $work/show.sh"
T new-session -d -s side -n ops "sh $work/show.sh"
T new-window -t side: -n blank 'exec sleep 600'
spid="$(T display -p '#{pid}')"
panes="$(T list-panes -a -F '#{pane_id}' | tr '\n' ' ')"
assert_eq "$panes" "%0 %1 %2 %3 %4 " "the test fleet has the five panes every expectation below names"
for p in %0 %1 %2 %3; do
  i=0
  while [ "$i" -lt 40 ] && ! T capture-pane -p -t "$p" | grep -q screen-line-two; do sleep 0.1; i=$((i + 1)); done
done
T set -p -t %2 @roost-name helper
T set -p -t %0 @agent_state done;    T set -p -t %0 @agent_since 1789000000
T set -p -t %1 @agent_state working; T set -p -t %1 @agent_since 1789000100
T set -p -t %3 @agent_state error;   T set -p -t %3 @agent_since 1789000200
T set -p -t %3 @roost-error-reason rate_limit
as_pane %0 "$ROOST" reply "hello from api"
as_pane %1 "$ROOST" reply "old reply from web"

# --- 1. human output, unchanged -------------------------------------------------

gold 'status' "$ROOST" status
gold 'status bogus (extra words are ignored)' "$ROOST" status bogus
gold 'whoami in %1' as_pane %1 "$ROOST" whoami
gold 'whoami outside a pane' "$ROOST" whoami
gold 'whoami with TMUX_PANE=%99' env TMUX_PANE=%99 "$ROOST" whoami
gold 'read %0 (reply)' "$ROOST" read %0
gold 'read main:api (reply, by name)' "$ROOST" read main:api
gold 'read %1 (stale reply)' "$ROOST" read %1
gold 'read %2 (screen fallback)' "$ROOST" read %2
gold 'read %3 (error fallback)' "$ROOST" read %3
gold 'read %4 (blank screen)' "$ROOST" read %4
gold 'read %99 (no such pane)' "$ROOST" read %99
gold 'read --bogus %0' "$ROOST" read --bogus %0
gold 'read -r -r %0 (repeated flag)' "$ROOST" read -r -r %0
gold 'read --render --bogus %0' "$ROOST" read --render --bogus %0
gold 'read -r -5 %0 (a count before the target)' "$ROOST" read -r -5 %0
gold 'read %0 --json (a flag after the target)' "$ROOST" read %0 --json
gold 'screen %0 3' "$ROOST" screen %0 3
gold 'screen %0' "$ROOST" screen %0
gold 'screen %4 (blank screen)' "$ROOST" screen %4
gold 'screen %99 (no such pane)' "$ROOST" screen %99
gold 'screen -5' "$ROOST" screen -5
gold 'screen %0 --json (a flag after the target)' "$ROOST" screen %0 --json

# --- 2. the documents -----------------------------------------------------------

doc_is st0 "{\"schema\":1,\"command\":\"status\",\"running\":false,\"socket\":\"$s\",\"socket_kind\":\"path\",\"sessions\":[],\"panes\":[]}" \
  "status --json with no server is a valid empty document"
assert_eq "$(rc st0)" 0 "status --json with no server exits 0, as the human mode does"

status_doc() {
  printf '{"schema":1,"command":"status","running":true,"socket":"%s","socket_kind":"path",' "$s"
  printf '"sessions":[{"name":"main","windows":2,"attached_clients":0},{"name":"side","windows":2,"attached_clients":0}],'
  printf '"panes":['
  printf '{"id":"%%0","session":"main","window_id":"@0","window_index":0,"window_name":"api","pane_index":0,"name":null,"command":"sleep","state":"done","since":1789000000},'
  printf '{"id":"%%1","session":"main","window_id":"@1","window_index":1,"window_name":"web","pane_index":0,"name":null,"command":"sleep","state":"working","since":1789000100},'
  printf '{"id":"%%2","session":"main","window_id":"@1","window_index":1,"window_name":"web","pane_index":1,"name":%s,"command":"sleep","state":null,"since":null},' "$1"
  printf '{"id":"%%3","session":"side","window_id":"@2","window_index":0,"window_name":"ops","pane_index":0,"name":null,"command":"sleep","state":"error","since":1789000200},'
  printf '{"id":"%%4","session":"side","window_id":"@3","window_index":1,"window_name":"blank","pane_index":0,"name":null,"command":"sleep","state":null,"since":null}'
  printf ']}'
}
cap st "$ROOST" status --json
doc_is st "$(status_doc '"helper"')" "status --json carries every session and pane with raw values"
assert_eq "$(rc st)" 0 "status --json exits 0"
assert_eq "$(cat "$work/st.err")" "" "status --json writes nothing to stderr"
assert_eq "$(jv st 'list(d)[:2]')" "['schema', 'command']" "schema and command are the first two keys"

cap wh as_pane %1 "$ROOST" whoami --json
doc_is wh '{"schema":1,"command":"whoami","pane":"%1"}' "whoami --json names the caller's pane"
cap wh_h "$ROOST" whoami
cap wh_j "$ROOST" whoami --json
assert_eq "$(rc wh_j)" "$(rc wh_h)" "whoami --json outside a pane keeps the human exit status"
assert_eq "$(cat "$work/wh_j.out")" "" "whoami --json outside a pane prints nothing on stdout"
assert_eq "$(cat "$work/wh_j.err")" "$(cat "$work/wh_h.err")" "whoami --json outside a pane keeps the human stderr"

# read: the JSON document, and stderr byte-identical to the human invocation.
read_case() {  # read_case NAME TARGET EXPECTED-JSON LABEL
  cap "$1" "$ROOST" read --json "$2"
  cap "$1_h" "$ROOST" read "$2"
  doc_is "$1" "$3" "$4"
  cmp -s "$work/$1.err" "$work/$1_h.err"; assert_true $? "$4: stderr is byte-identical to the human mode"
}
read_case r0 %0 '{"schema":1,"command":"read","target":"%0","pane":"%0","source":"reply","state":"done","stale":false,"error_reason":null,"text":"hello from api","lossy":false}' \
  "read --json returns a recorded reply"
assert_eq "$(rc r0)" 0 "read --json on a reply exits 0"
read_case rn main:api '{"schema":1,"command":"read","target":"main:api","pane":"%0","source":"reply","state":"done","stale":false,"error_reason":null,"text":"hello from api","lossy":false}' \
  "read --json keeps the target as typed and resolves the pane"
read_case r1 %1 '{"schema":1,"command":"read","target":"%1","pane":"%1","source":"reply","state":"working","stale":true,"error_reason":null,"text":"old reply from web","lossy":false}' \
  "read --json marks a reply on a working pane stale"
read_case r2 %2 '{"schema":1,"command":"read","target":"%2","pane":"%2","source":"screen","state":null,"stale":false,"error_reason":null,"text":"screen-line-one\nscreen-line-two","lossy":false}' \
  "read --json falls back to the screen and says so in source"
assert_eq "$(jv r2 'd["text"]')" "$(cat "$work/r2_h.out")" "read --json screen text is the human stdout without its final newline"
read_case r3 %3 '{"schema":1,"command":"read","target":"%3","pane":"%3","source":"screen","state":"error","stale":false,"error_reason":"rate_limit","text":"screen-line-one\nscreen-line-two","lossy":false}' \
  "read --json carries an errored pane's recorded reason"
read_case r4 %4 '{"schema":1,"command":"read","target":"%4","pane":"%4","source":"screen","state":null,"stale":false,"error_reason":null,"text":"","lossy":false}' \
  "read --json on a blank screen is a valid empty document"
assert_eq "$(rc r4)" 0 "read --json on a blank screen exits 0 (the human mode's exit 1 is a separate bug)"
# A reply stored on an ERRORED pane is stale too: every adapter drops the reply
# of a failed turn, so whatever is stored is an earlier turn's. The human mode
# says so on stderr; `stale` must say the same, and the reason must come along.
as_pane %3 "$ROOST" reply "an earlier turn's answer"
read_case r3r %3 '{"schema":1,"command":"read","target":"%3","pane":"%3","source":"reply","state":"error","stale":true,"error_reason":"rate_limit","text":"an earlier turn'"'"'s answer","lossy":false}' \
  "read --json marks a reply on an errored pane stale and carries the reason"
T set-option -pu -t %3 @roost-reply
cap r99 "$ROOST" read --json %99
cap r99_h "$ROOST" read %99
assert_eq "$(rc r99)" "$(rc r99_h)" "read --json on a missing pane keeps the human exit status"
assert_eq "$(wc -c <"$work/r99.out" | tr -d ' ')" 0 "read --json on a missing pane prints nothing on stdout"
cmp -s "$work/r99.err" "$work/r99_h.err"; assert_true $? "read --json on a missing pane keeps the human stderr"

for combo in "--json -r" "-r --json" "--json --render" "--json --json"; do
  # shellcheck disable=SC2086
  cap rc_combo "$ROOST" read $combo %0
  assert_eq "$(rc rc_combo)" 1 "read $combo is a usage error, exit 1"
  assert_eq "$(wc -c <"$work/rc_combo.out" | tr -d ' ')" 0 "read $combo prints nothing on stdout"
done
cap rc_combo "$ROOST" read --json -r %0
assert_contains "$(cat "$work/rc_combo.err")" "cannot be combined" "read --json -r says why it refused"

cap sc "$ROOST" screen --json %0 3
cap sc_h "$ROOST" screen %0 3
doc_is sc '{"schema":1,"command":"screen","target":"%0","pane":"%0","lines":3,"text":"screen-line-one\nscreen-line-two","lossy":false}' \
  "screen --json returns the screen lines"
assert_eq "$(jv sc 'd["text"]')" "$(cat "$work/sc_h.out")" "screen --json text is the human stdout without its final newline"
cap scn "$ROOST" screen --json %0 -3
assert_eq "$(jv scn 'd["lines"]')" 3 "screen --json reports a negative LINES as its count"
cap sc4 "$ROOST" screen --json %4
doc_is sc4 '{"schema":1,"command":"screen","target":"%4","pane":"%4","lines":40,"text":"","lossy":false}' \
  "screen --json on a blank screen is a valid empty document"
assert_eq "$(rc sc4)" 0 "screen --json on a blank screen exits 0"
cap sc99 "$ROOST" screen --json %99
cap sc99_h "$ROOST" screen %99
assert_eq "$(rc sc99)" "$(rc sc99_h)" "screen --json on a missing pane keeps the human exit status"
assert_eq "$(wc -c <"$work/sc99.out" | tr -d ' ')" 0 "screen --json on a missing pane prints nothing on stdout"
cmp -s "$work/sc99.err" "$work/sc99_h.err"; assert_true $? "screen --json on a missing pane keeps the human stderr"
cap scjj "$ROOST" screen --json --json %0
assert_eq "$(rc scjj)" 1 "screen --json --json is a usage error"
assert_eq "$(wc -c <"$work/scjj.out" | tr -d ' ')" 0 "screen --json --json prints nothing on stdout"
assert_contains "$(cat "$work/scjj.err")" "--json may be given once, before the target" "screen --json --json says why it refused"
cap scja "$ROOST" screen --json %0 --json
assert_eq "$(rc scja)" 1 "screen --json TGT --json is a usage error"
assert_contains "$(cat "$work/scja.err")" "--json goes before the target, once" "screen --json TGT --json names where the flag goes"
cap sc7 "$ROOST" screen --json %0 007
assert_eq "$(jv sc7 'd["lines"]')" 7 "screen --json reports a count with leading zeros as that count"
cap sc00 "$ROOST" screen --json %0 00
assert_eq "$(jv sc00 'd["lines"]')" 0 "screen --json reports a count of all zeros as 0"
cap scp "$ROOST" screen --json %0 +3
assert_eq "$(jv scp 'd["lines"]')" None "screen --json reports a non-count LINES such as +3 as null"

# --- 3. pathological bytes ------------------------------------------------------

# Does THIS tmux server store client-sent bytes as escape text? Measured:
# tmux 3.4 and 3.5a turn control bytes, DEL and invalid UTF-8 in any argument a
# client sends into `\ooo` / `\a \b \v \f \r` -- WITHOUT escaping a backslash, so
# the ESC byte and the literal text `\033` are stored identically and cannot be
# told apart afterwards. tmux 3.6 and 3.7c store the bytes. The test asks the
# server itself, independently of roost's own check, and says which it found.
tmux_escapes=0
if [ "$(T display-message -p $'\x01')" = '\001' ]; then tmux_escapes=1; fi
printf '  NOTE: %s; stores client-sent control bytes as escape text: %s; UTF-8 locale: %s\n' \
  "$(tmux -V)" "$tmux_escapes" "${json_utf8:-none}"

# rt_check NAME RAWFILE FIELD [STOREDFILE] -> "ok", or what differed.
#
# FIELD text: on a server that stores bytes, the expectation is Python's own
# replacement decode of the exact bytes that went in. On an escaping server the
# bytes are gone before roost ever reads them, so the expectation is what tmux
# STORED (STOREDFILE), exactly as human `roost read` prints it -- and the
# document must say lossy whenever that stored text holds an escape sequence
# tmux writes, or invalid UTF-8. The regex here is the test's own, not roost's.
rt_check() {
  python3 - "$work/$1.out" "$2" "$3" "${4:-}" "$tmux_escapes" <<'PY'
import sys, json, re
out, rawf, field, storedf, escapes = sys.argv[1:6]
b = open(out, 'rb').read()
try:
    d = json.loads(b.decode('utf-8'))
except Exception as e:
    print('INVALID %s %r' % (e, b[:120])); sys.exit()
raw = open(rawf, 'rb').read()
if field == 'text' and escapes == '1':
    raw = open(storedf, 'rb').read()
try:
    want, lossy = raw.decode('utf-8'), False
except UnicodeDecodeError:
    want, lossy = raw.decode('utf-8', 'replace'), True
if field == 'text' and escapes == '1' and re.search(rb'\\([0-7]{3}|[abfrv])', raw):
    lossy = True
if field == 'text':
    got, got_lossy = d['text'], d['lossy']
else:
    p = [x for x in d['panes'] if x['id'] == '%2']
    if len(p) != 1 or [x['id'] for x in d['panes']] != ['%0', '%1', '%2', '%3', '%4']:
        print('PANES WRONG %r' % [x['id'] for x in d['panes']]); sys.exit()
    got, got_lossy, lossy = p[0]['name'], None, None
    want = want if want else None
print('ok' if (got, got_lossy) == (want, lossy) else 'got %r lossy=%r want %r lossy=%r' % (got, got_lossy, want, lossy))
PY
}
corpus=(
  'quote " and \ backslash'
  $'a tab\tand nothing else'
  $'line one\nline two\ttab\rcarriage'
  $'ctl \x01 bs \x08 ff \x0c esc \x1b[31mred\x1b[0m us \x1f del \x7f'
  $'emoji \xf0\x9f\x90\x93 combining e\xcc\x81 separator \xe2\x80\xa8 cjk \xe4\xb8\xad'
  '\u0041 and \n are literal text here'
  'return 0;'
  $'bad \xff lone-lead \xc3 overlong \xc0\xaf surrogate \xed\xa0\x80 lone-cont \x80 end'
  $'ends mid-sequence \xe2\x82'
  '{"a": [1, "two"]}'
  'printf "\033[31m" is literal text, not an ESC byte'
)
k=0
for val in "${corpus[@]}"; do
  printf '%s' "$val" >"$work/raw$k"
  label="$(printf '%s' "$val" | LC_ALL=C tr -c '[:print:]' '?' | cut -c1-40)"
  as_pane %0 "$ROOST" reply "$val"
  printf '%s' "$(T show-options -p -t %0 -qv @roost-reply)" >"$work/rawr$k"
  cap rt with_utf8 "$ROOST" read --json %0
  assert_eq "$(rt_check rt "$work/raw$k" text "$work/rawr$k")" ok "reply round trip through read --json: $label"
  T set -p -t %2 @roost-name "$val"
  # The expectation is what tmux STORED, read back pane-scoped, not what was
  # typed. A raw `tmux set -p` goes through tmux's command parser, which eats a
  # trailing `;` (scripts/lib/roost-reply.sh escapes it for the reply channel;
  # nothing escapes it here, because this line is the test, not roost). No value
  # in the corpus ends in a newline, so $(...) strips nothing that matters.
  printf '%s' "$(T show-options -p -t %2 -qv @roost-name)" >"$work/rawn$k"
  cap nt with_utf8 "$ROOST" status --json
  assert_eq "$(rt_check nt "$work/rawn$k" name)" ok "pane name round trip through status --json: $label"
  k=$((k + 1))
done

# A name that contains the tabs and newlines of a whole second record. Accepted
# at face value by a delimiter split, it would add a pane that does not exist.
forged=$'x\n%0\tmain\t@0\t0\tapi\t0\tdone\t1\tsleep\tforged'
printf '%s' "$forged" >"$work/rawf"
T set -p -t %2 @roost-name "$forged"
cap nf with_utf8 "$ROOST" status --json
assert_eq "$(rt_check nf "$work/rawf" name)" ok "a name forging a second pane record is reported as one name on one pane"
T set -p -t %2 @roost-name helper
cap st2 "$ROOST" status --json
doc_is st2 "$(status_doc '"helper"')" "status --json is exact again once the hostile name is gone"

# NUL cannot reach a document at all: bash drops it from a value before roost
# is handed that value. Pinned so that a change of shell is noticed.
{ nulval="$(printf 'x\0y')"; } 2>/dev/null
as_pane %0 "$ROOST" reply "$nulval"
cap nul "$ROOST" read --json %0
assert_eq "$(jv nul 'd["text"]')" "xy" "a NUL given to roost reply never reaches read --json: the shell drops it first"

# --- 4. the encoder, fuzzed -----------------------------------------------------

# Skipped while recapturing the golden file: that runs against a pre-change
# tree, which has no roost-jsonout.sh to source (see the note at the bottom).
if [ -z "${ROOST_JSON_WRITE_GOLDEN:-}" ]; then
. "$HERE/scripts/lib/roost-jsonout.sh"
# The encoder is fuzzed from a UTF-8 locale when the machine has one, because
# that is where bash 5 miscounts and rewrites bytes (roost_jsonout_encode's
# comment). From the C locale, dropping the encoder's own `local LC_ALL=C` would
# stay green. Scoped to this section with a subshell-free save and restore.
fz_saved_lc="${LC_ALL-}"
fz_utf8="$json_utf8"
if [ -n "$fz_utf8" ]; then
  export LC_ALL="$fz_utf8"
elif [ -n "${CI:-}" ]; then
  # On CI a quietly weaker fuzz is the same failure as a missing oracle.
  assert_true 1 "CI has a UTF-8 locale for the encoder fuzz (locale -a found none)"
else
  printf '  NOTE: no UTF-8 locale on this machine; the encoder fuzz runs in the current locale\n'
fi
{ nulval="$(printf 'a\0b')"; } 2>/dev/null
roost_jsonout_encode "$nulval" ""
assert_eq "${ROOST_JSONOUT_STR[0]}|${ROOST_JSONOUT_STR[1]}|$ROOST_JSONOUT_LOSSY" '"ab"|""|00' \
  "the encoder is handed a NUL-free value and an empty value, and frames both"

python3 - "$work/fz" <<'PY'
import os, random, sys
d = sys.argv[1]; random.seed(41)
cases = [bytes([b]) for b in range(1, 256)]
cases += [b'', b'\n', b'\n\n', b'x\n', b'12:34', b'0:', b':', b'\xc0\xaf', b'\xed\xa0\x80', b'\xe2\x82', b'\xe2\x82(',
          b'\xf4\x90\x80\x80', b'\xf4\x8f\xbf\xbf', b'\xf0\x9f\x90', b'\xff\xfe', b'\xc3\x22', b'x\xc3', b'\xe0\xa0\x80']
pieces = [b'a', b'"', b'\\', b'\n', b'\t', b'\x01', b'\x7f', b'\x1f', b'\x80', b'\xbf', b'\xc2', b'\xdf', b'\xe0', b'\xed',
          b'\xef', b'\xf0', b'\xf4', b'\xf5', b'\xff', 'é'.encode(), '\U0001f413'.encode(), '中'.encode(),
          b'\xed\x9f\xbf', b'\xee\x80\x80', b' ', b';', b':', b'7', b'abc def']
for _ in range(600):
    cases.append(b''.join(random.choice(pieces) for _ in range(random.randint(0, 24))))
g = i = 0
while i < len(cases):
    k = random.randint(1, 8); os.makedirs('%s/in/%05d' % (d, g))
    for j, c in enumerate(cases[i:i + k]):
        open('%s/in/%05d/%d' % (d, g, j), 'wb').write(c)
    i += k; g += 1
os.makedirs(d + '/out')
PY
# Values are loaded with $(cat) under LC_ALL=C, never with `read -d ''`: see the
# two bash 5 traps in roost_jsonout_encode's comment.
fz_load() { local LC_ALL=C; fzv="$(cat "$1"; printf x)"; fzv="${fzv%x}"; }
for gdir in "$work"/fz/in/*; do
  vals=(); j=0
  while [ -f "$gdir/$j" ]; do fz_load "$gdir/$j"; vals[j]="$fzv"; j=$((j + 1)); done
  if roost_jsonout_encode "${vals[@]}"; then
    { printf '%s\n' "${ROOST_JSONOUT_STR[@]}"; printf '%s' "$ROOST_JSONOUT_LOSSY"; } >"$work/fz/out/${gdir##*/}"
  else
    printf 'ENCODE FAILED' >"$work/fz/out/${gdir##*/}"
  fi
done
fuzz="$(python3 - "$work/fz" <<'PY'
import json, os, sys
w = sys.argv[1]; bad = []; n = 0
for g in sorted(os.listdir(w + '/in')):
    raws = [open('%s/in/%s/%d' % (w, g, j), 'rb').read() for j in range(len(os.listdir('%s/in/%s' % (w, g))))]
    res = open('%s/out/%s' % (w, g), 'rb').read().split(b'\n')
    encs, flags = res[:-1], res[-1].decode('ascii', 'replace')
    if len(encs) != len(raws) or len(flags) != len(raws):
        bad.append('framing %s' % g); continue
    for raw, enc, fl in zip(raws, encs, flags):
        n += 1
        try:
            text = enc.decode('utf-8'); got = json.loads(text)
        except Exception as e:
            bad.append('invalid %r -> %r' % (raw, enc)); continue
        try:
            want, wl = raw.decode('utf-8'), '0'
        except UnicodeDecodeError:
            want, wl = raw.decode('utf-8', 'replace'), '1'
        if any(ord(c) < 0x20 or c == '\x7f' for c in text) or not (text.startswith('"') and text.endswith('"')):
            bad.append('raw control or unquoted %r -> %r' % (raw, enc))
        elif got != want or fl != wl:
            bad.append('%r -> %r (lossy %s, want %s)' % (raw, enc, fl, wl))
print('%d values, %d failures%s' % (n, len(bad), (': ' + '; '.join(bad[:3])) if bad else ''))
PY
)"
assert_prefix "$fuzz" "873 values, 0 failures" "the encoder round-trips every single byte and 600 random mixtures"
if [ -n "$fz_saved_lc" ]; then export LC_ALL="$fz_saved_lc"; else unset LC_ALL; fi

# A frame whose length is wrong must FAIL, and fail at once. The first encoder
# looped forever on one, and a hung awk hangs the roost command above it. Each
# case runs under a 5-second watchdog, so a regression is a FAIL line and not a
# suite that never finishes.
for bad in '9:abcx' 'ab:x' '3:abc2x' '2:a'; do
  printf '%s' "$bad" | LC_ALL=C awk "$ROOST_JSONOUT_AWK" >/dev/null 2>&1 &
  fz_pid=$!
  ( sleep 5; kill "$fz_pid" 2>/dev/null ) &
  fz_dog=$!
  wait "$fz_pid"; fz_rc=$?
  kill "$fz_dog" 2>/dev/null; wait "$fz_dog" 2>/dev/null
  # 143 is SIGTERM from the watchdog: the hang this exists to catch.
  if [ "$fz_rc" -ne 0 ] && [ "$fz_rc" -ne 143 ]; then fz_ok=0; else fz_ok=1; fi
  assert_true "$fz_ok" "a malformed frame ('$bad') makes the encoder exit non-zero promptly (rc $fz_rc)"
done
fi

# --- state ----------------------------------------------------------------------

gold 'state working in %2' as_pane %2 "$ROOST" state working
gold 'state --json in %2 (flag first: sets idle, as before)' as_pane %2 "$ROOST" state --json
assert_eq "$(T show -pqv -t %2 @agent_state)" idle "state --json with the flag FIRST still sets idle and prints nothing"
gold 'state bogus in %2' as_pane %2 "$ROOST" state bogus
gold 'state done outside a pane' "$ROOST" state done

as_pane %2 "$ROOST" state working
cap sj as_pane %2 "$ROOST" state bogus --json
doc_is sj '{"schema":1,"command":"state","requested":"bogus","state":"idle","pane":"%2","recorded":true}' \
  "state STATE --json sets the badge and echoes what was recorded"
assert_eq "$(T show -pqv -t %2 @agent_state)" idle "state bogus --json really set the badge"
cap sjd as_pane %2 "$ROOST" state done --json
doc_is sjd '{"schema":1,"command":"state","requested":"done","state":"done","pane":"%2","recorded":true}' \
  "state done --json echoes done"
# The case `recorded` exists for: a caller that looks like a roost pane, on
# this server, whose badge still went nowhere -- here, a pane id that does not
# exist. Nothing must claim it landed.
cap s99 as_pane %99 "$ROOST" state done --json
doc_is s99 '{"schema":1,"command":"state","requested":"done","state":null,"pane":"%99","recorded":false}' \
  "state --json says recorded:false when the badge did not land"
cap so "$ROOST" state done --json
doc_is so '{"schema":1,"command":"state","requested":"done","state":null,"pane":null,"recorded":false}' \
  "state --json outside a roost pane says nothing was recorded"
assert_eq "$(rc so)" 0 "state --json outside a roost pane exits 0, as the silent no-op always has"

# --- the golden comparison ------------------------------------------------------

# ROOST_JSON_WRITE_GOLDEN=1 rewrites the fixture instead of comparing. Use it
# ONLY on a tree whose human output is known to be right, and never to make a
# change to human output pass. A regenerated fixture is a reviewed diff.
#
# The fixture is captured from the commit BEFORE --json existed: export that
# commit to a scratch directory (`git archive`), copy this file and
# tests/fixtures/ into it, and run it there with ROOST_JSON_WRITE_GOLDEN=1. The
# JSON assertions FAIL in that tree, which is expected -- the command it has
# never heard of --json -- and section 4 is skipped because the library is not
# there. Copy the fixture back and review the diff.
if [ -n "${ROOST_JSON_WRITE_GOLDEN:-}" ]; then
  cp "$work/human.txt" "$GOLDEN"
  printf '  NOTE: wrote %s\n' "tests/fixtures/json-human-output.txt"
elif cmp -s "$work/human.txt" "$GOLDEN"; then
  assert_true 0 "every human invocation is byte-identical to the pre---json capture"
else
  assert_true 1 "every human invocation is byte-identical to the pre---json capture"
  diff "$GOLDEN" "$work/human.txt" | head -40
fi
