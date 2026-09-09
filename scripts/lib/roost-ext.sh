# roost-ext.sh — the shared helpers behind the extension seam.
#
# Sourced, not executed, alongside roost-socket.sh, roost-config.sh,
# roost-adapters.sh and roost-json.sh: `roost_ext_*` prefix, and the only work
# done at source time is the one path resolution below — nothing else here
# happens until a caller asks for it.
#
# Four of the functions here are SECURITY CONTROLS rather than conveniences,
# and each says so where it is defined:
#
#   roost_ext_repo_valid    runs before <org>/<repo> reaches a git command line
#   roost_ext_needs_valid   REFUSES an unknown authority rather than ignoring it
#   roost_ext_index_lookup  forks nothing, on the path every typo takes
#   roost_ext_tree_hostile  looks at the tree a clone actually delivered
#
# roost-json.sh is sourced LAZILY, inside the two functions that parse JSON,
# rather than at file scope. bin/roost sources THIS file on every invocation —
# including `roost state`, which fires on every tool call of every live agent
# (AGENTS.md §2) — and a file-scope source would read roost-json.sh, and
# through it roost-hooks.sh, on every one of those, to serve two functions
# that only ever run during `roost ext install`.

# Where this file's siblings live, resolved relative to THIS file rather than
# through an inherited $ROOST_HOME, for the reason roost-json.sh's own header
# gives at length: bin/roost exports ROOST_HOME into every pane of the session
# it starts, so a caller running inside a roost session would otherwise load a
# DIFFERENT checkout's copy of a library than the one it is executing.
#
# Resolved at SOURCE time and made absolute, because the one use of it below
# is LAZY: by the time roost_ext__json_lib runs, bin/roost has picked a
# subcommand and something may have changed the working directory, and a
# relative path captured here would resolve against the wrong place then.
#
# Parameter expansion and $PWD rather than `$(cd -P "$(dirname ...)" && pwd)`:
# this line runs on every single `roost` invocation, `roost state` included,
# and that idiom is two forks — one of them for a `dirname` that a `%/*`
# already does. It also keeps this file working with nothing at all on PATH,
# which is what tests/test-ext.sh pins.
case "${BASH_SOURCE[0]}" in
  /*)  ROOST_EXT__LIB_DIR="${BASH_SOURCE[0]%/*}" ;;
  */*) ROOST_EXT__LIB_DIR="$PWD/${BASH_SOURCE[0]%/*}" ;;
  *)   ROOST_EXT__LIB_DIR="$PWD" ;;
esac

# roost_ext__json_lib — make roost-json.sh's functions available. Guarded,
# because bin/roost and scripts/roost-install may have sourced roost-json.sh
# already and re-sourcing is wasted work rather than a bug.
roost_ext__json_lib() {
  declare -f roost_json_tool >/dev/null 2>&1 && return 0
  . "$ROOST_EXT__LIB_DIR/roost-json.sh"
}

# --- where things live on disk ----------------------------------------------

# roost_ext__roots — set ROOST_EXT_DATA_ROOT and ROOST_EXT_STATE_ROOT.
#
# SETS rather than prints, and the four resolvers below print what it set.
# That is roost_self_socket's shape, and it is here for the same reason:
# roost_ext_index_lookup runs on every mistyped roost subcommand, and a
# `$(roost_ext_index)` there would be a fork per typo on the one path this
# whole design promises not to fork on.
#
# `${X:-...}`, not `${X-...}`. An XDG variable exported with an EMPTY value is
# a real thing — a stray `export XDG_STATE_HOME=` in a profile, a launcher
# that exports every name it knows whether or not it has a value — and the
# documented default has to win there too, or ext.lock lands at the filesystem
# root as /roost/ext.lock.
roost_ext__roots() {
  ROOST_EXT_DATA_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/roost"
  ROOST_EXT_STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/roost"
}

# Where the clones live. Prints the PARENT — `<data>/roost/ext` — and each
# installed extension is a directory under it, `<data>/roost/ext/<name>/`.
# Callers append the name themselves; there is no per-extension resolver,
# because the parent is what install, list and remove all iterate over.
roost_ext_data_dir()  { roost_ext__roots; printf '%s\n' "$ROOST_EXT_DATA_ROOT/ext"; }

# Where each extension's own private data lives. Again the PARENT —
# `<state>/roost/ext` — with `<state>/roost/ext/<name>/` being what one
# extension is handed as ROOST_EXT_STATE, and the only place
# `roost ext remove --purge` knows to delete.
roost_ext_state_dir() { roost_ext__roots; printf '%s\n' "$ROOST_EXT_STATE_ROOT/ext"; }

# The record of what is installed, pinned. Beside the ext/ directory rather
# than inside it: a file named ext.lock within a directory of per-extension
# subdirectories would collide with an extension called "lock".
roost_ext_lock()      { roost_ext__roots; printf '%s\n' "$ROOST_EXT_STATE_ROOT/ext.lock"; }

# The dispatch table — plain text, one line per claimed command. See
# roost_ext_index_lookup for why this file exists at all when ext.lock already
# holds the same facts.
roost_ext_index()     { roost_ext__roots; printf '%s\n' "$ROOST_EXT_STATE_ROOT/ext.index"; }

# --- validation -------------------------------------------------------------

# roost_ext_name_valid NAME -> 0 when NAME is `[a-z][a-z0-9-]*`, at most 32
# characters. This is the install DIRECTORY name, so it is kept to something
# that cannot be mistaken for a flag, a path, or a shell metacharacter.
roost_ext_name_valid() {
  # LC_ALL pinned to C for the two patterns below, and `local` puts the
  # caller's locale back on return. A bracket RANGE in a shell pattern is
  # collated by the current locale: under some locales [a-z] also matches
  # uppercase, and the check would then accept exactly the names it exists to
  # refuse.
  local name="$1" LC_ALL=C
  [ "${#name}" -le 32 ] || return 1
  case "$name" in
    ''|*[!a-z0-9-]*) return 1 ;;
  esac
  case "$name" in
    [a-z]*) return 0 ;;
  esac
  return 1
}

# roost_ext__repo_part PART -> 0 when one side of <org>/<repo> is safe to put
# on a git command line. See roost_ext_repo_valid.
roost_ext__repo_part() {
  local part="$1" LC_ALL=C
  case "$part" in
    # The design's character class, exactly.
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    # A leading dash arrives at git as a FLAG rather than as an argument.
    -*) return 1 ;;
    # The design's regex admits these, because `.` is in the class above — and
    # `../..` is the one traversal that regex is quoted alongside, so the
    # dot-only forms are refused here as well. A part that merely CONTAINS a
    # dot (`roost.dev`, `x.y`) is an ordinary repository name and stays legal.
    .|..) return 1 ;;
  esac
  return 0
}

# roost_ext_repo_valid SPEC -> 0 when SPEC is `<org>/<repo>` and safe.
#
# A SECURITY CONTROL, not a tidiness check. SPEC is about to be pasted into a
# git URL and handed to `git ls-remote` and `git clone`, where:
#
#   ../..                    escapes the clone base entirely
#   https://user:pass@host/  smuggles credentials into somebody else's fetch
#   -x/y                     arrives at git as a flag, not as an argument
#
# Nothing in this feature may build a git URL without calling this first.
roost_ext_repo_valid() {
  local spec="$1" org repo
  case "$spec" in
    # Exactly one slash. Three-part forms are how a URL and a traversal both
    # arrive, so they are refused before either part is even looked at.
    */*/*) return 1 ;;
    */*) ;;
    *) return 1 ;;
  esac
  org="${spec%%/*}"
  repo="${spec#*/}"
  roost_ext__repo_part "$org" || return 1
  roost_ext__repo_part "$repo" || return 1
  return 0
}

