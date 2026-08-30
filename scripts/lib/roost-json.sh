# roost-json.sh — JSON edit helper that degrades honestly.
#
# scripts/roost-doctor:31 records a standing decision: python3 is not a
# runtime dependency, and neither is jq. That decision is about the
# PostToolUse hot path, which fires on every tool call of every live agent.
# This file is not on that path — it backs a one-off setup command
# (scripts/roost-install) — so it is allowed to use whichever JSON tool it
# finds. But the decision still binds the case where NEITHER is present: that
# must be a real, quiet, non-zero degraded path, not a crash and not a
# half-written config. See roost_json_merge below.
#
# Sits alongside roost-adapters.sh, roost-socket.sh, roost-config.sh: sourced,
# not executed, `roost_json_*` prefix. Unlike roost-socket.sh's
# roost_self_socket, these print rather than set a variable — nothing here
# runs on a hot path, so a subshell per call costs nothing anyone will notice.

# The claude and codex hook bodies are NOT written out again here. They come
# from scripts/lib/roost-hooks.sh, which is the one production definition of
# those bytes, and this file merges whatever that prints. Codex stores a hash
# of each normalised handler object and silently SKIPS any handler whose hash
# no longer matches — nothing on stdout, on stderr, or in its TUI (measured on
# codex-cli 0.150.1: appending one argument to a command string took 8 of 8
# hooks down; changing one timeout from 10 to 11 took 7 of 8 down). A second
# copy of those bytes here, kept in sync by hand, would eventually differ by
# one byte and silently un-badge every machine that had already granted trust.
#
# Sourced by path relative to THIS file rather than from an inherited
# $ROOST_HOME, for the reason scripts/lib/roost-adapters.sh spells out at
# length: bin/roost exports ROOST_HOME into every pane of the session it
# starts, so a caller running inside a roost session would otherwise pull the
# hook bodies out of a DIFFERENT checkout than the one it is installing.
# Guarded, because bin/roost sources both files and re-sourcing is wasted work
# rather than a bug.
if ! declare -f roost_hooks_claude >/dev/null 2>&1; then
  . "$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/roost-hooks.sh"
fi

# roost_json_tool -> prints "python3", "jq", or nothing (found, in that
# preference order). Never fails; absence is reported by an empty string, not
# a non-zero status, so callers that only want the name can use it directly
# in a printf without also checking $?.
roost_json_tool() {
  if command -v python3 >/dev/null 2>&1; then
    printf 'python3'
  elif command -v jq >/dev/null 2>&1; then
    printf 'jq'
  fi
}

# roost_json_backup FILE -> copy FILE to FILE.roost-bak-<epoch-seconds> and
# print the backup path. Only ever call this immediately before a write that
# is actually going to happen — never speculatively, and never when the
# merge turns out to be a no-op. A backup taken for nothing written is a bug,
# not a safety margin: it litters a config directory with copies that do not
# correspond to any real change and that a user has no way to tell apart from
# ones that do.
roost_json_backup() {
  local file="$1" bak
  bak="${file}.roost-bak-$(date +%s)"
  cp -p "$file" "$bak" || return 1
  printf '%s' "$bak"
}

# roost_json__py_script -> the python3 helper, on stdout. One copy shared by
# every mode so the merge logic for a given mode exists exactly once.
#
# Reads the CURRENT document from stdin (the caller passes FILE's bytes, or
# the literal text "{}" when FILE is absent), applies argv[1] (the mode) with
# argv[2:] as its arguments, and prints the result with 2-space indentation.
# A key already present keeps its original position — Python dicts preserve
# insertion order, and `obj[key] = value` on an existing key updates in
# place rather than moving it to the end — so re-running a merge that changes
# nothing produces byte-identical output. Malformed input is reported on
# stderr in the parser's own words and exits 1; an unknown mode exits 2. Both
# leave nothing on stdout for the caller to mistake for a result.
roost_json__py_script() {
  cat <<'PY'
import json
import sys

def main():
    mode = sys.argv[1]
    args = sys.argv[2:]
    try:
        data = json.load(sys.stdin)
    except Exception as exc:
        sys.stderr.write("roost-json: %s\n" % exc)
        sys.exit(1)
    if not isinstance(data, dict):
        sys.stderr.write("roost-json: top-level JSON value must be an object\n")
        sys.exit(1)

    try:
        if mode == "hooks-merge":
            # argv[2] is a whole JSON document {"hooks": {...}} produced by
            # scripts/lib/roost-hooks.sh. Its events are copied in ITS order,
            # so a key already in the file is updated where it stands and a
            # new one is appended after the existing ones — which is what
            # makes a re-merge byte-identical. Every hook the file already
            # had under a different event name is left alone.
            patch = json.loads(args[0])
            hooks = data.setdefault("hooks", {})
            for event in patch["hooks"]:
                hooks[event] = patch["hooks"][event]
        elif mode == "copilot-flag":
            flags = data.setdefault("enabledFeatureFlags", {})
            flags["EXTENSIONS"] = True
        else:
            sys.stderr.write("roost-json: unknown mode '%s'\n" % mode)
            sys.exit(2)
    except (IndexError, KeyError, TypeError, ValueError, AttributeError) as exc:
        sys.stderr.write("roost-json: cannot apply mode '%s': %s\n" % (mode, exc))
        sys.exit(1)

    # ensure_ascii=False + writing to the raw byte stream: a settings file
    # with an accented path or an emoji in a statusLine command must come
    # back with the SAME bytes it had (modulo indentation), not \uXXXX
    # escapes. Writing to sys.stdout directly would pick whatever encoding
    # the environment's locale gives sys.stdout, which is not guaranteed to
    # be UTF-8 (and a mismatch there would raise, not silently mangle) — so
    # encode explicitly and write bytes.
    out = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    sys.stdout.buffer.write(out.encode("utf-8"))

main()
PY
}

