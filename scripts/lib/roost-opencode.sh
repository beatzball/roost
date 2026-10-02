# roost-opencode.sh — which opencode is on PATH. Sourced, never executed.
#
# One definition, because two callers act on the answer and must not disagree:
# `roost doctor` reports it, and `roost wiring` decides from it whether to set
# OPENCODE_CONFIG_DIR at all (#150, #154). A doctor that read "1.x" beside a
# wiring that read "2.x" would tell the user their panes are wired while the
# server had declined to wire them.
#
# Why the major version matters at all: roost's opencode adapter and roost's
# wiring were both built on opencode 1.x, and 2.x changed the two things they
# stand on. It has a different plugin shape, so it refuses adapters/opencode/
# roost.js at load. And it reads OPENCODE_CONFIG_DIR INSTEAD of the user's
# config directory, where 1.x reads it AS WELL — measured, see roost_opencode_v2
# below.

# roost_opencode_version -> print the version number of the `opencode` on PATH,
# or nothing. Never fails, and never takes more than about six seconds.
#
# `--version` prints `1.18.30` on 1.x and `opencode v2.0.20` on 2.x, so the
# number is taken from wherever the first digit is rather than from the start
# of the line. On 2.x it starts no background service — checked, because 2.x
# starts one for most other commands and neither caller may leave a server
# behind.
#
# Asking is not free, which is why it is done in a throwaway directory.
# opencode sets up its directories before it looks at its arguments: measured
# in an empty home, `opencode --version` on 1.18.30 creates opencode/ under
# all four XDG directories and under $TMPDIR, and 2.0.20 does the same and
# also writes a log file. doctor is a report — it must not be the thing that
# first creates ~/.local/share/opencode on a machine where opencode was
# installed and never run, and tests/test-doctor.sh's canary fails if any
# doctor run writes into a home it was only supposed to read. So the five are
# pointed at one temp directory for this one command, and it is removed.
# If the temp directory cannot be made, the version is left unread rather
# than asked for in the user's real directories.
#
# BOUNDED, because `roost wiring apply` runs this while a roost server is
# starting (bin/roost's ensure_session), and before the bound a `--version`
# that never returned was a roost that never started (found in review of
# #153). Measured in a fresh directory, three runs each: 0.29–0.52 s on
# 1.18.30 and 0.30–1.10 s on 2.0.20, the slow one being the first. Five
# seconds is several times the worst of those; it is not a number opencode
# promises.
#
# macOS ships no timeout(1), so the probe runs in the background beside a
# watchdog — the shape scripts/lib/roost-record.sh uses, for the reason it
# gives: SIGTERM first, because a process that can answer a signal should exit
# its own way, and SIGKILL a second later, because one that cannot is the case
# the bound exists for. Worst case is therefore six seconds, not five.
#
# The answer goes to a FILE in the throwaway directory, not down the pipe of
# the caller's `$(...)`. A killed probe can leave a child holding the pipe's
# write end, and the command substitution would then wait for it — the caller
# hangs after the watchdog has done its job. The watchdog's own output goes to
# /dev/null for the same reason. The whole body is a subshell with stderr
# closed off, so the "Terminated" line bash prints when it reaps a killed job
# never reaches a user who only asked for a doctor report.
#
# A probe that was killed leaves no first line to read, so it reads as "no
# version" — the same answer as an opencode that printed nothing. What each
# caller does with that is its own decision, and the two decide differently on
# purpose: see roost_opencode_takes_config_dir.
roost_opencode_version() {
  command -v opencode >/dev/null 2>&1 || return 0
  (
    d="$(mktemp -d 2>/dev/null)" && [ -n "$d" ] || exit 0
    XDG_CONFIG_HOME="$d" XDG_DATA_HOME="$d" XDG_CACHE_HOME="$d" XDG_STATE_HOME="$d" TMPDIR="$d" \
      opencode --version </dev/null >"$d/.roost-version" 2>/dev/null &
    probe=$!
    { sleep 5; kill "$probe"; sleep 1; kill -9 "$probe"; } </dev/null >/dev/null 2>&1 &
    dog=$!
    wait "$probe"
    kill "$dog"
    sed -n '1s/^[^0-9]*\([0-9][0-9.]*\).*/\1/p' "$d/.roost-version"
    rm -rf "$d"
  ) 2>/dev/null
  return 0
}

# roost_opencode_v2 [VERSION] -> 0 when that version (default: the one on PATH)
# is 2.x or later, 1 otherwise.
#
# "Otherwise" includes no opencode at all and a version that cannot be read.
# For `roost doctor` both take the 1.x checks on purpose: it is what doctor did
# before it asked, an opencode too old or too odd to print a version is far
# more likely to be 1.x, and the worst a wrong guess does there is print the
# wrong advice.
#
# What 2.x does with OPENCODE_CONFIG_DIR, measured on 2.0.20 against 1.18.30
# with the same files — a user config naming a non-default model, and the
# variable naming a directory that holds only an empty plugin/ folder:
#
#                                   plain          with OPENCODE_CONFIG_DIR
#   2.0.20  debug paths config      ~/.config/..   the named directory
#   2.0.20  model a turn used       the user's     the built-in default
#   1.18.30 model a turn used       the user's     the user's
#
# So on 2.x the variable does not ADD roost's folder, it REPLACES the user's:
# their model, providers, agents, commands, MCP servers and permission rules
# stop being read. The 1.x row is the control — same variable, and the user's
# model survives.
roost_opencode_v2() {
  local v="${1-}"
  [ "$#" -gt 0 ] || v="$(roost_opencode_version)"
  case "${v%%.*}" in
    ''|0|1) return 1 ;;
    *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# roost_opencode_takes_config_dir -> 0 when it is safe for `roost wiring` to
# set OPENCODE_CONFIG_DIR for the opencode on PATH, 1 when it is not.
#
# Safe means one of two things, and nothing else:
#
#   - there is no opencode on PATH. Nothing can be harmed, and an opencode 1.x
#     installed later then badges in new panes without a restart, as it always
#     has. (An opencode 2 installed later is the gap docs/known-gaps.md
#     records.)
#   - there is one, it answered, and it said 1.x.
#
# An opencode that is THERE but whose version could not be read — it printed
# nothing, or it was killed at the bound above — is NOT safe, and this is the
# one place the two callers part. doctor guesses 1.x, because a wrong guess
# costs a wrong line of advice. Wiring may not guess: set for a 2.x it failed
# to recognise, the variable silently drops the user's whole configuration,
# permission rules included, which is the bug this file exists to end (#154).
# Left unset for a 1.x it failed to recognise, the cost is a pane that does not
# badge until `roost install` is run, and doctor already prints that command.
# One of those can be seen and fixed by the user in a minute; the other cannot
# be seen at all. So the unknown goes the visible way.
#
# This matters more for having a bound: before it, "could not read the
# version" needed an opencode that printed nothing. With it, a 2.x that is
# merely slow on a loaded machine lands here too.
roost_opencode_takes_config_dir() {
  command -v opencode >/dev/null 2>&1 || return 0
  local v
  v="$(roost_opencode_version)"
  [ -n "$v" ] || return 1
  roost_opencode_v2 "$v" && return 1
  return 0
}