# roost_ext_needs_valid CSV -> 0 when every authority in CSV is one roost
# knows. Contract 1 knows exactly one: fleet.
#
# A SECURITY CONTROL in the sense that matters most here: it REFUSES what it
# does not recognise. An older roost that quietly ignored a future authority
# would grant nothing while the extension believed it had everything, and that
# surfaces as corrupted behaviour rather than as a clean refusal at install
# time. This is the one place the contract is deliberately strict rather than
# forgiving.
#
# The offending value comes back in ROOST_EXT_NEEDS_UNKNOWN rather than on
# stdout, so the caller can name it in its own refusal message: this is called
# from inside an `if`, where anything printed would go straight to the user's
# terminal. Cleared on success, so a caller under `set -u` can always read it.
roost_ext_needs_valid() {
  ROOST_EXT_NEEDS_UNKNOWN=""
  local csv="$1" need rc=0 noglob=0
  # Commas AND whitespace, NEWLINES INCLUDED. The plan names this parameter
  # CSV; roost_ext_manifest_read emits the same field space-separated; and
  # bin/roost's dispatcher reads it out of ext.index's fourth column, which
  # nothing validates. A translation step between those spellings in some
  # caller is exactly where an unknown value gets dropped on the floor.
  #
  # This was `read -r -a wanted <<<"$csv"`, and that is precisely the silent
  # ignore this function exists to prevent: `read` takes ONE line, so
  # `fleet<newline>sudo` split to just `fleet` and returned 0 with nothing
  # named, while `sudo<newline>fleet` refused correctly — a bug that reads as
  # working from either end you test it from.
  #
  # Word splitting on an unquoted expansion handles every separator at once,
  # but it also GLOBS: a needs value of `*` would expand to the filenames in
  # the caller's working directory and the refusal below would name a file
  # instead of the authority that was actually asked for. So globbing is
  # turned off across the split and put back exactly as it was found —
  # `local -` would say this in one line, and does not exist in bash 3.2,
  # which is what macOS ships and what this file is tested under.
  case "$-" in *f*) noglob=1 ;; esac
  set -f
  local IFS=$', \t\n'
  for need in $csv; do
    case "$need" in
      fleet) ;;
      *) ROOST_EXT_NEEDS_UNKNOWN="$need"; rc=1; break ;;
    esac
  done
  [ "$noglob" -eq 1 ] || set +f
  return "$rc"
}

# --- the advisory roost-version range ---------------------------------------

# roost_ext__semver_ok VERSION -> 0 when VERSION is exactly A.B.C, all digits.
roost_ext__semver_ok() {
  local v="$1" LC_ALL=C
  case "$v" in
    ''|*[!0-9.]*|.*|*.|*..*) return 1 ;;
  esac
  case "$v" in
    *.*.*.*) return 1 ;;
    *.*.*) return 0 ;;
  esac
  return 1
}

# roost_ext__semver_lt A B -> 0 when A sorts strictly below B. Both are known
# to be A.B.C by the time this is called.
roost_ext__semver_lt() {
  local a="$1" b="$2" i ai bi
  local -a ap=() bp=()
  local IFS=.
  read -r -a ap <<<"$a"
  read -r -a bp <<<"$b"
  for i in 0 1 2; do
    # `10#` so a zero-padded component is read as decimal: without it, bash
    # arithmetic reads 08 and 09 as invalid octal and the comparison dies
    # rather than answering.
    ai=$((10#${ap[$i]}))
    bi=$((10#${bp[$i]}))
    [ "$ai" -lt "$bi" ] && return 0
    [ "$ai" -gt "$bi" ] && return 1
  done
  return 1
}

# roost_ext_semver_in_range VERSION RANGE -> 0 in range, 1 out of range, 2
# unparsable.
#
# Callers WARN on 1 and on 2 and carry on. Nothing here may cause a refusal:
# the manifest's `roost` field is advisory on purpose, because a hard
# product-version gate would make every roost release a compatibility event,
# which is the cost the contract integer exists to avoid.
#
# Exactly three forms, and the smallness is the point — a richer grammar could
# only ever harden into the refusal roost has promised not to make.
roost_ext_semver_in_range() {
  local ver="$1" range="${2-}" lo hi
  case "$range" in
    # Absent or `*`: no opinion, so no need to parse VERSION either.
    ''|'*') return 0 ;;
  esac
  case "$range" in
    '>='*' <'*) ;;
    *) return 2 ;;
  esac
  lo="${range#>=}"; lo="${lo%% *}"
  hi="${range##* <}"
  # Rebuilt and compared, which is how the canonical spacing is enforced and
  # how anything hiding between the two bounds is caught: `>=1.0.0 x <2.0.0`
  # splits into two believable-looking bounds and must still be a 2.
  case "$range" in
    ">=$lo <$hi") ;;
    *) return 2 ;;
  esac
  # A prerelease or a two-component version is unparsable rather than guessed
  # at. Ordering prereleases is a real semver rule with real edge cases, and
  # getting it silently wrong here would produce a confident WRONG warning,
  # which is worse than the honest "cannot read this range" one.
  roost_ext__semver_ok "$ver" || return 2
  roost_ext__semver_ok "$lo" || return 2
  roost_ext__semver_ok "$hi" || return 2
  roost_ext__semver_lt "$ver" "$lo" && return 1   # below an INCLUSIVE lower bound
  roost_ext__semver_lt "$ver" "$hi" || return 1   # at or above an EXCLUSIVE upper bound
  return 0
}

# --- what core already owns -------------------------------------------------

# roost_ext_core_commands -> every subcommand bin/roost handles itself, one
# per line.
#
# `roost ext install` refuses a manifest that claims one of these, naming the
# collision, so an extension author is told why rather than left wondering.
# (The dispatcher makes shadowing structurally impossible as well — the lookup
# lives only in bin/roost's `*)` fallback — but a refusal at install time is
# what makes that comprehensible.)
#
# tests/test-ext.sh extracts bin/roost's own case labels and asserts the two
# lists agree. Without that test this list rots the first time somebody adds a
# subcommand, and a STALE entry here is exactly what would let an extension
# shadow `roost send` — the command that can inject a prompt into any agent.
#
# The flag spellings (--help, -V) are labels of that same case and are kept
# for that reason: the drift test compares the two lists whole, and dropping
# some labels would mean matching exclusion logic in the test, which is itself
# the drift the test exists to catch. They cost nothing, since
# roost_ext_name_valid already refuses any name that starts with a dash.
#
# printf, not a `cat <<EOF` heredoc: a heredoc through cat is a fork, and
# there is no reason to make this the one place a builtin would not do.
roost_ext_core_commands() {
  printf '%s\n' \
    up start \
    session s \
    new \
    state \
    help --help -h \
    doctor \
    validate \
    ext \
    install update \
    init \
    settings \
    whoami \
    spawn \
    split \
    hooks \
    ssh \
    send \
    read \
    screen \
    reply \
    wait-done wait \
    status \
    kill down stop \
    --version -V version
}

# --- reading JSON, honestly -------------------------------------------------

