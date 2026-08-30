#!/usr/bin/env bash
# tests/test-roost-json.sh — scripts/lib/roost-json.sh: atomic, backed-up
# JSON merges that degrade honestly when no JSON tool is on PATH.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/scripts/lib/roost-json.sh"

# Every external binary roost-json.sh or this test file calls, so a shim
# built from this list can run either engine's whole code path (stat/chmod
# included, for the permission-preservation check).
CORE_BINS="bash sh cat cp mv rm mkdir mktemp dirname readlink cmp date grep sed diff env printf true false stat chmod"

build_shim() {
  # build_shim [EXTRA...] -> prints a PATH-ready directory of symlinks to
  # CORE_BINS plus each EXTRA that this machine actually has. Not a
  # $PATH-prepend (tests/test-doctor.sh's noroostdir case is the precedent):
  # this machine's real PATH may carry a real python3 and/or jq, and
  # prepending would never exercise the "only this one tool" or "neither
  # tool" branches. The caller sets PATH to EXACTLY this directory.
  local dir bin real
  dir="$(mktemp -d /tmp/amx.XXXX)"
  for bin in $CORE_BINS "$@"; do
    real="$(command -v "$bin" 2>/dev/null)" && ln -s "$real" "$dir/$bin" 2>/dev/null
  done
  printf '%s' "$dir"
}

hide_json_tools() {
  # hide_json_tools CMD... -> run CMD with neither python3 nor jq reachable.
  local shim rc
  shim="$(build_shim)"
  PATH="$shim" "$@"
  rc=$?
  rm -rf "$shim"
  return $rc
}

merge_under() {
  # merge_under SHIMDIR FILE MODE [ARGS...] -> run roost_json_merge in a
  # fresh bash under PATH=SHIMDIR, capturing stdout/stderr the way a real
  # caller would (separately, so a test can check either).
  local shim="$1"; shift
  PATH="$shim" bash -c '. "'"$HERE"'/scripts/lib/roost-json.sh"; roost_json_merge "$@"' _ "$@"
}

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

# --- roost_json_tool ---

case "$(roost_json_tool)" in
  python3|jq) assert_true 0 "roost_json_tool reports a real tool when one is present" ;;
  *) assert_true 1 "roost_json_tool reports a real tool when one is present" ;;
esac

hide_json_tools bash -c '[ -z "$(. "'"$HERE"'/scripts/lib/roost-json.sh"; roost_json_tool)" ]'
assert_true $? "roost_json_tool prints nothing when neither tool is on PATH"

