# roost-ancestry.sh — is a process inside a pane's process tree? (#105)
#
# Sourced by scripts/roost-agent-state (the report filter, step 4 of
# docs/airig/specs/2026-09-29-turn-over-design.md) and by bin/roost (`state
# --json` says what the filter decided). Defines one function and one constant
# and runs nothing at source time. It runs no tmux: the caller hands it the
# pane's #{pane_pid}, read in a tmux call it was making anyway, so a caller
# that needs the answer for many panes -- #78, finding a pane by ancestry --
# pays one listing, not one round trip per pane.
#
# --- the question, and why it is asked -----------------------------------------
#
# Any local process that carries a pane's $TMUX_PANE can stamp that pane's
# badge: the sink finds the pane from the environment and nothing else. A GUI
# app launched from the pane that detached itself, a shell that copied the
# variable, a daemon: each badges a pane it does not live in. The design's
# answer (§4) is one principle -- a pane answers only for its own process tree
# -- and this is its one test: walk P's parents with `ps -o ppid=` until the
# pane's process turns up, or the walk runs out.
#
# What it does NOT fix, so nobody reuses it for that (§4.2, the #105
# correction): a nested agent (#77) -- a `codex exec` or `claude -p` the pane's
# own agent started -- is a descendant, so it passes. And silence (#102) has no
# sender to test.
#
# --- the three answers ----------------------------------------------------------
#
#   in       P is the pane's process, or the walk met it            (return 0)
#   out      the walk RAN and reached pid 1 without meeting it,
#            and the pane's process is visible from here          (return 1)
#   unknown  the walk could not reach a verdict                    (return 2)
#
# "unknown" is narrow on purpose, and that is the human's Q4 limit (§8, §9.2):
# it means only that the walk could not run -- `ps` failed or printed nothing
# usable, the pane's process is not visible from here (a container's pid
# namespace: #64 §3.4), a pid was not a number, or the walk was longer than
# ROOST_ANCESTRY_MAX. A walk that ends at pid 1 is a VERDICT, never an
# "unknown": otherwise every detached process -- `setsid`, `nohup … &` whose
# parent exited -- would get in as unverified, and that is exactly the
# process the filter exists for.
#
# The visibility test runs only on the way to "out", after the walk has
# already reached pid 1, so an accepted report never pays for it. In a
# container the walk ends at the container's own pid 1 and the host's pane
# pid is not visible, so the answer is "unknown": accepted and marked, which
# protects nothing there (§9.2) but is visible. A container pid that happens
# to EQUAL the host's pane pid would read as "in" or "out"; not measured, and
# in docs/known-gaps.md.
#
# --- cost -------------------------------------------------------------------------
#
# One `ps` per level above P (2.4 ms a level on the design's machine, M9),
# none at all when P is the pane's process. The sink passes its own $PPID, so
# `roost state` typed at the pane's prompt -- whose parent IS the pane's shell
# -- costs nothing, and a Claude hook (hook -> claude -> pane, M8) costs one.
# `ps -A` once (26 ms there) would be the better trade only past about ten
# levels; no harness measured comes near that.
#
# A process that exits mid-walk makes its `ps` fail, so the walk says
# "unknown": the report is accepted and marked. That costs protection only in
# a race the reporter would have to lose on purpose, and it can never refuse a
# report from inside the pane.
#
# --- the suite's switch -----------------------------------------------------------
#
# ROOST_TEST_SKIP_ANCESTRY=1 makes every answer "unknown". tests/lib.sh exports
# it, because nearly every test file in the suite reports from the test's own
# shell with TMUX_PANE set by hand -- outside the pane, which is precisely what
# the filter refuses. It is never set anywhere else. It is not a quiet
# bypass: "unknown" is accepted AND marked `verified: false`, in `status
# --json`, in `state --json` and by `roost doctor`, the same as a container's,
# so a process that inherited it is visible, never trusted. The tests of the
# filter itself (tests/test-report-filter.sh) unset it.

# How many parents the walk will read before it gives up as "unknown". A
# harness's hook is two to four levels below the pane (M8, #64 §3.1); a deep
# PATH wrapper chain adds a few. 32 is far past any of them and still bounds a
# walk that `ps` somehow sends round in a loop.
ROOST_ANCESTRY_MAX=32

# roost_pid_in_pane PID PANE_PID -> ROOST_ANCESTRY (in | out | unknown), and
# returns 0, 1 or 2 to match. PID is where the walk starts: the reporter
# itself, or -- what the sink passes -- its parent.
#
# Strings are compared, never numbers, for the answer: ps prints no leading
# zero, and a value that is not all digits stops the walk before any test.
# The letters are spelled out for bash 3.2, which matches a range by the
# locale's collation.
roost_pid_in_pane() {
  local p="$1" pane="$2" n=0 up
  ROOST_ANCESTRY=unknown
  [ "${ROOST_TEST_SKIP_ANCESTRY:-}" != 1 ] || return 2
  # A pane process of 0 or 1 is not a pane: a tmux that printed nothing
  # usable (3.8 prints #{pane_pid} EMPTY once the pane's process has gone,
  # #165) must never make "reached pid 1" read as "met the pane".
  case "$pane" in ''|0|1|*[!0123456789]*) return 2 ;; esac
  case "$p" in ''|*[!0123456789]*) return 2 ;; esac
  while [ "$n" -lt "$ROOST_ANCESTRY_MAX" ]; do
    if [ "$p" = "$pane" ]; then
      ROOST_ANCESTRY=in
      return 0
    fi
    [ "$p" -gt 1 ] || break
    up="$(ps -o ppid= -p "$p" 2>/dev/null)" || return 2
    up="${up//[[:space:]]/}"
    case "$up" in ''|*[!0123456789]*) return 2 ;; esac
    p="$up"
    n=$((n + 1))
  done
  [ "$n" -lt "$ROOST_ANCESTRY_MAX" ] || return 2
  # Reached pid 1 (or 0, launchd's parent on macOS) without the pane. A
  # verdict only if the pane's process is there to be met: see above.
  up="$(ps -o pid= -p "$pane" 2>/dev/null)" || return 2
  up="${up//[[:space:]]/}"
  [ "$up" = "$pane" ] || return 2
  ROOST_ANCESTRY=out
  return 1
}