# roost_ext__json_read FILE PY_FN JQ_FN [ARG] -> run whichever JSON tool is
# present over FILE and print what it produced.
#
# Both engines answer with the SAME line protocol: either the intended output,
# or exactly one line `roost-ext-error=<message>`. That is what makes the two
# engines' refusals identical text rather than "whatever this engine happened
# to say" — and a refusal message is the thing a user actually reads.
#
# Exit status, matching roost_json_merge's degraded contract:
#   0  output on stdout
#   1  refused: FILE is missing, unparsable, or says something this cannot use
#      (message on stderr, naming what)
#   3  neither python3 nor jq is on PATH. Nothing is printed. Not an error —
#      the caller degrades rather than crashing.
#
# The engine scripts are asked for AFTER the tool check, not before: with an
# empty PATH there is no `cat` either, and an emitter run first would print
# its own noise on the way to a perfectly correct 3.
roost_ext__json_read() {
  local file="$1" py_fn="$2" jq_fn="$3" arg="${4:-}"
  local tool out rc
  roost_ext__json_lib
  tool="$(roost_json_tool)"
  [ -n "$tool" ] || return 3
  # A missing file is a 1, never a 3. Conflating the two would have the caller
  # print "install a JSON tool" advice about a repository that simply has no
  # manifest in it.
  if [ ! -f "$file" ]; then
    printf 'roost-ext: %s: no such file\n' "$file" >&2
    return 1
  fi
  # The engine's stderr is left flowing to the caller's, not captured into a
  # temp file and printed again. Its own parse message is the most useful
  # thing a user gets out of a broken manifest, and a `mktemp` here would put
  # one more external command on a path that has to keep working when there is
  # very little on PATH at all.
  case "$tool" in
    python3) out="$(python3 -c "$("$py_fn")" "$arg" < "$file")"; rc=$? ;;
    jq)      out="$(jq -r --arg arg "$arg" "$("$jq_fn")" -- "$file")"; rc=$? ;;
  esac
  if [ "$rc" -ne 0 ]; then
    # A genuine parse failure. The two engines word it differently — as
    # roost-json.sh's header says of the same split, a contract that states
    # what each engine really does beats one that pretends they agree — so the
    # engine's own words stand, with one line of context after them, and both
    # engines come back as a 1 rather than as jq's own 5.
    printf 'roost-ext: %s: could not be read as JSON\n' "$file" >&2
    return 1
  fi
  case "$out" in
    'roost-ext-error='*)
      printf 'roost-ext: %s: %s\n' "$file" "${out#roost-ext-error=}" >&2
      return 1
      ;;
  esac
  # Guarded, because `printf '%s\n' ""` would turn "no rows at all" into one
  # empty line, and roost_ext_index_write writes what this prints straight to
  # the dispatch table.
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# roost_ext__manifest_py -> the python3 engine for roost_ext_manifest_read.
#
# Every value is collected BEFORE anything is printed. A field error found
# half way through would otherwise leave `name=mark` already on stdout with
# the error line after it, and roost_ext__json_read's `roost-ext-error=` test
# would then read the pair as a successful parse.
roost_ext__manifest_py() {
  cat <<'PY'
import decimal
import json
import sys


def w(text):
    # Bytes, not str, and always UTF-8: a description with an accent or an
    # emoji in it must come back as the same bytes it went in as. Writing to
    # sys.stdout picks up whatever encoding the environment's locale gives it,
    # which is not guaranteed to be UTF-8 — and a mismatch there raises rather
    # than silently mangling, which would take a whole install down over one
    # character in a description. roost-json.sh's emitter does the same.
    sys.stdout.buffer.write(text.encode("utf-8"))


def die(msg):
    w("roost-ext-error=" + msg + "\n")
    raise SystemExit(0)


# EVERY JSON NUMBER IS READ AS A decimal.Decimal, and that is what makes this
# engine agree with jq about `contract` rather than merely claim to.
#
# jq has one number type, backed by decNumber, and it answers `tostring` with
# that library's canonical form: coefficient and exponent, `1E+2` for 1e2 and
# a plain `1` for 1e0. Python's float has neither, so this engine used to see
# a float where jq saw a `1` and refused a manifest jq installed. MEASURED on
# jq-1.7.1-apple: `1e0`, `1E0`, `1e00` and `0.1e1` all print as `1`, pass the
# pure-digits test below, and install as contract 1 -- while python3 refused
# all four. A comment here used to say the two forms "agree on every literal
# jq preserves" and blame the residual on an older jq. That was wrong on the
# shipped jq, and the one exponent literal the parity harness happened to
# carry (`1e2`) is one of the ones they DO agree about.
#
# decimal.Decimal implements the same standard decNumber does, so handing
# json the Decimal constructor for both parse_int and parse_float gives this
# engine jq's own number model, digit for digit -- verified over 40+ literals,
# including -0, 1e-2, a 30-digit integer and 1.000000000000000000001.
# Converging on jq is the only direction available: jq cannot tell `1` from
# `1e0` after parsing (both are coefficient 1, exponent 0), so the strictness
# python3 had could not be given to it. Nothing is loosened that mattered --
# `"contract": "1"` as a STRING was always accepted, so the gate was never a
# defence against a manifest writing 1 in an unusual way.
#
# THE RESIDUAL IS NOT CLOSED BY THIS, and it is worse than the number model it
# sits beside. jq's PARSER accepts JSON this one rejects: a leading-zero
# literal is invalid JSON, python3 refuses the whole document, and jq reads it.
# `"contract": 001` therefore comes back as contract `1` under jq -- which
# PASSES the hard gate and installs -- while python3 refuses the manifest
# outright. Measured through this function on both engines: `001`, `01` and
# `0001` all install on a jq machine and are refused on a python3 one.
#
# So the divergence lives in the version gate itself, and the honest statement
# is that it is open. It cannot be closed here: jq has already consumed the
# literal by the time this expression sees a number, and `001` is
# indistinguishable from `1` in its value model -- the same wall the exponent
# forms hit, in the other direction. Recorded in docs/known-gaps.md, which is
# where a shipped risk belongs; tests/test-ext.sh asserts the divergence rather
# than agreement, so it goes red if either engine ever changes.
#
# An earlier version of this comment named `007` instead, and said both engines
# refuse the install. That is true of `007` -- 7 is not 1, so jq's gate refuses
# too -- and it is exactly the wrong literal to pick: it is the leading-zero
# case where the OUTCOME happens to coincide, the same selection bias as
# choosing `1e2` from the exponent forms.
try:
    data = json.load(sys.stdin, parse_int=decimal.Decimal, parse_float=decimal.Decimal)
except Exception as exc:
    sys.stderr.write(str(exc) + "\n")
    raise SystemExit(1)
if not isinstance(data, dict):
    die("top-level JSON value must be an object")


def digits(text):
    # `^-?[0-9]+$`, the same question jq's engine asks of its own `tostring`.
    # Written out rather than imported from `re`, for the reason ctrl() gives
    # below: one comparison per character says exactly what it means.
    body = text[1:] if text[:1] == "-" else text
    return bool(body) and all("0" <= ch <= "9" for ch in body)


def scalar(key, required):
    if key not in data:
        if required:
            die("missing required field '%s'" % key)
        return ""
    value = data[key]
    # `"contract": true` is not a contract number — it is a manifest to
    # refuse, not one to read as 1. Belt and braces now that numbers arrive as
    # Decimal rather than int (a bool is not a Decimal, so it would be refused
    # by the type test alone), and kept because the intent is the point: bool
    # is an int subclass in python, so anyone re-adding `int` to the tuple
    # below would silently start reading `true` as 1 without this line.
    if isinstance(value, bool) or not isinstance(value, (str, decimal.Decimal)):
        die("field '%s' must be a string or an integer" % key)
    if isinstance(value, decimal.Decimal):
        text = str(value)
        if not digits(text):
            die("field '%s' must be a string or an integer" % key)
        return text
    return value


def strlist(key, required):
    if key not in data:
        if required:
            die("missing required field '%s'" % key)
        return ""
    value = data[key]
    if not isinstance(value, list):
        die("field '%s' must be an array" % key)
    if required and not value:
        die("field '%s' must list at least one entry" % key)
    for item in value:
        if not isinstance(item, str) or not item:
            die("field '%s' must contain only non-empty strings" % key)
        # The line this becomes is space-separated, so an entry with a space
        # in it would come back out as two entries. `item.split() != [item]`
        # is true for any whitespace at all, not only for a plain space.
        if item.split() != [item]:
            die("field '%s' has an entry with whitespace in it" % key)
    return " ".join(value)


fields = [
    ("name", scalar("name", True)),
    ("contract", scalar("contract", True)),
    ("roost", scalar("roost", False)),
    ("needs", strlist("needs", False)),
    ("commands", strlist("commands", True)),
    ("description", scalar("description", False)),
]

def ctrl(value):
    # ANY C0 control character, plus DEL -- not only the two that break this
    # function's own line protocol.
    #
    # A newline or a carriage return would turn one KEY=VALUE line into two,
    # and the caller's `while IFS== read` would take the tail of a description
    # as a key of its own. That was the whole reason for this check, and it
    # was the wrong reason: `roost` and `description` are the only free-text
    # fields in a manifest, `roost ext install` PRINTS the first one verbatim
    # in the consent block and `roost ext info` prints the second, and an ESC
    # is not a character on a terminal -- it is an instruction to one.
    #
    # A manifest carrying
    #   "roost": "*\x1b[2A\x1b[1G  commit 0000000...  (pinned)\x1b[K..."
    # repaints the commit row of the consent block. The user is shown a
    # commit that was never resolved, never cloned and never written to
    # ext.lock, and consents to it. A cruder "\x1b[8m" hides the authority
    # paragraph, the honesty paragraph and the prompt itself.
    #
    # That defeats integrity at the one point where integrity is
    # COMMUNICATED, which makes every control downstream of the prompt worth
    # nothing. So the rule is the whole class, stated in the design as: a
    # free-text manifest field is untrusted input to a terminal, and a
    # terminal is an interpreter.
    #
    # No `re` import: this is one comparison per character and it says
    # exactly what it means. The jq engine asks the same question with the
    # character class [\x00-\x1f\x7f], and tests/test-ext.sh runs an ESC
    # through both.
    for ch in value:
        if ord(ch) < 0x20 or ord(ch) == 0x7F:
            return True
    return False


# How long a field this reader will hand back, per field. Only the two
# free-text ones are here; the rest are bounded by the grammars that validate
# them (roost_ext_name_valid at 32, roost_ext_needs_valid to one known word,
# each command through roost_ext_name_valid again).
#
# THE CAP IS ABOUT THE SCREEN, not about parsing. `roost ext install` prints
# the `roost` range verbatim in the consent block, and a 1349-character value
# with no control character in it at all -- no ESC, no C1, no bidi -- pushes
# the `commit ... (pinned)` row off an 80x24 terminal by the time the prompt
# is drawn. Measured at that moment: prompt visible, pinned row not. The block
# never states anything false; it stops stating the pin at all, and the user
# approves a commit that is no longer on screen. Omission gets the same
# outcome as a forgery.
#
# 64 for a grammar whose longest legal form is about 26 characters
# (">=100.100.100 <200.200.200"), so the cap cannot be reached by anything
# honest. 200 for a description the design calls "one line".
#
# WHY THIS COULD NOT BE ESCALATED INTO A REAL FORGERY, and it is structural
# rather than lucky -- worth keeping if anyone is ever tempted to simplify the
# consent block: a value long enough to scroll is always an UNPARSABLE range,
# so `install` prints the mandatory `Note:` line, which re-prints the same
# payload at a different column offset and garbles whatever wrap alignment an
# attacker chose. A width-aligned 80-column forged block comes out as obvious
# mangled junk. The Note is load-bearing; it is not decoration.
CAPS = {"roost": 64, "description": 200}

out = []
for key, value in fields:
    if ctrl(value):
        die("field '%s' contains a control character" % key)
    # After ctrl(), so a field that is both wins on the control character --
    # the jq engine folds its cap outside `clean` for exactly this ordering.
    if key in CAPS and len(value) > CAPS[key]:
        die("field '%s' is longer than %d characters" % (key, CAPS[key]))
    out.append("%s=%s" % (key, value))
w("\n".join(out) + "\n")
PY
}

