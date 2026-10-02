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
# or nothing. Never fails.
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
roost_opencode_version() {
  command -v opencode >/dev/null 2>&1 || return 0
  local d v
  d="$(mktemp -d 2>/dev/null)" && [ -n "$d" ] || return 0
  v="$(XDG_CONFIG_HOME="$d" XDG_DATA_HOME="$d" XDG_CACHE_HOME="$d" XDG_STATE_HOME="$d" TMPDIR="$d" \
    opencode --version </dev/null 2>/dev/null | sed -n '1s/^[^0-9]*\([0-9][0-9.]*\).*/\1/p')"
  rm -rf "$d"
  printf '%s' "$v"
}

# roost_opencode_v2 [VERSION] -> 0 when that version (default: the one on PATH)
# is 2.x or later, 1 otherwise.
#
# "Otherwise" includes no opencode at all and a version that cannot be read.
# Both take the 1.x path on purpose: it is what roost did before it asked, an
# opencode too old or too odd to print a version is far more likely to be 1.x,
# and a machine with no opencode has nothing to protect.
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
