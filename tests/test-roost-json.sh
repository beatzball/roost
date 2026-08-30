#!/usr/bin/env bash
# tests/test-roost-json.sh — scripts/lib/roost-json.sh: atomic, backed-up
# JSON merges that degrade honestly when no JSON tool is on PATH.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/scripts/lib/roost-json.sh"

# hide_json_tools -- run "$@" with a PATH that carries every external command
# roost-json.sh and this test need, but neither python3 nor jq. Not a
# $PATH-prepend (tests/test-doctor.sh's noroostdir note explains why: this
# machine's real PATH has a real python3 and/or jq on it, and prepending
# would never exercise the "neither present" branch). Instead build a
# dedicated directory of symlinks to the real binaries this file actually
# calls, and set PATH to exactly that directory.
hide_json_tools() {
  local shim
  shim="$(mktemp -d /tmp/amx.XXXX)"
  local bin
  for bin in bash sh cat cp mv rm mkdir mktemp dirname cmp date grep sed diff env printf true false; do
    local real
    real="$(command -v "$bin" 2>/dev/null)" || continue
    ln -s "$real" "$shim/$bin"
  done
  PATH="$shim" "$@"
  local rc=$?
  rm -rf "$shim"
  return $rc
}

# --- roost_json_tool ---

case "$(roost_json_tool)" in
  python3|jq) assert_eq ok ok "roost_json_tool reports a real tool when one is present" ;;
  *) assert_eq "$(roost_json_tool)" "python3 or jq" "roost_json_tool reports a real tool when one is present" ;;
esac

out="$(hide_json_tools bash -c '. "'"$HERE"'/scripts/lib/roost-json.sh"; roost_json_tool')"
assert_eq "$out" "" "roost_json_tool prints nothing when neither tool is on PATH"

# --- shared fixture ---

mkfixture() {
  # mkfixture DIR -- writes settings.json with an unrelated top-level key and
  # an unrelated hook, so a merge that clobbers either is caught.
  cat > "$1/settings.json" <<'JSON'
{
  "unrelatedTopLevelKey": "keep-me",
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "echo unrelated-hook" } ] }
    ]
  }
}
JSON
}

run_case() {
  # run_case TOOLNAME -- exercises the full case list once under a PATH that
  # exposes ONLY that JSON tool (plus the other externals roost-json.sh and
  # this test need), so python3 and jq are each proven to work on their own,
  # not just whichever one this machine prefers.
  local tool="$1" shim d
  shim="$(mktemp -d /tmp/amx.XXXX)"
  local bin
  for bin in bash sh cat cp mv rm mkdir mktemp dirname cmp date grep sed diff env printf true false "$tool"; do
    local real
    real="$(command -v "$bin" 2>/dev/null)" || continue
    ln -s "$real" "$shim/$bin" 2>/dev/null
  done

  d="$(mktemp -d /tmp/amx.XXXX)"
  mkfixture "$d"
  local before after
  before="$(cat "$d/settings.json")"

  PATH="$shim" bash -c '. "'"$HERE"'/scripts/lib/roost-json.sh"; roost_json_merge "'"$d"'/settings.json" claude-hooks "/checkout/scripts/roost-agent-state"' >"$d/merge1.out" 2>"$d/merge1.err"
  local rc=$?
  assert_eq "$rc" "0" "[$tool] merge exits 0"

  after="$(cat "$d/settings.json")"
  assert_contains "$after" "keep-me" "[$tool] unrelated top-level key survives the merge"
  assert_contains "$after" "echo unrelated-hook" "[$tool] unrelated hook survives the merge"
  assert_contains "$after" "/checkout/scripts/roost-agent-state working" "[$tool] roost's hook entry was added"

  local bak
  bak="$(ls "$d"/settings.json.roost-bak-* 2>/dev/null | head -1)"
  [ -n "$bak" ] && assert_eq "$(cat "$bak")" "$before" "[$tool] backup holds the pre-merge bytes"
  [ -n "$bak" ] || assert_eq "backup" "no backup" "[$tool] a backup was created for the first write"

  # idempotent: merging again with the same args changes nothing further.
  cp "$d/settings.json" "$d/after-first.json"
  rm -f "$d"/settings.json.roost-bak-*
  PATH="$shim" bash -c '. "'"$HERE"'/scripts/lib/roost-json.sh"; roost_json_merge "'"$d"'/settings.json" claude-hooks "/checkout/scripts/roost-agent-state"' >"$d/merge2.out" 2>"$d/merge2.err"
  rc=$?
  assert_eq "$rc" "0" "[$tool] second merge exits 0"
  assert_eq "ok" "$(cmp -s "$d/settings.json" "$d/after-first.json" && echo ok || echo diff)" "[$tool] second merge is byte-identical (idempotent)"
  local bak2
  bak2="$(ls "$d"/settings.json.roost-bak-* 2>/dev/null | head -1)"
  [ -z "$bak2" ] && assert_eq ok ok "[$tool] idempotent re-merge makes no backup" \
    || assert_eq "backup made" "no backup" "[$tool] idempotent re-merge makes no backup"

  # malformed input: return non-zero, file untouched, no backup.
  local md
  md="$(mktemp -d /tmp/amx.XXXX)"
  printf '{ "not": "valid json"' > "$md/settings.json"
  local malformed_before
  malformed_before="$(cat "$md/settings.json")"
  PATH="$shim" bash -c '. "'"$HERE"'/scripts/lib/roost-json.sh"; roost_json_merge "'"$md"'/settings.json" claude-hooks "/checkout/scripts/roost-agent-state"' >"$md/merge.out" 2>"$md/merge.err"
  rc=$?
  [ "$rc" -ne 0 ] && assert_eq ok ok "[$tool] malformed JSON: merge returns non-zero" \
    || assert_eq "$rc" "non-zero" "[$tool] malformed JSON: merge returns non-zero"
  assert_eq "$(cat "$md/settings.json")" "$malformed_before" "[$tool] malformed JSON: file is byte-identical after"
  [ -s "$md/merge.err" ] && assert_eq ok ok "[$tool] malformed JSON: parser's message is printed" \
    || assert_eq "empty" "a message" "[$tool] malformed JSON: parser's message is printed"
  local malformed_bak
  malformed_bak="$(ls "$md"/settings.json.roost-bak-* 2>/dev/null | head -1)"
  [ -z "$malformed_bak" ] && assert_eq ok ok "[$tool] malformed JSON: no backup created" \
    || assert_eq "backup made" "no backup" "[$tool] malformed JSON: no backup created"
  rm -rf "$md"

  # capture the normalised output for the cross-tool comparison below.
  cat "$d/settings.json" > "$d/../roost-json-cross-$tool.out" 2>/dev/null || cp "$d/settings.json" "/tmp/roost-json-cross-$tool.out"

  rm -rf "$d" "$shim"
}