# roost_ext__manifest_jq -> the jq engine for roost_ext_manifest_read. It has
# to agree with roost_ext__manifest_py line for line and message for message:
# a machine with only jq installs extensions by these rules and a machine with
# python3 installs them by the other set, and a user comparing notes with
# another user is entitled to the same answer.
#
# A field that fails a check yields an OBJECT rather than a string, so the
# checks can be written one per field and the FIRST failure picked out
# afterwards — which is the order python3's engine reports them in, since it
# dies at the first. Distinguishing by TYPE rather than by a marker prefix
# means no legitimate value can ever be mistaken for an error.
roost_ext__manifest_jq() {
  cat <<'JQ'
# The same class python3's ctrl() asks about, and it has to be applied in
# BOTH places python3 applies it -- python3 checks every FINISHED field,
# strlist's joined output included, so a jq that only checked scalars would
# pass an ESC inside a `commands` entry that python3 refuses. `\s` is not a
# substitute: it matches whitespace, and ESC is not whitespace.
def clean($k; $v):
  if ($v | test("[\\x00-\\x1f\\x7f]")) then {err: ("field '" + $k + "' contains a control character")} else $v end;
# The same caps python3's CAPS table holds, and the same ordering: an OBJECT
# is an error already found -- by `clean`, inside scalar() -- and passes
# straight through, so a field that is both too long and carries a control
# character is reported as the control character on both engines.
#
# `length` on a jq string counts codepoints, which is what python3's len()
# counts too. Applied OUTSIDE scalar() rather than inside it, because scalar()
# is shared with fields that have no cap.
def cap($k; $v; $max):
  if ($v | type) == "object" then $v
  elif ($v | length) > $max
    then {err: ("field '" + $k + "' is longer than " + ($max | tostring) + " characters")}
  else $v end;
def scalar($k; $req):
  if has($k) then
    (.[$k] as $v
     | if ($v | type) == "string" then clean($k; $v)
       elif ($v | type) == "number" then
         # Pure digits or nothing, asked of decNumber's canonical string
         # form. python3's engine asks the identical question of the
         # identical string: it parses every JSON number with
         # decimal.Decimal, which implements the same standard, so `1.0` ->
         # "1.0" and `1e2` -> "1E+2" are refused on both while `1e0` -> "1"
         # is accepted on both.
         #
         # It did NOT used to be identical, and a comment here used to say it
         # was. python3 saw a float wherever jq saw a number, so `1e0`, `1E0`,
         # `1e00` and `0.1e1` installed on a jq machine as contract 1 and were
         # refused on a python3 one. See the long comment above
         # roost_ext__manifest_py's json.load for the measurement, and for why
         # converging on jq was the only direction available.
         (if ($v | tostring | test("^-?[0-9]+$")) then ($v | tostring)
          else {err: ("field '" + $k + "' must be a string or an integer")} end)
       else {err: ("field '" + $k + "' must be a string or an integer")} end)
  elif $req then {err: ("missing required field '" + $k + "'")}
  else "" end;
def strlist($k; $req):
  if has($k) then
    (.[$k] as $v
     | if ($v | type) != "array" then {err: ("field '" + $k + "' must be an array")}
       elif ($req and ($v | length) == 0)
         then {err: ("field '" + $k + "' must list at least one entry")}
       elif any($v[]; (type != "string") or (. == ""))
         then {err: ("field '" + $k + "' must contain only non-empty strings")}
       elif any($v[]; test("\\s"))
         then {err: ("field '" + $k + "' has an entry with whitespace in it")}
       else clean($k; ($v | join(" "))) end)
  elif $req then {err: ("missing required field '" + $k + "'")}
  else "" end;
if type != "object" then ["roost-ext-error=top-level JSON value must be an object"]
else
  [ ["name",        scalar("name"; true)],
    ["contract",    scalar("contract"; true)],
    ["roost",       cap("roost"; scalar("roost"; false); 64)],
    ["needs",       strlist("needs"; false)],
    ["commands",    strlist("commands"; true)],
    ["description", cap("description"; scalar("description"; false); 200)] ] as $f
  | ([$f[] | select((.[1] | type) == "object")] | first) as $bad
  | if $bad != null then ["roost-ext-error=" + $bad[1].err]
    else [$f[] | .[0] + "=" + .[1]] end
end
| .[]
JQ
}