# ============================================================================
# run_case TOOL -- the full behavioural contract, exercised under a PATH that
# carries ONLY this one JSON tool (plus CORE_BINS). Called once for python3
# and once for jq so each engine is proven on its own, not just whichever one
# this machine prefers -- this is what the reviewer's Blocking 1 exploited:
# every mode except claude-hooks used to run on the ambient PATH, so on any
# machine with python3 installed the jq code paths never executed at all.
# ============================================================================
run_case() {
  local tool="$1" shim
  shim="$(build_shim "$tool")"

  # -- claude-hooks: unrelated key/hook survive, roost's hook is added --
  local d before after
  d="$(mktemp -d /tmp/amx.XXXX)"
  mkfixture "$d"
  before="$(cat "$d/settings.json")"
  chmod 644 "$d/settings.json"

  merge_under "$shim" "$d/settings.json" claude-hooks "/checkout/scripts/roost-agent-state" \
    >"$d/merge1.out" 2>"$d/merge1.err"
  assert_true $? "[$tool] claude-hooks merge exits 0"

  after="$(cat "$d/settings.json")"
  assert_contains "$after" "keep-me" "[$tool] unrelated top-level key survives the merge"
  assert_contains "$after" "echo unrelated-hook" "[$tool] unrelated hook survives the merge"
  assert_contains "$after" "/checkout/scripts/roost-agent-state working" "[$tool] roost's hook entry was added"

  local bak
  bak="$(ls "$d"/settings.json.roost-bak-* 2>/dev/null | head -1)"
  [ -n "$bak" ]; assert_true $? "[$tool] a backup was created for the first write"
  [ -n "$bak" ] && assert_eq "$(cat "$bak")" "$before" "[$tool] backup holds the pre-merge bytes"

  # -- permission preservation: mktemp's 0600 must not leak onto the target --
  # (Blocking 2: mktemp creates 0600 and a bare `mv` carries that mode onto
  # the destination, so a -rw-r--r-- settings file would silently become
  # -rw-------. Fixture was chmod 644 above specifically so this can fail.)
  local mode
  mode="$(stat -f '%Lp' "$d/settings.json" 2>/dev/null || stat -c '%a' "$d/settings.json" 2>/dev/null)"
  assert_eq "$mode" "644" "[$tool] merge preserves the target file's permissions"

  # -- idempotent: merging again with the same args changes nothing further --
  cp "$d/settings.json" "$d/after-first.json"
  rm -f "$d"/settings.json.roost-bak-*
  merge_under "$shim" "$d/settings.json" claude-hooks "/checkout/scripts/roost-agent-state" \
    >"$d/merge2.out" 2>"$d/merge2.err"
  assert_true $? "[$tool] second merge exits 0"
  cmp -s "$d/settings.json" "$d/after-first.json"
  assert_true $? "[$tool] second merge is byte-identical (idempotent)"
  assert_file_absent "$d"/settings.json.roost-bak-* "[$tool] idempotent re-merge makes no backup"

  # -- APPEND, never replace: a user's own entry in one of roost's own four
  #    events survives, matcher and all --
  #
  # This was a real defect, not a hypothetical: `hooks[event] = patch[event]`
  # replaced the whole array, so a settings.json whose PostToolUse carried
  # {"matcher": "Edit", "hooks": [{"command": "my-own-formatter"}]} came back
  # with that entry GONE -- rc 0, backup taken, nothing printed. A PostToolUse
  # formatter or linter is one of the most common Claude Code setups, so this
  # would have hit a large share of users on their first `roost install`.
  #
  # Roost's entry now joins the array. Idempotence comes from the TARGET path,
  # not from position: an existing entry whose commands all point at this
  # checkout's target is roost's own and is dropped before the patch's copy is
  # appended, so re-running converges instead of stacking duplicates.
  if command -v jq >/dev/null 2>&1; then
    local ud ulen ucmd
    ud="$(mktemp -d /tmp/amx.XXXX)"
    cat > "$ud/settings.json" <<'JSON'
{
  "hooks": {
    "PostToolUse": [
      { "matcher": "Edit",
        "hooks": [ { "type": "command", "command": "my-own-formatter" } ] }
    ]
  }
}
JSON
    merge_under "$shim" "$ud/settings.json" claude-hooks "/checkout/scripts/roost-agent-state" >/dev/null 2>&1
    assert_true $? "[$tool] append: a merge over a user's own entry exits 0"
    assert_eq "$(jq -c '.hooks.PostToolUse[0]' "$ud/settings.json" 2>/dev/null)" \
      '{"matcher":"Edit","hooks":[{"type":"command","command":"my-own-formatter"}]}' \
      "[$tool] append: the user's PostToolUse entry survives with its matcher intact"
    ulen="$(jq '.hooks.PostToolUse | length' "$ud/settings.json" 2>/dev/null)"
    assert_eq "$ulen" "2" "[$tool] append: roost's entry joins the array rather than replacing it"
    ucmd="$(jq -r '.hooks.PostToolUse[1].hooks[0].command' "$ud/settings.json" 2>/dev/null)"
    assert_eq "$ucmd" "/checkout/scripts/roost-agent-state working" \
      "[$tool] append: roost's entry is the one that was added"
    # Idempotence asserted as a COUNT. "roost's hook is present" stays true
    # while duplicates pile up one per run, so presence alone cannot see this.
    merge_under "$shim" "$ud/settings.json" claude-hooks "/checkout/scripts/roost-agent-state" >/dev/null 2>&1
    assert_eq "$(jq '.hooks.PostToolUse | length' "$ud/settings.json" 2>/dev/null)" "2" \
      "[$tool] append: a second merge adds no second roost entry"
    assert_eq "$(jq -c '.hooks.PostToolUse[0]' "$ud/settings.json" 2>/dev/null)" \
      '{"matcher":"Edit","hooks":[{"type":"command","command":"my-own-formatter"}]}' \
      "[$tool] append: the user's entry is still first and still intact after a re-merge"

    # A roost entry from a DIFFERENT checkout is not ours to drop. It is left
    # in place like any other stranger's hook, and this checkout's entry is
    # appended beside it -- scripts/roost-install refuses that whole case
    # before it ever reaches here, so what matters at this layer is only that
    # nothing is destroyed.
    local fd
    fd="$(mktemp -d /tmp/amx.XXXX)"
    cat > "$fd/settings.json" <<'JSON'
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "/other/checkout/scripts/roost-agent-state done --stop-hook" } ] }
    ]
  }
}
JSON
    merge_under "$shim" "$fd/settings.json" claude-hooks "/checkout/scripts/roost-agent-state" >/dev/null 2>&1
    assert_eq "$(jq -r '.hooks.Stop[0].hooks[0].command' "$fd/settings.json" 2>/dev/null)" \
      "/other/checkout/scripts/roost-agent-state done --stop-hook" \
      "[$tool] append: another checkout's roost entry is left alone, not rewritten"
    assert_eq "$(jq '.hooks.Stop | length' "$fd/settings.json" 2>/dev/null)" "2" \
      "[$tool] append: this checkout's entry is added beside it"
    rm -rf "$fd"

    # codex's events are arrays too, and the same fix has to hold there. Per
    # the measured hash fact (scripts/lib/roost-hooks.sh's header), adding a
    # handler to an event does not disturb an already-trusted handler: the
    # hash is per handler and over the parsed struct, so a neighbour arriving
    # in the same array changes nothing codex can see.
    local cxa
    cxa="$(mktemp -d /tmp/amx.XXXX)"
    cat > "$cxa/hooks.json" <<'JSON'
{
  "hooks": {
    "PostToolUse": [
      { "hooks": [ { "type": "command", "command": "somebody-elses-codex-hook", "timeout": 3 } ] }
    ]
  }
}
JSON
    merge_under "$shim" "$cxa/hooks.json" codex-hooks "/checkout/adapters/codex/roost-codex-hook" >/dev/null 2>&1
    assert_true $? "[$tool] append: a codex merge over another handler exits 0"
    assert_eq "$(jq -c '.hooks.PostToolUse[0]' "$cxa/hooks.json" 2>/dev/null)" \
      '{"hooks":[{"type":"command","command":"somebody-elses-codex-hook","timeout":3}]}' \
      "[$tool] append: the other codex handler survives, value for value"
    assert_eq "$(jq -c '.hooks.PostToolUse[1]' "$cxa/hooks.json" 2>/dev/null)" \
      '{"hooks":[{"type":"command","command":"/checkout/adapters/codex/roost-codex-hook PostToolUse","timeout":10}]}' \
      "[$tool] append: roost's codex handler is appended beside it, byte-exact"
    merge_under "$shim" "$cxa/hooks.json" codex-hooks "/checkout/adapters/codex/roost-codex-hook" >/dev/null 2>&1
    assert_eq "$(jq '.hooks.PostToolUse | length' "$cxa/hooks.json" 2>/dev/null)" "2" \
      "[$tool] append: a second codex merge adds no second roost handler"
    rm -rf "$cxa"

    # An event whose value is not an array cannot be appended to, and roost
    # does not get to decide what it meant. Refused, with the file untouched
    # and no backup -- the same answer as any other shape it cannot read.
    local nd nbefore
    nd="$(mktemp -d /tmp/amx.XXXX)"
    printf '{"hooks":{"Stop":{"not":"an array"}}}' > "$nd/settings.json"
    nbefore="$(cat "$nd/settings.json")"
    merge_under "$shim" "$nd/settings.json" claude-hooks "/checkout/scripts/roost-agent-state" \
      >/dev/null 2>"$nd/err"
    [ "$?" -ne 0 ]; assert_true $? "[$tool] append: an event that is not an array is refused"
    assert_eq "$(cat "$nd/settings.json")" "$nbefore" \
      "[$tool] append: that file is byte-identical after"
    assert_file_absent "$nd"/settings.json.roost-bak-* \
      "[$tool] append: no backup was taken for a refusal"
    [ -s "$nd/err" ]; assert_true $? "[$tool] append: the refusal says something on stderr"
    rm -rf "$nd"

    rm -rf "$ud"
  else
    assert_true 0 "[$tool] append cases skipped (jq needed to read the result back)"
  fi

  # -- genuine JSON syntax error: non-zero, untouched, no backup --
  # python3 folds every malformed-input case into exit 1. jq's OWN parse
  # error (a real syntax error, not just "not one object") is forwarded as
  # jq's own exit status, 5 -- see roost_json__jq_validate's comment for why
  # that is not remapped to 1.
  local want_syntax_rc
  case "$tool" in python3) want_syntax_rc=1 ;; jq) want_syntax_rc=5 ;; esac
  local md mbefore
  md="$(mktemp -d /tmp/amx.XXXX)"
  printf '{ "not": "valid json"' > "$md/settings.json"
  mbefore="$(cat "$md/settings.json")"
  merge_under "$shim" "$md/settings.json" claude-hooks "/checkout/scripts/roost-agent-state" \
    >"$md/merge.out" 2>"$md/merge.err"
  assert_eq "$?" "$want_syntax_rc" "[$tool] genuine JSON syntax error returns $want_syntax_rc"
  assert_eq "$(cat "$md/settings.json")" "$mbefore" "[$tool] syntax error: file is byte-identical after"
  [ -s "$md/merge.err" ]; assert_true $? "[$tool] syntax error: parser's message is printed"
  assert_file_absent "$md"/settings.json.roost-bak-* "[$tool] syntax error: no backup created"
  rm -rf "$md"

  # -- shape-malformed: valid JSON, but not exactly one top-level object --
  # This is Blocking 1's actual bug. jq is a STREAM processor: an empty or
  # whitespace-only file is zero JSON values and two concatenated objects
  # are two, and unchecked, jq ran its merge filter over that stream, wrote
  # whatever that produced (nothing, for an empty file), and reported rc=0
  # -- silently truncating a real settings file while claiming success. Every
  # one of these must now return non-zero, leave the file untouched, and
  # take no backup, under BOTH engines.
  local shape_name shape_content
  for shape_name in empty whitespace-only two-concatenated-docs non-object-array; do
    case "$shape_name" in
      empty)                  shape_content="" ;;
      whitespace-only)        shape_content="$(printf '\n  \n')" ;;
      two-concatenated-docs)  shape_content="$(printf '{"a":1}\n{"b":2}\n')" ;;
      non-object-array)       shape_content="$(printf '[1,2]')" ;;
    esac
    local sd sbefore
    sd="$(mktemp -d /tmp/amx.XXXX)"
    printf '%s' "$shape_content" > "$sd/settings.json"
    sbefore="$(cat "$sd/settings.json")"
    merge_under "$shim" "$sd/settings.json" copilot-flag >"$sd/merge.out" 2>"$sd/merge.err"
    local rc=$?
    [ "$rc" -ne 0 ]; assert_true $? "[$tool] shape ($shape_name): merge returns non-zero (got $rc)"
    assert_eq "$(cat "$sd/settings.json")" "$sbefore" "[$tool] shape ($shape_name): file is byte-identical after"
    assert_file_absent "$sd"/settings.json.roost-bak-* "[$tool] shape ($shape_name): no backup created"
    rm -rf "$sd"
  done

  # -- copilot-flag: unrelated keys survive, flag lands --
  local cd_
  cd_="$(mktemp -d /tmp/amx.XXXX)"
  cat > "$cd_/settings.json" <<'JSON'
{
  "keepThis": true,
  "enabledFeatureFlags": {
    "SOME_OTHER_FLAG": true
  }
}
JSON
  merge_under "$shim" "$cd_/settings.json" copilot-flag >/dev/null 2>&1
  assert_true $? "[$tool] copilot-flag merge exits 0"
  local cflag_after
  cflag_after="$(cat "$cd_/settings.json")"
  assert_contains "$cflag_after" '"SOME_OTHER_FLAG": true' "[$tool] copilot-flag: unrelated flag survives"
  assert_contains "$cflag_after" '"EXTENSIONS": true' "[$tool] copilot-flag: EXTENSIONS flag is set"
  assert_contains "$cflag_after" '"keepThis": true' "[$tool] copilot-flag: unrelated top-level key survives"
  rm -rf "$cd_"

  # -- codex-hooks: unrelated hook survives, and the four handlers are
  # byte-exact -- a reordered handler object, a dropped "matcher"-shaped
  # field, or a changed argument would all still pass a plain
  # assert_contains '"timeout": 10'. Codex silently skips any handler whose
  # normalised hash no longer matches (see scripts/lib/roost-hooks.sh's own
  # comment), so this compares full compact objects, in order, not just a
  # substring.
  local cx
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
  merge_under "$shim" "$cx/hooks.json" codex-hooks "/checkout/adapters/codex/roost-codex-hook" >/dev/null 2>&1
  assert_true $? "[$tool] codex-hooks merge exits 0"
  local cx_after
  cx_after="$(cat "$cx/hooks.json")"
  assert_contains "$cx_after" "echo unrelated" "[$tool] codex-hooks: unrelated hook survives"

  local event want_obj got_obj
  for event in UserPromptSubmit PostToolUse PermissionRequest Stop; do
    want_obj='{"hooks":[{"type":"command","command":"/checkout/adapters/codex/roost-codex-hook '"$event"'","timeout":10}]}'
    got_obj="$(jq -c ".hooks.$event[0]" "$cx/hooks.json" 2>/dev/null)"
    assert_eq "$got_obj" "$want_obj" "[$tool] codex-hooks: $event handler is byte-exact"
  done
  rm -rf "$cx"

  # -- the merged bytes come from scripts/lib/roost-hooks.sh, not a copy --
  # Task 3b. roost-json.sh used to hardcode its own version of the four
  # claude and the four codex handler shapes. They matched by hand, which is
  # exactly the guarantee codex's handler hashing does not accept: it stores
  # a hash of each normalised handler object and silently SKIPS any handler
  # whose hash no longer matches -- nothing on stdout, on stderr, or in its
  # TUI (measured on codex-cli 0.150.1: appending one argument took 8 of 8
  # hooks down; changing one timeout from 10 to 11 took 7 of 8 down). So
  # compare what the merge actually wrote against what roost-hooks.sh
  # prints, for the same injected target, as ONE ordered compact object --
  # a reordered key, a dropped field or a changed timeout all fail here.
  if command -v jq >/dev/null 2>&1; then
    local sd_ want_hooks got_hooks
    sd_="$(mktemp -d /tmp/amx.XXXX)"
    merge_under "$shim" "$sd_/claude.json" claude-hooks "/x/agent-state" >/dev/null 2>&1
    want_hooks="$(. "$HERE/scripts/lib/roost-hooks.sh"; roost_hooks_claude "/x/agent-state" | jq -c '.hooks')"
    got_hooks="$(jq -c '.hooks' "$sd_/claude.json" 2>/dev/null)"
    assert_eq "$got_hooks" "$want_hooks" \
      "[$tool] claude-hooks merges exactly what roost_hooks_claude prints"

    merge_under "$shim" "$sd_/codex.json" codex-hooks "/x/codex-hook" >/dev/null 2>&1
    want_hooks="$(. "$HERE/scripts/lib/roost-hooks.sh"; roost_hooks_codex "/x/codex-hook" | jq -c '.hooks')"
    got_hooks="$(jq -c '.hooks' "$sd_/codex.json" 2>/dev/null)"
    assert_eq "$got_hooks" "$want_hooks" \
      "[$tool] codex-hooks merges exactly what roost_hooks_codex prints"
    rm -rf "$sd_"
  else
    assert_true 0 "[$tool] hook-body identity check skipped (jq needed to compare)"
  fi

  # -- absent file is treated as {} --
  local af
  af="$(mktemp -d /tmp/amx.XXXX)"
  merge_under "$shim" "$af/new-settings.json" copilot-flag >/dev/null 2>&1
  assert_true $? "[$tool] merge against an absent file exits 0"
  [ -f "$af/new-settings.json" ]; assert_true $? "[$tool] merge against an absent file creates it"
  assert_file_absent "$af"/new-settings.json.roost-bak-* "[$tool] creating a fresh file makes no backup"
  rm -rf "$af"

  # -- unknown mode: a caller bug, not a degraded runtime condition --
  local um
  um="$(mktemp -d /tmp/amx.XXXX)"
  printf '{}' > "$um/f.json"
  merge_under "$shim" "$um/f.json" bogus-mode >/dev/null 2>"$um/err"
  assert_eq "$?" "2" "[$tool] unknown mode returns 2"
  assert_eq "$(cat "$um/f.json")" "{}" "[$tool] unknown mode: file is untouched"
  rm -rf "$um"

  rm -rf "$d" "$md" "$shim" 2>/dev/null
}

