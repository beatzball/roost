# roost-have.sh — is a harness REALLY on PATH? Sourced, never executed.
#
# POSIX sh, because shims/opencode sources it and runs on whatever /bin/sh the
# machine has; the bash scripts source it too.
#
# Why not `command -v NAME`: inside a roost pane, roost's own shim directory
# (shims/, marked by its .roost-shim file) is first on PATH, and it holds a
# `claude` and an `opencode` that are roost's wrappers, not the harnesses.
# `command -v opencode` then answers "yes" on a machine with no opencode at
# all. Every place roost asks "is this harness installed?" — install's list of
# harnesses to wire, doctor's opencode checks, the opencode version probe that
# `roost wiring` decides OPENCODE_CONFIG_DIR from, validate, revive — would
# act on a harness that is not there. The version probe is the one with a
# consequence: a wrapper with no real opencode behind it prints no version,
# and `roost wiring` reads "on PATH, version unknown" as not safe and leaves
# OPENCODE_CONFIG_DIR unset (scripts/lib/roost-opencode.sh says why).
#
# So these skip every PATH entry holding .roost-shim, by the same marker rule
# the shims use to find the real binary behind themselves. Skipping by marker
# rather than by comparing against one checkout's shims/ means a second
# checkout's shim directory on the same PATH is skipped too.

# roost_which NAME -> print the path of the first executable NAME on PATH that
# is not in a roost shim directory; return 1, printing nothing, if there is
# none.
#
# Executables only, like the shims' own lookup: not functions, aliases or
# builtins, which `command -v` would also report. A harness is a program, and
# these callers go on to run it or link an adapter for it.
#
# An empty PATH entry, or `.`, means the current directory to a POSIX shell.
# It is skipped, as the shims skip it: the answer to "is opencode installed?"
# must not depend on which directory the question was asked from.
#
# `set -f` because an unquoted $PATH is split on IFS and then globbed; a PATH
# entry containing `*` would otherwise expand. The caller's noglob state and
# IFS are put back exactly as they were.
roost_which() {
  _rw_name="$1" _rw_found="" _rw_ifs="$IFS" _rw_glob=1
  case $- in *f*) _rw_glob=0 ;; esac
  set -f
  IFS=:
  for _rw_d in $PATH; do
    case "$_rw_d" in '' | .) continue ;; esac
    [ -f "$_rw_d/.roost-shim" ] && continue
    if [ -f "$_rw_d/$_rw_name" ] && [ -x "$_rw_d/$_rw_name" ]; then
      _rw_found="$_rw_d/$_rw_name"
      break
    fi
  done
  IFS="$_rw_ifs"
  [ "$_rw_glob" = 1 ] && set +f
  [ -n "$_rw_found" ] || return 1
  printf '%s\n' "$_rw_found"
}

# roost_have NAME -> 0 when roost_which finds a real NAME, 1 otherwise.
roost_have() { roost_which "$1" >/dev/null; }

# roost_opencode_is_mini ARGS... -> 0 when that opencode command line starts
# `opencode mini`, the minimal interface (opencode 2.x).
#
# Why roost cares: `opencode mini` does not load terminal-side plugins, and
# roost's opencode 2 adapter (adapters/opencode/v2/tui.js) is one. Measured on
# opencode 2.1.3, isolated, with a spy plugin under plugins/: the full TUI
# called its setup() and `opencode mini`, fully started, never did. So a mini
# pane never badges, `roost read` has no reply for it, and `roost wait-done`
# cannot see its turn end. shims/opencode refuses it in a roost pane, and
# `roost doctor` names a pane already running it — both through this one rule,
# so the two cannot disagree about what "mini" is.
#
# The rule: the first argument that is not a flag is the word `mini`. opencode
# takes `[<directory>]` and a subcommand in the same place, and `mini` there is
# the subcommand. A flag's VALUE is not that argument: `opencode -s mini` is a
# session named mini, and `opencode --log-level debug mini` is still mini. The
# flags that take a separate value are the ones `opencode --help` and
# `opencode mini --help` list with one on 2.1.3 — `--log-level`,
# `--completions`, `--server`, `--session`/`-s`, `--prompt`, and mini's own
# `--model`/`-m`, `--agent`, `--replay-limit`. `--flag=value` is one word and
# needs nothing. Anything after `--` is not looked at.
#
# Not version-checked. opencode 1.x has no `mini` subcommand, so there the
# same words mean a project directory named mini — asking the version would
# cost about half a second on every `opencode` typed in a roost pane to spare
# that one case, and the refusal names the way past it.
roost_opencode_is_mini() {
  _rm_skip=0
  for _rm_a in "$@"; do
    if [ "$_rm_skip" = 1 ]; then _rm_skip=0; continue; fi
    case "$_rm_a" in
      --) return 1 ;;
      --log-level|--completions|--server|--session|-s|--prompt|--model|-m|--agent|--replay-limit)
        _rm_skip=1 ;;
      -*) : ;;
      mini) return 0 ;;
      *) return 1 ;;
    esac
  done
  return 1
}