# roost_ext_manifest_read FILE -> print one KEY=VALUE line for each of name,
# contract, roost, needs, commands and description, in that order.
#
# `needs` and `commands` are space-separated. An absent OPTIONAL field is
# printed empty rather than omitted, so a caller always sees the same six keys
# and cannot mistake a missing line for a missing file.
#
# What it does NOT do is judge the values: a bad `name` is read out and handed
# to roost_ext_name_valid, a `needs` to roost_ext_needs_valid, a `contract` to
# whatever gate the caller applies. Keeping every refusal in one place is what
# lets `roost ext install` print one message per problem at consent time
# instead of a different one per layer.
#
# Exit status is roost_ext__json_read's: 0, 1 (naming what), or 3 when neither
# python3 nor jq is present — the same degraded contract as roost_json_merge.
roost_ext_manifest_read() {
  roost_ext__json_read "$1" roost_ext__manifest_py roost_ext__manifest_jq
}

# --- integrity --------------------------------------------------------------

# roost_ext__git ARGS... -> git, hardened, for the calls this library makes.
#
# The same three measures scripts/roost-ext's `_ext_git` carries, and here for
# the same reason rather than for symmetry. roost_ext_tree_hash runs git
# INSIDE an extension's directory -- during `roost ext install`, and again
# during every `roost ext verify` -- and the design names
# `core.hooksPath=/dev/null` precisely because "the clone is not the only path
# that reads a config". This is that path, and it was unhardened: with
# core.hooksPath and init.templateDir set in a user's own global config,
# `reference-transaction` and `post-index-change` hooks fire during an install
# that has just promised nothing runs.
#
# Those are the USER'S OWN hooks, not an attacker's -- no manifest chooses
# them -- so this is not an escalation, and the promise it breaks is still the
# one printed at the prompt.
#
# `-c init.templateDir=` on top of the hooksPath override: hooksPath alone
# stops a hook being FOUND, and the empty template stops one being COPIED into
# the throwaway object database in the first place. Measured: with a template
# dir configured, `git init --bare` writes its hooks into the new repository
# unless this is set.
#
# WHAT IT DOES NOT CLOSE, stated rather than implied: `git add` runs a CLEAN
# filter, and a filter is chosen by the extension's own in-tree .gitattributes
# even though the command behind it comes from the user's config.
# GIT_LFS_SKIP_SMUDGE governs the smudge direction only, and git has no
# blanket "no filters" switch for `add`. So a user who has configured an LFS
# clean filter, installing an extension whose .gitattributes asks for it, runs
# that filter here. It is the user's own configured program, the same class as
# the hooks above, and it is written down rather than left to be discovered.
#
# `-C /` closes a different door from the three above, and scripts/roost-ext's
# `_ext_git` carries the measurement behind it: git reads a repository's config
# whenever it DISCOVERS one by walking up from the current directory, with no
# `-C` and no `GIT_DIR` involved. Every call here already sets an explicit
# GIT_DIR, which suppresses discovery on its own -- except `init`, which does
# not, and which reads `init.templateDir` from whatever repository it found.
# `/` needs no creation and has no parent to walk up into, and it goes FIRST so
# a caller's own `-C <dir>` still wins; every `-C` in this feature is an
# ABSOLUTE path, which is what makes that composition safe.
#
# It does not close every config key, and no comment here should say it does:
# the user's own ~/.gitconfig and /etc/gitconfig are read exactly as they are
# for every other git on the machine. The claim is the mechanism -- an
# extension's own config is never the repository git resolves.
roost_ext__git() {
  GIT_LFS_SKIP_SMUDGE=1 git -C / -c core.hooksPath=/dev/null -c init.templateDir= "$@"
}