if command -v python3 >/dev/null 2>&1; then
  run_case python3
else
  assert_true 0 "python3 cases skipped (not installed on this machine)"
fi

if command -v jq >/dev/null 2>&1; then
  run_case jq
else
  assert_true 0 "jq cases skipped (not installed on this machine)"
fi

# --- same input, same output under both tools ---
# Two fixtures: plain ASCII, and one with non-ASCII bytes (an accented path,
# an emoji in a statusLine command -- both common in a real settings.json).
# Blocking 3: python3's json.dump defaults to ensure_ascii=True (\uXXXX
# escapes) while jq always emits raw UTF-8, so an ASCII-only fixture is
# structurally incapable of catching that divergence -- which is exactly
# what the original version of this test did.
compare_engines() {
  local fixture_file="$1" label="$2"
  local py_out jq_out pyshim jqshim
  py_out="$(mktemp -d /tmp/amx.XXXX)"
  jq_out="$(mktemp -d /tmp/amx.XXXX)"
  cp "$fixture_file" "$py_out/settings.json"
  cp "$fixture_file" "$jq_out/settings.json"
  pyshim="$(build_shim python3)"
  jqshim="$(build_shim jq)"

  merge_under "$pyshim" "$py_out/settings.json" claude-hooks "/checkout/scripts/roost-agent-state" >/dev/null 2>&1
  merge_under "$jqshim" "$jq_out/settings.json" claude-hooks "/checkout/scripts/roost-agent-state" >/dev/null 2>&1

  cmp -s "$py_out/settings.json" "$jq_out/settings.json"
  assert_true $? "python3 and jq produce byte-identical output ($label)"

  rm -rf "$py_out" "$jq_out" "$pyshim" "$jqshim"
}

