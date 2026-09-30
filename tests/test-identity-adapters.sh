#!/usr/bin/env bash
# The node adapters' half of #141: opencode, copilot and pi each call
# `roost identify` at their session start, with a recording shim standing in
# for roost on PATH. Offline, no model call, no harness installed. What
# `roost identify` then does with the values is tests/test-identity.sh.
#
# Gated on node the way tests/test-pi-extension.sh is.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
if ! command -v node >/dev/null 2>&1; then
  echo "  SKIP: node not found — adapter identity tests skipped"
  exit 0
fi

dir="$(mktemp -d /tmp/amx.XXXX)"
trap 'rm -rf "$dir"' EXIT
# One line per call: every argument, joined by `|`. None of the fixtures below
# holds a `|`, so the join is unambiguous.
cat > "$dir/roost" <<EOF
#!/bin/sh
cat > /dev/null
out=""
for a in "\$@"; do out="\$out|\$a"; done
printf '%s\n' "\${out#|}" >> "$dir/calls"
EOF
chmod +x "$dir/roost"
calls() { grep '^identify' "$dir/calls" 2>/dev/null || true; }
verbs() { cut -d'|' -f1 "$dir/calls" 2>/dev/null | paste -sd, - || true; }
drive() { : > "$dir/calls"; PATH="$dir:$PATH" node --input-type=module -e "$1" 2>"$dir/err" || cat "$dir/err"; }

printf '\n== opencode ==\n'
drive "
const { RoostState } = await import('$HERE/adapters/opencode/roost.js')
const h = await RoostState({ directory: '/w/oc', client: {} })
const ev = (event) => h.event({ event })
await ev({ type: 'session.status', properties: { sessionID: 'ses_root1', status: { type: 'busy' } } })
await ev({ type: 'session.status', properties: { sessionID: 'ses_root1', status: { type: 'busy' } } })
await ev({ type: 'session.idle', properties: { sessionID: 'ses_root1' } })
"
assert_eq "$(calls)" "identify|--session|ses_root1|--cwd|/w/oc|--harness|opencode" \
  "opencode identifies its session once, from the first event that names it"
assert_eq "$(verbs)" "identify,state,state" "opencode identifies before it badges"

drive "
const { RoostState } = await import('$HERE/adapters/opencode/roost.js')
const h = await RoostState({ directory: '/w/oc', client: {} })
const ev = (event) => h.event({ event })
await ev({ type: 'session.status', properties: { sessionID: 'ses_root1', status: { type: 'busy' } } })
await ev({ type: 'session.created', properties: { info: { id: 'ses_child', parentID: 'ses_root1' } } })
await ev({ type: 'session.status', properties: { sessionID: 'ses_child', status: { type: 'busy' } } })
await ev({ type: 'session.idle', properties: { sessionID: 'ses_child' } })
await ev({ type: 'session.idle', properties: { sessionID: 'ses_root1' } })
await ev({ type: 'session.status', properties: { sessionID: 'ses_root2', status: { type: 'busy' } } })
"
assert_eq "$(calls | cut -d'|' -f3 | paste -sd, -)" "ses_root1,ses_root2" \
  "a subagent's child session is never the pane's identity, and a new root session replaces the old"

drive "
const { RoostState } = await import('$HERE/adapters/opencode/roost.js')
const h = await RoostState()
await h.event({ event: { type: 'session.status', properties: { sessionID: 'ses_x', status: { type: 'busy' } } } })
"
assert_eq "$(calls)" "" "with no directory to report, opencode identifies nothing (and still badges)"
assert_eq "$(verbs)" "state" "(control) that instance did badge"

printf '\n== copilot ==\n'
drive "
process.chdir('$dir')
const { identifySession } = await import('$HERE/adapters/copilot/extension.mjs')
await identifySession({ sessionId: 'cp-1234-abcd' })
await identifySession({})
await identifySession(undefined)
"
real_dir="$(cd -P "$dir" && pwd)"
assert_eq "$(calls)" "identify|--session|cp-1234-abcd|--cwd|$real_dir|--harness|copilot" \
  "copilot identifies the session it joined, once, and a session with no id is skipped"

printf '\n== pi ==\n'
drive "
const mod = await import('$HERE/adapters/pi/roost.ts')
const on = {}
mod.default({ on: (name, fn) => { on[name] = fn } })
const sm = (id, file) => ({ getSessionId: () => id, getSessionFile: () => file })
await on.session_start({ reason: 'startup' }, { hasUI: true, ui: {}, cwd: '/w/pi', sessionManager: sm('pi-1', '/w/.pi/sessions/pi-1.jsonl') })
await on.session_start({ reason: 'new' }, { hasUI: true, ui: {}, cwd: '/w/pi', sessionManager: sm('pi-2', undefined) })
await on.session_start({ reason: 'startup' }, { hasUI: false, ui: {}, cwd: '/w/pi', sessionManager: sm('pi-child', '/w/c.jsonl') })
"
# node strips a .ts file's types on import from 22.18 on; before that the
# import itself fails, and that one cause is a SKIP, as in
# tests/pi-extension-harness.mjs.
if grep -qE 'ERR_UNKNOWN_FILE_EXTENSION|strip-types|Unknown file extension' "$dir/err" 2>/dev/null; then
  printf '  SKIP: node %s cannot import a .ts file — pi identity tests skipped (needs node >= 22.18)\n' "$(node --version)"
  exit 0
fi
assert_eq "$(calls | sed -n 1p)" "identify|--session|pi-1|--cwd|/w/pi|--harness|pi|--transcript|/w/.pi/sessions/pi-1.jsonl" \
  "pi identifies its session, directory and session file at session_start"
assert_eq "$(calls | sed -n 2p)" "identify|--session|pi-2|--cwd|/w/pi|--harness|pi" \
  "a /new session is identified again, and an ephemeral one has no transcript"
assert_eq "$(calls | wc -l | tr -d ' ')" "2" "a pi with no UI (a spawned worker) identifies nothing"