# --- python3 and jq, each in isolation ---

if command -v python3 >/dev/null 2>&1; then
  run_case python3
else
  assert_eq ok ok "python3 cases skipped (not installed on this machine)"
fi

if command -v jq >/dev/null 2>&1; then
  run_case jq
else
  assert_eq ok ok "jq cases skipped (not installed on this machine)"
fi

# --- same input, same output under both tools ---

if command -v python3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  py_out="$(mktemp -d /tmp/amx.XXXX)"
  jq_out="$(mktemp -d /tmp/amx.XXXX)"
  mkfixture "$py_out"
  mkfixture "$jq_out"

  pyshim="$(mktemp -d /tmp/amx.XXXX)"
  for bin in bash sh cat cp mv rm mkdir mktemp dirname cmp date grep sed diff env printf true false python3; do
    real="$(command -v "$bin" 2>/dev/null)" && ln -s "$real" "$pyshim/$bin" 2>/dev/null
  done
  jqshim="$(mktemp -d /tmp/amx.XXXX)"
  for bin in bash sh cat cp mv rm mkdir mktemp dirname cmp date grep sed diff env printf true false jq; do
    real="$(command -v "$bin" 2>/dev/null)" && ln -s "$real" "$jqshim/$bin" 2>/dev/null
  done

  PATH="$pyshim" bash -c '. "'"$HERE"'/scripts/lib/roost-json.sh"; roost_json_merge "'"$py_out"'/settings.json" claude-hooks "/checkout/scripts/roost-agent-state"' >/dev/null 2>&1
  PATH="$jqshim" bash -c '. "'"$HERE"'/scripts/lib/roost-json.sh"; roost_json_merge "'"$jq_out"'/settings.json" claude-hooks "/checkout/scripts/roost-agent-state"' >/dev/null 2>&1

  if cmp -s "$py_out/settings.json" "$jq_out/settings.json"; then
    assert_eq ok ok "python3 and jq produce byte-identical output for the same input"
  else
    assert_eq "$(cat "$py_out/settings.json")" "$(cat "$jq_out/settings.json")" "python3 and jq produce byte-identical output for the same input"
  fi

  rm -rf "$py_out" "$jq_out" "$pyshim" "$jqshim"
else
  assert_eq ok ok "python3-vs-jq comparison skipped (both tools required)"
fi

# --- copilot-flag mode: unrelated keys survive, flag lands ---

if command -v python3 >/dev/null 2>&1 || command -v jq >/dev/null 2>&1; then
  cd_="$(mktemp -d /tmp/amx.XXXX)"
  cat > "$cd_/settings.json" <<'JSON'
{
  "keepThis": true,
  "enabledFeatureFlags": {
    "SOME_OTHER_FLAG": true
  }
}
JSON
  roost_json_merge "$cd_/settings.json" copilot-flag >/dev/null 2>&1
  rc=$?
  assert_eq "$rc" "0" "copilot-flag merge exits 0"
  cflag_after="$(cat "$cd_/settings.json")"
  assert_contains "$cflag_after" '"SOME_OTHER_FLAG": true' "copilot-flag: unrelated flag survives"
  assert_contains "$cflag_after" '"EXTENSIONS": true' "copilot-flag: EXTENSIONS flag is set"
  assert_contains "$cflag_after" '"keepThis": true' "copilot-flag: unrelated top-level key survives"
  rm -rf "$cd_"