if command -v python3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  fx="$(mktemp -d /tmp/amx.XXXX)"
  mkfixture "$fx"
  compare_engines "$fx/settings.json" "ASCII fixture"
  rm -rf "$fx"

  fx2="$(mktemp -d /tmp/amx.XXXX)"
  printf '{"statusLine": {"command": "echo café \xe2\x9c\x94"}, "hooks": {}}' > "$fx2/settings.json"
  compare_engines "$fx2/settings.json" "non-ASCII fixture (café + a checkmark)"
  rm -rf "$fx2"
else
  assert_true 0 "python3-vs-jq comparison skipped (both tools required)"
fi

# --- neither tool present: status 3, nothing written ---

nt="$(mktemp -d /tmp/amx.XXXX)"
mkfixture "$nt"
nt_before="$(cat "$nt/settings.json")"
hide_json_tools bash -c '. "'"$HERE"'/scripts/lib/roost-json.sh"; roost_json_merge "'"$nt"'/settings.json" claude-hooks "/checkout/scripts/roost-agent-state"'
assert_eq "$?" "3" "no JSON tool on PATH: roost_json_merge returns 3"
assert_eq "$(cat "$nt/settings.json")" "$nt_before" "no JSON tool on PATH: file is byte-identical"
assert_file_absent "$nt"/settings.json.roost-bak-* "no JSON tool on PATH: no backup created"
rm -rf "$nt"