# roost_ext_tree_hash DIR -> the git tree hash of DIR's contents.
#
# The integrity control's arithmetic: `roost ext install` records what this
# prints, `roost ext verify` recomputes it, and both call THIS function, so
# the two can never drift into two slightly different definitions of "the
# contents of that directory" — which is where a hand-rolled walk over sorted
# filenames eventually ends up.
#
# Git's own plumbing does the hashing: same bytes, same names, same executable
# bits, same 40-character id. For a freshly cloned working tree the answer IS
# the commit's own tree hash, which is what makes the recorded value auditable
# against the repository it came from.
#
# For whoever writes `roost ext install`: record THIS, not
# `git rev-parse HEAD^{tree}`. The two agree on a clean clone and stop
# agreeing the moment the directory carries anything the commit does not.
roost_ext_tree_hash() {
  local dir="$1" tmp tree=""
  [ -d "$dir" ] || return 1
  # Made absolute before anything else touches it. `git -C "$dir"` chdirs
  # first, so a RELATIVE GIT_WORK_TREE would then resolve against DIR itself
  # and point at DIR/DIR -- which fails safe, but returns the same bare 1 as
  # "that is not a directory" and would have a caller chasing the wrong thing.
  # Parameter expansion, not a `cd && pwd` subshell: no fork, and nothing here
  # needs the symlinks resolved.
  case "$dir" in /*) ;; *) dir="$PWD/$dir" ;; esac
  tmp="$(mktemp -d)" || return 1
  # A throwaway object database. The tree objects have to be written
  # somewhere, and writing them into the extension's own clone would make a
  # read-only integrity check mutate the very thing it is checking.
  if roost_ext__git init -q --bare "$tmp/odb" >/dev/null 2>&1; then
    # `:(exclude).git` is not tidiness. The clone's .git holds ref state and
    # changes on every fetch, so including it would have `roost ext verify`
    # cry tamper at a no-op — and, since .git is itself a repository, git
    # would record it as a gitlink to whatever HEAD happened to be.
    #
    # --force so the extension's own .gitignore cannot hide a file from the
    # hash. What is hashed is what is ON DISK, not what the repository chose
    # to track: a file dropped into the clone after install is exactly what
    # verify exists to notice.
    #
    # A separate GIT_INDEX_FILE for the same reason as the separate object
    # database — the clone's own index is never touched.
    if GIT_DIR="$tmp/odb" GIT_WORK_TREE="$dir" GIT_INDEX_FILE="$tmp/index" \
       roost_ext__git -C "$dir" add -A --force -- . ':(exclude).git' >/dev/null 2>&1; then
      tree="$(GIT_DIR="$tmp/odb" GIT_WORK_TREE="$dir" GIT_INDEX_FILE="$tmp/index" \
              roost_ext__git write-tree 2>/dev/null)"
    fi
  fi
  rm -rf "$tmp"
  [ -n "$tree" ] || return 1
  printf '%s\n' "$tree"
}

# roost_ext__link_escapes REL TARGET -> 0 when a symlink at REL (a path
# RELATIVE to the extension directory) pointing at TARGET resolves outside
# that directory; 1 when it stays inside.
#
# Lexical, not filesystem: the answer must be the same whether or not the
# target exists, because a link pointing at a file that is not there today is
# a link pointing at a file that may be there tomorrow -- and `readlink -f`
# and `realpath` disagree about a missing target, and macOS ships neither in
# the GNU spelling this would need.
#
# The rule is two lines: an ABSOLUTE target escapes by definition, and a
# relative one escapes when normalising it takes the depth below zero. That
# second test is deliberately conservative -- `../ext/name/x` from the root of
# the extension dips to -1 and is refused even though it lands back inside --
# because the alternative is resolving a path against a tree an attacker
# wrote, and "refuse a link nobody has a reason to write" costs nothing.
#
# It is also what makes checking each link ON ITS OWN sufficient. Every link
# that survives this is relative AND lands inside, so a chain of them cannot
# reach out either: the first link that could have provided the way out is
# refused before the chain is ever followed.
roost_ext__link_escapes() {
  local rel="$1" target="$2" base full comp depth=0 esc=0 noglob=0
  case "$target" in
    # readlink printing nothing at all. Not a link this can reason about, and
    # the direction to fail is towards refusing it.
    '') return 0 ;;
    /*) return 0 ;;
  esac
  # The link resolves against the directory it SITS IN, not against the root.
  # `bin/x -> ../../etc/passwd` is two levels up from bin/, which is one level
  # outside the extension -- getting this wrong in the safe-looking direction
  # would read every link as if it were at the top.
  base="${rel%/*}"
  [ "$base" = "$rel" ] && base=""
  if [ -n "$base" ]; then full="$base/$target"; else full="$target"; fi
  # Word splitting on an unquoted expansion also GLOBS, and a path component
  # containing `*` would expand against the caller's working directory and be
  # counted as however many files happen to be there. Off across the split and
  # put back exactly as it was found -- `local -` would say this in one line
  # and does not exist in bash 3.2, which is what macOS ships.
  case "$-" in *f*) noglob=1 ;; esac
  set -f
  local IFS=/
  for comp in $full; do
    case "$comp" in
      # An empty component is a doubled slash; `.` is a no-op.
      ''|.) ;;
      ..)
        depth=$((depth-1))
        # An `if`, not `[ ... ] && esc=1`: a false test on the LAST iteration
        # would make the whole `for` return 1, and a caller under `set -e`
        # would take that as this function failing rather than as this
        # component not being the one that escaped.
        if [ "$depth" -lt 0 ]; then esc=1; fi
        ;;
      *) depth=$((depth+1)) ;;
    esac
  done
  [ "$noglob" -eq 1 ] || set +f
  if [ "$esc" -eq 1 ]; then return 0; fi
  return 1
}

# roost_ext_tree_hostile DIR -> 0 when DIR carries something an install must
# REFUSE, naming it in ROOST_EXT_HOSTILE_FOUND; 1 when it carries none of
# them. Cleared on entry, so a caller under `set -u` can always read it.
#
# A SECURITY CONTROL, and the second half of what makes the consent block's
# "nothing runs during install" true. `roost ext install` hardens the CLONE so
# git executes nothing on the way in -- --no-recurse-submodules,
# GIT_LFS_SKIP_SMUDGE=1, -c core.hooksPath=/dev/null -- and this is the check
# on what actually arrived, run after cloning and before anything is moved
# into place. Two findings, both from the design's "The install must actually
# run nothing":
#
#   a symlink resolving OUTSIDE the extension directory. That directory is
#   deleted whole by `roost ext remove`, hashed whole by `roost ext verify`
#   and replaced whole by `roost ext update`; a link out of it turns each of
#   those into an operation on somebody else's files.
#
#   a setuid or setgid FILE. Nothing in this contract needs one, and a
#   program carrying one is a privilege boundary sitting inside a directory
#   the user was told holds an ordinary program.
#
# Returns 0 for "found something", which reads backwards until you write the
# caller: `if roost_ext_tree_hostile "$dir"; then refuse; fi`. That is the
# same shape scripts/roost-ext's `_ext_index_disagrees` uses, and a security
# check is worth making easy to write in the refusing direction.
#
# DIRECTORIES are deliberately excluded from the setgid sweep. On macOS and
# the BSDs a new directory INHERITS setgid from its parent, so a clone made
# below a setgid temp directory carries the bit on every directory it created
# -- refusing that would refuse an ordinary install for a property of the
# machine's /tmp rather than for anything the repository did. On a file the
# bit is the whole risk; on a directory it is a group-ownership convention.
#
# .git is skipped for the same reason roost_ext_tree_hash excludes it: git
# built it, not the manifest author, and nothing under it is executed, hashed
# or moved by this feature.
#
# What this does NOT do is judge the code. It finds two specific things and
# names them. An extension that passes has had two questions answered about
# it, and roost has still not checked whether the program is honest -- see the
# consent block, which says so in those words every single time.
roost_ext_tree_hostile() {
  ROOST_EXT_HOSTILE_FOUND=""
  local dir="$1" found link target rel
  if [ ! -d "$dir" ]; then
    ROOST_EXT_HOSTILE_FOUND="not a directory: $dir"
    return 0
  fi
  # Absolute before find is asked anything, so the `${link#$dir/}` below
  # really does strip a prefix -- the same reason roost_ext_tree_hash makes it
  # absolute first.
  case "$dir" in /*) ;; *) dir="$PWD/$dir" ;; esac

  # No `| head -1`. Under `set -o pipefail`, which scripts/roost-ext runs
  # with, head closing the pipe early can take find down with SIGPIPE and the
  # whole substitution reports failure -- on a run that FOUND something, which
  # is the run that must not be mistaken for an error. The first line is taken
  # with parameter expansion instead, and nothing forks.
  found="$(find "$dir" -path "$dir/.git" -prune -o -type f \( -perm -4000 -o -perm -2000 \) -print 2>/dev/null)" || found=""
  found="${found%%
*}"
  if [ -n "$found" ]; then
    ROOST_EXT_HOSTILE_FOUND="a setuid or setgid file: ${found#"$dir/"}"
    return 0
  fi

  found="$(find "$dir" -path "$dir/.git" -prune -o -type l -print 2>/dev/null)" || found=""
  # A here-document rather than a pipe, so the loop body runs in THIS shell
  # and the variable it sets survives -- a `find ... | while read` would set
  # ROOST_EXT_HOSTILE_FOUND in a subshell and return as if it had found
  # nothing.
  while IFS= read -r link || [ -n "$link" ]; do
    [ -n "$link" ] || continue
    rel="${link#"$dir/"}"
    target="$(readlink "$link" 2>/dev/null)" || target=""
    if roost_ext__link_escapes "$rel" "$target"; then
      ROOST_EXT_HOSTILE_FOUND="a symlink pointing outside the extension: $rel -> $target"
      return 0
    fi
  done <<EOF
$found
EOF
  return 1
}

# --- the dispatch table -----------------------------------------------------

# roost_ext_index_lookup CMD -> print the executable that claims CMD.
#
# THE HOT PATH. This runs on every mistyped `roost` subcommand, because the
# dispatcher lives in bin/roost's `*)` fallback — which is precisely what
# makes shadowing a core command structurally impossible rather than merely
# refused at install time.
#
# So: no JSON tool, no external command, and no command substitution. Not
# style. scripts/lib/roost-json.sh opens by recording the standing decision
# that neither python3 nor jq is a runtime dependency of roost; parsing
# ext.lock here would have made one of them exactly that, quietly, and that is
# the whole reason ext.index exists as a plain text file when ext.lock already
# holds the same facts. A `$(roost_ext_index)` for the path would be a fork
# per typo, so the path is built from what roost_ext__roots SETS.
#
# The name, the path and the AUTHORITY come back in ROOST_EXT_LOOKUP_NAME,
# ROOST_EXT_LOOKUP_PATH and ROOST_EXT_LOOKUP_NEEDS, for the dispatcher: it
# needs the extension's NAME for its directories, and it must call this WITHOUT
# a `$(...)` — a command substitution there would reintroduce the very fork
# this function exists to avoid — so it redirects stdout away and reads the
# variables instead. All three are cleared on entry, so a caller under `set -u`
# can always read them.
#
# The fourth column is why this function answers about authority at all.
# roost_ext_index_write resolves `needs` out of ext.lock with a real JSON
# parser, once, at install and removal time, and writes it here; the
# dispatcher reads it off the line it was already reading. It must NEVER be
# re-derived from ext.lock on this path. The first attempt did that with a
# shell reader and it granted `fleet` to an extension whose lockfile entry
# declared none — two ordinary strings in the entry, `"description": "needs"`
# and `"commands": ["fleet"]`, were enough to steer it. Both files live in the
# same 0600 state directory, so carrying the decision forward moves no trust
# boundary; re-deriving it cheaply moved a security decision onto a parser
# that was never one.
#
# A MISSING fourth column is no authority, which is what a hand-edited line
# and every line an older roost wrote both look like. Fail closed, silently,
# because "no authority" is the safe reading of a line that does not say.
roost_ext_index_lookup() {
  ROOST_EXT_LOOKUP_NAME=""
  ROOST_EXT_LOOKUP_PATH=""
  ROOST_EXT_LOOKUP_NEEDS=""
  local want="$1" cmd name path needs index
  roost_ext__roots
  index="$ROOST_EXT_STATE_ROOT/ext.index"
  [ -f "$index" ] || return 1
  # IFS pinned to TAB alone: an extension's install path can contain spaces
  # (an XDG_DATA_HOME under "Application Support" is enough), and the default
  # IFS would split one path into several fields.
  local IFS=$'\t'
  # `|| [ -n "$cmd" ]` so a final line with no trailing newline is still read.
  # A hand-edited ext.index is exactly the case this has to survive.
  while read -r cmd name path needs || [ -n "$cmd" ]; do
    # Surrounding whitespace off every field, because "a hand-edited ext.index
    # has to survive" has to mean it. A trailing space after a path — an
    # editor stripping or adding one, a line pasted out of a terminal — used
    # to make `[ -x "$path" ]` false and turn an installed command back into
    # "unknown subcommand" with nothing printed to say why. It also catches
    # the `\r` of a file that has been through a CRLF editor.
    #
    # Parameter expansion, not `sed` or `tr`: this is the no-fork path. Only
    # the command is trimmed for every line; the rest is trimmed once, on the
    # line that matched.
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"; cmd="${cmd%"${cmd##*[![:space:]]}"}"
    [ "$cmd" = "$want" ] || continue
    name="${name#"${name%%[![:space:]]*}"}";  name="${name%"${name##*[![:space:]]}"}"
    path="${path#"${path%%[![:space:]]*}"}";  path="${path%"${path##*[![:space:]]}"}"
    needs="${needs#"${needs%%[![:space:]]*}"}"; needs="${needs%"${needs##*[![:space:]]}"}"
    # The LOCKFILE, not the clone, is the record of what is installed. So a
    # clone whose files have gone away degrades to "unknown subcommand" rather
    # than to exec'ing whatever now sits at that path.
    [ -x "$path" ] || return 1
    ROOST_EXT_LOOKUP_NAME="$name"
    ROOST_EXT_LOOKUP_PATH="$path"
    ROOST_EXT_LOOKUP_NEEDS="$needs"
    printf '%s\n' "$path"
    return 0
  done < "$index"
  return 1
}

# roost_ext__index_py -> the python3 engine for roost_ext_index_write.
roost_ext__index_py() {
  cat <<'PY'
import json
import sys

data_dir = sys.argv[1]


def w(text):
    sys.stdout.buffer.write(text.encode("utf-8"))


def die(msg):
    w("roost-ext-error=" + msg + "\n")
    raise SystemExit(0)


# esc TEXT -> TEXT with every C0 control character and DEL replaced by `?`,
# truncated to 64 characters.
#
# Every message below names back a piece of the LOCKFILE -- an entry name, a
# command -- and roost_ext__json_read prints that message to stderr, which is
# a terminal. An ESC is not a character on a terminal: it is an instruction to
# one, so an entry name of "a\x1b[2A\x1b[1G b" repaints the lines above the
# refusal it is being complained about in. MEASURED: the raw ESC reached
# stderr from both engines, on the regeneration-failure path of install,
# update and remove.
#
# The sibling readers already close this: scripts/roost-ext's _ext_lock_rows
# engines carry esc() on every message for exactly this reason, and
# roost_ext__manifest_py's ctrl() asks the same question of a manifest's
# free-text fields. This is that rule applied to the third pair, which is the
# one deciding a GRANT.
#
# The truncation is the second half, and it is the lesson the `roost` field's
# CAPS table records: a value with no control character in it at all, merely
# long, pushes what matters off the screen. Nothing honest reaches 64 here --
# roost_ext_name_valid stops a real name at 32 -- so the cap can only ever
# fire on a lockfile edited by hand.
def esc(text):
    clean = "".join("?" if ord(ch) < 0x20 or ord(ch) == 0x7F else ch for ch in text)
    return clean if len(clean) <= 64 else clean[:64] + "..."


try:
    lock = json.load(sys.stdin)
except Exception as exc:
    sys.stderr.write(str(exc) + "\n")
    raise SystemExit(1)
if not isinstance(lock, dict):
    die("top-level JSON value must be an object")

rows = []
claimed = {}
# sorted(), so the collision message below names the same pair whichever order
# the lockfile happened to be written in.
for name in sorted(lock):
    entry = lock[name]
    if not isinstance(entry, dict):
        die("entry '%s' is not an object" % esc(name))
    commands = entry.get("commands")
    if not isinstance(commands, list) or not commands:
        die("entry '%s' lists no commands" % esc(name))
    # Whitespace in a name or a command would write a line this file's own
    # reader could not read back. Refused rather than escaped: that reader is
    # a `while read` with no unescaping in it, and adding one would put a
    # parser back on the hot path.
    if name.split() != [name] or "/" in name:
        die("entry name '%s' is not a plain word" % esc(name))
    # The authority column. Resolved HERE, where a real JSON parser is
    # reading the lockfile anyway, and carried forward to the dispatcher --
    # which must never re-derive it from ext.lock with something cheaper.
    # The first attempt at this feature did exactly that, with a shell reader
    # that matched the bytes `"needs"` anywhere in an entry, and two ordinary
    # string values out of the extension's own manifest steered it: a
    # `"description": "needs"` beside a `"commands": ["fleet"]` handed the
    # fleet to an entry whose needs was `[]`. The general rule, and it is in
    # the design now: decide a grant where a real parser is available, carry
    # the decision, never re-derive it somewhere cheaper.
    #
    # An ABSENT needs is no authority. A needs that is not an array -- null
    # included -- is refused rather than read as none, because a lockfile
    # saying something this cannot understand about authority is not a
    # lockfile to guess at.
    if "needs" in entry:
        needs = entry["needs"]
        if not isinstance(needs, list):
            die("entry '%s' declares a needs that is not an array" % esc(name))
    else:
        needs = []
    for need in needs:
        # Whitespace would split one authority into two inside a field that
        # is itself space-separated, and the second half would be dropped by
        # whoever read it back. Refused, for the same reason a command with a
        # space in it is.
        if not isinstance(need, str) or not need or need.split() != [need]:
            die("entry '%s' declares an authority that is not a plain word" % esc(name))
    # NOT validated against the authorities roost knows -- that is
    # roost_ext_needs_valid's job, and it happens in the dispatcher, on the
    # value it is actually about to act on. Writing the index is not the
    # place to decide what `fleet` means.
    needs_field = " ".join(needs)
    for command in commands:
        if (not isinstance(command, str) or not command
                or command.split() != [command] or "/" in command):
            die("entry '%s' claims a command that is not a plain word" % esc(name))
        # An ambiguous dispatch table is worse than no dispatch table: which
        # extension ran would depend on the order the lockfile was written in.
        # Refused and named. `roost ext install` refuses the collision long
        # before this, so reaching it means the lockfile was edited by hand.
        if command in claimed:
            die("command '%s' is claimed by both '%s' and '%s'"
                % (esc(command), esc(claimed[command]), esc(name)))
        claimed[command] = name
        rows.append((command, name, needs_field))

rows.sort()
# The authority column is written even when it is EMPTY, so every line has the
# same four fields and `awk -F'\t'` on this file means the same thing on every
# row. A hand edit that drops the trailing tab still reads back as no
# authority, which is the direction every failure here has to fall.
w("".join("%s\t%s\t%s/%s/bin/roost-%s\t%s\n" % (c, n, data_dir, n, c, s)
          for c, n, s in rows))
PY
}

# roost_ext__index_jq -> the jq engine for roost_ext_index_write, agreeing
# with roost_ext__index_py line for line. $arg is the extension data
# directory. As in the manifest engine, a failed check yields an OBJECT where
# a good row yields an array, so no legitimate row can be mistaken for an
# error.
roost_ext__index_jq() {
  cat <<'JQ'
# esc($s) -> $s with every C0 control character and DEL replaced by `?`, then
# truncated to 64 characters. The python3 engine's esc() carries the reasons
# at length: every message below names a piece of the LOCKFILE back to a
# terminal, an ESC is an instruction to a terminal rather than a character in
# it, and a merely LONG value pushes what matters off the screen without
# using one. `length` counts codepoints here and python3's len() counts them
# there, so the two truncate at the same character.
def esc($s): ((($s | gsub("[\\x00-\\x1f\\x7f]"; "?"))) as $t
              | if ($t | length) > 64 then (($t[0:64]) + "...") else $t end);
if type != "object" then ["roost-ext-error=top-level JSON value must be an object"]
else
  [ to_entries | sort_by(.key)[]
    | .key as $n | .value as $e
    # The authority column, resolved by the same real parser that resolves
    # the rest of the row. `has("needs")` and not `// []`: a needs of null is
    # a lockfile saying something this cannot understand about authority, and
    # `//` would quietly read it as none. python3's engine refuses it too.
    | (if ($e | type) == "object" and ($e | has("needs")) then $e.needs else [] end) as $needs
    | if ($e | type) != "object" then {err: ("entry '" + esc($n) + "' is not an object")}
      elif (($e.commands | type) != "array") or (($e.commands | length) == 0)
        then {err: ("entry '" + esc($n) + "' lists no commands")}
      # `($n == "")` FIRST, and it is not decoration: python3 asks
      # `name.split() != [name]`, and "".split() is the empty LIST, so python3
      # refuses an empty name while `test("\\s")` on an empty string is false
      # and jq accepted it. A machine with only jq then wrote an ext.index for
      # a lockfile python3 refuses, with no SECURITY WARNING raised, while a
      # machine with python3 refused the same file -- two machines disagreeing
      # about whether to raise a warning this code itself calls a security
      # control. The sibling check on `commands`, four lines down, has carried
      # its own `(. == "")` from the start; this is the same guard on the name.
      elif ($n == "") or ($n | test("\\s")) or ($n | contains("/"))
        then {err: ("entry name '" + esc($n) + "' is not a plain word")}
      elif any($e.commands[]; (type != "string") or (. == "") or test("\\s") or contains("/"))
        then {err: ("entry '" + esc($n) + "' claims a command that is not a plain word")}
      elif ($needs | type) != "array"
        then {err: ("entry '" + esc($n) + "' declares a needs that is not an array")}
      elif any($needs[]; (type != "string") or (. == "") or test("\\s"))
        then {err: ("entry '" + esc($n) + "' declares an authority that is not a plain word")}
      else ($e.commands[] | [., $n, ($needs | join(" "))]) end ] as $rows
  | ([$rows[] | select(type == "object")] | first) as $bad
  | if $bad != null then ["roost-ext-error=" + $bad.err]
    else ($rows | sort_by(.[0])) as $sorted
      | ([$sorted[] | .[0]] | group_by(.) | map(select(length > 1)) | first) as $dup
      | if $dup != null then
          ([$sorted[] | select(.[0] == $dup[0])]) as $both
          | ["roost-ext-error=command '" + esc($dup[0]) + "' is claimed by both '"
             + esc($both[0][1]) + "' and '" + esc($both[1][1]) + "'"]
        else [$sorted[] | .[0] + "\t" + .[1] + "\t" + $arg + "/" + .[1] + "/bin/roost-" + .[0] + "\t" + .[2]]
        end
    end
end
| .[]
JQ
}

# roost_ext_index_write -> regenerate ext.index from ext.lock, atomically.
#
# ext.lock is the record; ext.index is the dispatch table derived from it.
# Both are written in the same step at install and at removal time so they
# cannot disagree about what is installed.
#
# A MISSING lockfile is not an error. It is what a machine with nothing
# installed looks like, and it is also what `roost ext remove` leaves behind
# when it takes the last extension out — the index has to become empty there
# rather than stay stale, because a stale index is a dispatch table pointing
# at a clone that is gone.
#
# Exit status: 0 written, 1 the lockfile says something this cannot use
# (message on stderr, naming what), 3 neither python3 nor jq is present and
# there is a lockfile that needs reading.
roost_ext_index_write() {
  local lock index out="" rc tmp
  roost_ext__roots
  lock="$ROOST_EXT_STATE_ROOT/ext.lock"
  index="$ROOST_EXT_STATE_ROOT/ext.index"
  if [ -f "$lock" ]; then
    out="$(roost_ext__json_read "$lock" roost_ext__index_py roost_ext__index_jq \
           "$ROOST_EXT_DATA_ROOT/ext")"
    rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
  fi
  mkdir -p -- "$ROOST_EXT_STATE_ROOT" || return 1
  # A temp file in the SAME directory, then a rename: a `roost` invocation
  # that reads the index while an install is rewriting it sees the old file or
  # the new one, never a half-written dispatch table. Across filesystems the
  # rename would stop being atomic, which is why the temp file is not in /tmp.
  #
  # mktemp's 0600 is kept rather than widened. This is one user's own state
  # directory, every reader of it runs as that user, and the file names every
  # executable roost is willing to hand control to — nothing about it wants a
  # wider mode than the lockfile beside it.
  tmp="$(mktemp "$ROOST_EXT_STATE_ROOT/.roost-ext-index.XXXXXX")" || return 1
  if [ -n "$out" ]; then
    printf '%s\n' "$out" > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  mv "$tmp" "$index"
}