else
  assert_eq ok ok "copilot-flag case skipped (no JSON tool installed)"
fi

# --- codex-hooks mode ---

if command -v python3 >/dev/null 2>&1 || command -v jq >/dev/null 2>&1; then
  cx="$(mktemp -d /tmp/amx.XXXX)"
  cat > "$cx/hooks.json" <<'JSON'
{
  "hooks": {
    "SomeOtherEvent": [
      { "hooks": [ { "type": "command", "command": "echo unrelated" } ] }
    ]
  }
}
JSON
  roost_json_merge "$cx/hooks.json" codex-hooks "/checkout/adapters/codex/roost-codex-hook" >/dev/null 2>&1
  rc=$?
  assert_eq "$rc" "0" "codex-hooks merge exits 0"
  cx_after="$(cat "$cx/hooks.json")"
  assert_contains "$cx_after" "echo unrelated" "codex-hooks: unrelated hook survives"
  assert_contains "$cx_after" "/checkout/adapters/codex/roost-codex-hook UserPromptSubmit" "codex-hooks: UserPromptSubmit handler added"
  assert_contains "$cx_after" '"timeout": 10' "codex-hooks: handler carries timeout 10"
  rm -rf "$cx"
else
  assert_eq ok ok "codex-hooks case skipped (no JSON tool installed)"
fi

# --- absent file is treated as {} ---

if command -v python3 >/dev/null 2>&1 || command -v jq >/dev/null 2>&1; then
  af="$(mktemp -d /tmp/amx.XXXX)"
  roost_json_merge "$af/new-settings.json" copilot-flag >/dev/null 2>&1
  rc=$?
  assert_eq "$rc" "0" "merge against an absent file exits 0"
  [ -f "$af/new-settings.json" ] && assert_eq ok ok "merge against an absent file creates it" \
    || assert_eq "no file" "a file" "merge against an absent file creates it"
  nobak="$(ls "$af"/new-settings.json.roost-bak-* 2>/dev/null | head -1)"
  [ -z "$nobak" ] && assert_eq ok ok "creating a fresh file makes no backup (nothing existed to back up)" \
    || assert_eq "backup made" "no backup" "creating a fresh file makes no backup (nothing existed to back up)"
  rm -rf "$af"
else
  assert_eq ok ok "absent-file case skipped (no JSON tool installed)"
fi

# --- unknown mode: a caller bug, not a degraded runtime condition ---

if command -v python3 >/dev/null 2>&1 || command -v jq >/dev/null 2>&1; then
  um="$(mktemp -d /tmp/amx.XXXX)"
  printf '{}' > "$um/f.json"
  roost_json_merge "$um/f.json" bogus-mode >/dev/null 2>"$um/err"
  rc=$?
  assert_eq "$rc" "2" "unknown mode returns 2"
  assert_eq "$(cat "$um/f.json")" "{}" "unknown mode: file is untouched"
  rm -rf "$um"
else
  assert_eq ok ok "unknown-mode case skipped (no JSON tool installed)"
fi

# --- neither tool present: status 3, nothing written ---

nt="$(mktemp -d /tmp/amx.XXXX)"
mkfixture "$nt"
nt_before="$(cat "$nt/settings.json")"
hide_json_tools bash -c '. "'"$HERE"'/scripts/lib/roost-json.sh"; roost_json_merge "'"$nt"'/settings.json" claude-hooks "/checkout/scripts/roost-agent-state"'
rc=$?
assert_eq "$rc" "3" "no JSON tool on PATH: roost_json_merge returns 3"
assert_eq "$(cat "$nt/settings.json")" "$nt_before" "no JSON tool on PATH: file is byte-identical"
nt_bak="$(ls "$nt"/settings.json.roost-bak-* 2>/dev/null | head -1)"
[ -z "$nt_bak" ] && assert_eq ok ok "no JSON tool on PATH: no backup created" \
  || assert_eq "backup made" "no backup" "no JSON tool on PATH: no backup created"
rm -rf "$nt"

# --- also confirm the absent-file case degrades the same way ---

nt2="$(mktemp -d /tmp/amx.XXXX)"
hide_json_tools bash -c '. "'"$HERE"'/scripts/lib/roost-json.sh"; roost_json_merge "'"$nt2"'/settings.json" copilot-flag'
rc=$?
assert_eq "$rc" "3" "no JSON tool on PATH, absent file: roost_json_merge still returns 3"
[ -f "$nt2/settings.json" ] && assert_eq "file created" "no file" "no JSON tool on PATH: nothing written even for a new file" \
  || assert_eq ok ok "no JSON tool on PATH: nothing written even for a new file"
rm -rf "$nt2"

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