nt2="$(mktemp -d /tmp/amx.XXXX)"
hide_json_tools bash -c '. "'"$HERE"'/scripts/lib/roost-json.sh"; roost_json_merge "'"$nt2"'/settings.json" copilot-flag'
assert_eq "$?" "3" "no JSON tool on PATH, absent file: roost_json_merge still returns 3"
assert_file_absent "$nt2/settings.json" "no JSON tool on PATH: nothing written even for a new file"
rm -rf "$nt2"

# --- one copy of the hook bytes, not two ---------------------------------
# Output equality alone cannot tell "sourced from the shared lib" from
# "duplicated inline and kept in sync by hand", and the hand-kept duplicate is
# the thing that actually bites (see the identity check inside run_case). So
# pin the SOURCE too, the way tests/test-hook-source.sh pins bin/roost's.
# Comment-only lines are stripped first and the function name is required as a
# whole word, because roost-json.sh's own header names both functions in
# prose -- an unanchored grep would pass with the call deleted.
json_code="$(grep -v '^[[:space:]]*#' "$HERE/scripts/lib/roost-json.sh")"
json_called() { printf '%s' "$1" | grep -Eq "(^|[^A-Za-z0-9_])$2([^A-Za-z0-9_]|\$)"; }
grep -q 'roost-hooks.sh' "$HERE/scripts/lib/roost-json.sh" && s=yes || s=no
assert_eq "$s" "yes" "roost-json.sh sources scripts/lib/roost-hooks.sh"
json_called "$json_code" roost_hooks_claude && s=yes || s=no
assert_eq "$s" "yes" "roost-json.sh actually CALLS roost_hooks_claude (not just mentions it)"
json_called "$json_code" roost_hooks_codex && s=yes || s=no
assert_eq "$s" "yes" "roost-json.sh actually CALLS roost_hooks_codex (not just mentions it)"
n="$(grep -c 'roost-codex-hook' "$HERE/scripts/lib/roost-json.sh" || true)"
assert_eq "${n:-0}" "0" "roost-json.sh carries no second copy of the frozen codex handlers"
n="$(grep -c 'permission_prompt' "$HERE/scripts/lib/roost-json.sh" || true)"
assert_eq "${n:-0}" "0" "roost-json.sh carries no second copy of the claude hook body"

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