# roost_json__jq_validate INPUT -> jq is a STREAM processor: an empty file
# is zero JSON values, and two concatenated objects are two — either way jq
# runs its filter zero-or-N times and exits 0, with no complaint that the
# top-level shape was never a single object. Left unchecked, that turns an
# empty or whitespace-only settings file into a truncated one (the merge
# filter has nothing to operate on, so it produces nothing, and roost_json_
# merge would still see rc=0 and promote that "nothing" to the real file) —
# this is exactly the gap python3's `isinstance(data, dict)` check (above)
# already closes for that engine.
#
# `jq --slurp` reads every top-level value in INPUT into one JSON array, so
# `length == 1 and (.[0] | type) == "object"` is true for exactly the shape
# roost_json_merge is willing to touch: prints nothing and returns 0 there.
#
# Two failure shapes, kept distinct because they ARE distinct and the header
# comment on roost_json_merge documents both:
#   - INPUT has a genuine JSON syntax error -> jq itself exits 5 (jq's own
#     "compile/parse error" status; -e does not change this one). Its own
#     parse-error message is forwarded verbatim.
#   - INPUT parses fine but is not exactly one object at the top level
#     (empty, whitespace-only, multiple concatenated documents, or a single
#     non-object value like `[1,2]`) -> exit 1, with a message this
#     function writes itself, since jq has no complaint of its own to
#     forward for "valid JSON, wrong shape".
roost_json__jq_validate() {
  local input="$1" msg rc
  msg="$(jq -e --slurp 'length == 1 and (.[0] | type) == "object"' "$input" 2>&1 1>/dev/null)"
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  if [ "$rc" -eq 5 ]; then
    printf '%s\n' "$msg" >&2
    return 5
  fi
  printf 'roost-json: top-level JSON value must be an object\n' >&2
  return 1
}

# roost_json__jq_run MODE INPUT OUT ARGS... -> run jq for MODE against INPUT,
# writing the result to OUT. Kept as a case per mode rather than one generic
# filter, so each mode stays diffable against roost_json__py_script's version
# of the same one. MODE here is an INTERNAL mode, already translated by
# roost_json_merge — `hooks-merge`, not `claude-hooks`.
#
# jq preserves key order the same way Python's dict does: on the left of a
# `+`, a key that already exists keeps its position and takes the right's
# value; only a brand new key is appended. That is what makes the
# idempotent-merge and same-input-same-output checks hold for jq too, not just
# for python3.
roost_json__jq_run() {
  local mode="$1" input="$2" out="$3"; shift 3

  # Validated unconditionally, same as python3's isinstance(dict) check runs
  # before python3 even looks at MODE: an unparseable or wrongly-shaped
  # FILE is refused the same way whether or not the caller also passed a
  # mode this file recognises.
  roost_json__jq_validate "$input" || return $?

  case "$mode" in
    hooks-merge)
      # `+` on two objects is jq's spelling of the python branch above: the
      # left object keeps its own key order, a key present on both takes the
      # right's value in place, and a key only on the right is appended after
      # them. So both engines produce the same bytes for the same input, and
      # a re-merge changes nothing.
      local patch="${1:-}"
      if [ -z "$patch" ]; then
        printf "roost-json: cannot apply mode 'hooks-merge': no patch document\n" >&2
        return 1
      fi
      jq --indent 2 --argjson patch "$patch" \
        '.hooks = ((.hooks // {}) + $patch.hooks)' \
        "$input" > "$out"
      ;;
    copilot-flag)
      jq --indent 2 '.enabledFeatureFlags.EXTENSIONS = true' "$input" > "$out"
      ;;
    *)
      printf 'roost-json: unknown mode '\''%s'\''\n' "$mode" >&2
      return 2
      ;;
  esac
}

# roost_json_merge FILE MODE [ARGS...] -> apply MODE to FILE (treated as "{}"
# when FILE does not exist), writing the result atomically. Modes:
#   claude-hooks TARGET_SCRIPT   merge the four roost hook entries into .hooks
#   codex-hooks  TARGET_SCRIPT   merge the four roost handlers into .hooks
#   copilot-flag                 set .enabledFeatureFlags.EXTENSIONS = true
#
# The two hook modes are translated here into the engines' internal
# `hooks-merge` mode, whose patch document is whatever
# scripts/lib/roost-hooks.sh prints for TARGET_SCRIPT. That is the whole point
# of the translation: the bytes merged into a real settings.json and the bytes
# `roost hooks` prints come from ONE definition, so they cannot drift into two
# different codex handler hashes. TARGET_SCRIPT is passed to roost-hooks.sh
# verbatim, so a caller (or a test) may inject any path at all.
#
# Every other top-level key, and every other key already inside .hooks (or
# .enabledFeatureFlags), is left exactly as it was. Key order survives: only
# indentation is normalised, to 2 spaces.
#
# Exit status:
#   0  success — either FILE was written (and, if it existed before, backed
#      up first — see below) or the merge turned out to be a no-op
#   1  malformed input under python3 (any parse failure, or a top-level
#      value that isn't an object); under jq, valid JSON that still isn't
#      exactly one top-level object (empty input, multiple concatenated
#      documents, or a single non-object value like `[1,2]`)
#   2  unknown MODE (a caller bug, not a degraded runtime condition)
#   3  neither python3 nor jq is on PATH. Nothing is written. Not an error —
#      the caller falls back to printing the block for the user to merge by
#      hand.
#   5  jq only: a genuine JSON syntax error in FILE. jq's own exit status
#      for a parse failure, forwarded rather than remapped to 1, so this
#      contract says what each engine actually does instead of pretending
#      they agree. No caller of this file distinguishes 5 from 1 today —
#      both simply mean "nothing was written, read the stderr message" —
#      but a future one should not have to discover the real number by
#      testing.
#
# Every one of the non-zero codes above leaves FILE untouched and takes no
# backup, regardless of engine.
#
# On stdout: the backup path, IF AND ONLY IF a backup was actually made
# (an existing file whose content is about to change). Nothing is printed
# when FILE did not exist yet, and nothing is printed when the merge is a
# no-op. roost_json_backup itself is never called speculatively — only right
# here, immediately before the one write that needs it.
roost_json_merge() {
  local file="$1" mode="$2"; shift 2
  local tool dir tmp input existed rc bak
  tool="$(roost_json_tool)"
  [ -n "$tool" ] || return 3

  # Translate a public hook mode into the engines' `hooks-merge` plus the
  # patch document roost-hooks.sh prints. An unrecognised mode is passed
  # through untouched so the engine still reports it as unknown (status 2)
  # AFTER it has validated FILE — the order the header documents.
  local engine_mode="$mode"
  case "$mode" in
    claude-hooks|codex-hooks)
      local target="${1:-}"
      if [ -z "$target" ]; then
        printf "roost-json: mode '%s' needs a TARGET_SCRIPT\n" "$mode" >&2
        return 1
      fi
      engine_mode=hooks-merge
      case "$mode" in
        claude-hooks) set -- "$(roost_hooks_claude "$target")" ;;
        codex-hooks)  set -- "$(roost_hooks_codex  "$target")" ;;
      esac
      ;;
  esac

  dir="$(dirname -- "$file")"
  mkdir -p -- "$dir" || return 1

  if [ -f "$file" ]; then
    existed=1
    input="$file"
  else
    existed=0
    input="$(mktemp "$dir/.roost-json-in.XXXXXX")" || return 1
    printf '{}' > "$input"
  fi

  tmp="$(mktemp "$dir/.roost-json.XXXXXX")" || { [ "$existed" -eq 0 ] && rm -f "$input"; return 1; }

  case "$tool" in
    python3)
      python3 -c "$(roost_json__py_script)" "$engine_mode" "$@" < "$input" > "$tmp"
      rc=$?
      ;;
    jq)
      roost_json__jq_run "$engine_mode" "$input" "$tmp" "$@"
      rc=$?
      ;;
  esac

  [ "$existed" -eq 0 ] && rm -f "$input"

  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    return "$rc"
  fi

  if [ "$existed" -eq 1 ] && cmp -s -- "$file" "$tmp" 2>/dev/null; then
    # Idempotent: nothing changed, so nothing is written and no backup is
    # taken.
    rm -f "$tmp"
    return 0
  fi

  if [ "$existed" -eq 1 ]; then
    bak="$(roost_json_backup "$file")" || { rm -f "$tmp"; return 1; }
    printf '%s\n' "$bak"

    # mktemp creates 0600, and mv carries that mode onto the target — so
    # without this, a -rw-r--r-- settings file would silently become
    # -rw-------. GNU-first, BSD-fallback `stat`, same as
    # roost_cfg_set in roost-config.sh: GNU `stat -f` means "filesystem
    # status" and succeeds on the wrong thing rather than failing, so the
    # order cannot be reversed.
    local perm
    perm="$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null)"
    [ -n "$perm" ] && chmod "$perm" "$tmp"
  fi

  mv "$tmp" "$file"
}
