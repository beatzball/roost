#!/usr/bin/env bash
# Run every tests/test-*.sh and sum results.
#
#   bash tests/run.sh                 the whole suite, as always
#   SHARD=2/4 bash tests/run.sh       only the files assigned to shard 2 of 4
#   SHARD=2/4 bash tests/run.sh --list   print those files and run nothing
#
# Shards exist for CI (#169): the macOS job ran the 58 files one after another
# in 733 s, and a pull request waited 12 minutes for it. Every file drives its
# own tmux server on its own socket and waits on its own timeouts, so the
# files are independent and a job can run any subset. With SHARD unset nothing
# below changes: the same files, the same order, the same lines, the same
# "N passed, M failed" summary. With SHARD set the per-file lines and the
# summary keep their shape and cover that shard's files only, so the four
# shard totals add up to the full run's.
set -u
cd "$(dirname "$0")"

# Seconds each file took on the macOS job of pull request #168's run
# (2026-10-22, 733 s over 58 files, read off the job log's line timestamps:
# one header to the next). Only the twelve slowest are listed; every other
# file gets 5, the average of the remaining 46 (213 s between them, none over
# 12 s). Balancing by COUNT instead (every fourth file) gives shards of 61,
# 206, 226 and 240 s, the slowest of them 3.9 times the lightest; by these
# numbers the four come out at 169 to 194 s, within 25 s of each other.
#
# This is a budget, not a measurement to quote back (AGENTS.md §9). A file
# that gets slower moves one shard's finish time and breaks nothing, and a
# new file lands at 5 until someone measures it. Re-measure when one shard
# runs noticeably longer than the others: the per-file seconds fall out of
# the job log the same way, and tests/test-run-shards.sh pins the shape of
# the assignment, not these values.
shard_weight() {
  case "$1" in
    test-send-turn.sh) echo 102 ;;
    test-opencode2-plugin.sh) echo 65 ;;
    test-send-paste.sh) echo 58 ;;
    test-ext.sh) echo 56 ;;
    test-send-lock.sh) echo 85 ;;
    test-wait-done-shell.sh) echo 40 ;;
    test-coordination.sh) echo 39 ;;
    test-events.sh) echo 35 ;;
    test-wait-done-died.sh) echo 26 ;;
    test-send-readiness.sh) echo 25 ;;
    test-claude-permission-request.sh) echo 25 ;;
    test-adapter-install.sh) echo 25 ;;
    test-reply-record.sh) echo 24 ;;
    # One local macOS run (2026-10-24, 28 s), not a CI log: re-measure with the rest.
    test-send-when-idle.sh) echo 28 ;;
    # Added 2026-10-24 for the turn-over steps 1 to 3 (#95, #97), each timed
    # once on the dev Mac, not off a CI log: 20.3 s, 12.5 s and (fix loop 1)
    # 28.6 s (after the rebase added the send checks).
    test-turn-over-interrupt.sh) echo 20 ;;
    test-turn-over-hold.sh) echo 13 ;;
    test-turn-over-edges.sh) echo 29 ;;
    # Added for persistent sessions Part 1 (#191), timed once on the dev Mac
    # at Task 1.13 (34 s), not off a CI log; Task 1.14 adds cases to it.
    test-shape-place.sh) echo 40 ;;
    *) echo 5 ;;
  esac
}

# shard_files K N — print the files of shard K of N, one per line, in the
# order the main loop below would run them (the glob's order, so a shard's
# output reads like a slice of the full run, not a reshuffle of it).
#
# Greedy, longest first onto the lightest shard: sort the files by weight,
# heaviest first, and hand each to whichever shard has the least so far. With
# N shards the N heaviest files are guaranteed to land in N different shards,
# which is the one property that matters here — the 102 s file never shares a
# job with the 65 s one. Ties go to the lowest-numbered shard, and files of
# equal weight are ordered by name, so the assignment is a pure function of
# the file list and the weights: the same every run, on every machine, with
# no state to keep between jobs. That is also why it is recomputed from the
# glob in each job rather than read from a list: a new test file is in
# exactly one shard the moment it exists, with nothing to register.
#
# `LC_ALL=C` because the name tiebreak must sort the same way on every
# runner, and a locale-aware sort does not promise that. bash 3.2 has
# indexed arrays and no `declare -A`, hence the loads in `load[i]`.
shard_files() {
  local k=$1 n=$2 i f w best picked=""
  local load
  load=()
  i=0; while [ "$i" -lt "$n" ]; do load[$i]=0; i=$((i+1)); done
  while read -r w f; do
    best=0; i=1
    while [ "$i" -lt "$n" ]; do
      [ "${load[$i]}" -lt "${load[$best]}" ] && best=$i
      i=$((i+1))
    done
    load[$best]=$(( ${load[$best]} + w ))
    [ "$((best + 1))" -eq "$k" ] && picked="$picked $f"
  done < <(for f in test-*.sh; do
             [ -e "$f" ] || continue
             printf '%s %s\n' "$(shard_weight "$f")" "$f"
           done | LC_ALL=C sort -k1,1nr -k2,2)
  for f in test-*.sh; do
    [ -e "$f" ] || continue
    case " $picked " in *" $f "*) printf '%s\n' "$f" ;; esac
  done
}

# SHARD is k/n with 1 <= k <= n, both plain positive integers. Anything else
# is refused with exit 2 BEFORE a single file runs: a typo like SHARD=4 or
# SHARD=0/4 that silently ran the whole suite (or nothing) would look like a
# green job, and a shard that ran nothing is exactly the failure mode the
# "died mid-run" check below exists to catch for one file. Exit 2 is distinct
# from the 1 a failing suite returns, so a workflow can tell the two apart.
#
# Each half is checked ON ITS OWN, all digits and non-empty, before any
# arithmetic touches it. The first version matched the whole spec against one
# pattern, and `SHARD=1/2/3` slipped through: k was 1, n was "2/3", the `-gt`
# comparison errored — which is false, not a refusal — and the greedy loop ran
# over garbage and handed back an empty set, so the run printed "0 passed,
# 0 failed" and exited 0 with a failing file in the directory. Two reviewers
# found it; tests/test-run-shards.sh now pins that spec and `1/4/4`.
shard_k=1 shard_n=1 shard_set=""
if [ -n "${SHARD:-}" ]; then
  shard_k="${SHARD%%/*}" shard_n="${SHARD#*/}"
  case "$SHARD" in */*) ;; *) shard_k="" ;; esac
  case "$shard_k" in ""|*[!0-9]*) shard_k="" ;; esac
  case "$shard_n" in ""|*[!0-9]*) shard_k="" ;; esac
  # Width too, not just digits: a value wider than the integer `[` can read
  # (SHARD=1/9223372036854775808) passes the all-digits check and then makes
  # every -lt/-gt/-ge below error out — false, not a refusal — the empty-shard
  # guard included, so zero files ran and the exit was 0. Seven or more
  # digits is refused; nobody has a million shards.
  case "$shard_k" in ???????*) shard_k="" ;; esac
  case "$shard_n" in ???????*) shard_k="" ;; esac
  if [ -z "$shard_k" ] || [ "$shard_k" -lt 1 ] || [ "$shard_k" -gt "$shard_n" ]; then
    printf 'RUNNER: SHARD must be k/n with 1 <= k <= n, got [%s]\n' "$SHARD" >&2
    exit 2
  fi
  shard_set=" $(shard_files "$shard_k" "$shard_n" | tr '\n' ' ') "
  # Second line of defence, for a failure the spec check cannot see: a shard
  # that holds NO file while there are at least n files. Longest-first greedy
  # gives each of the n shards one of the first n files, so with n or more
  # files every shard is non-empty by construction, and an empty one means
  # the assignment itself broke — a `sort` that printed nothing, a glob that
  # found nothing from a wrong directory. Without this, that is eight green
  # jobs that ran nothing. Fewer files than shards is the one honest empty
  # shard (the fixture test's 3 shards over 2 files) and still exits 0.
  shard_total=0
  for t in test-*.sh; do [ -e "$t" ] && shard_total=$((shard_total + 1)); done
  case "$shard_set" in
    *[!\ ]*) ;;
    *) if [ "$shard_total" -ge "$shard_n" ]; then
         printf 'RUNNER: shard %s of %s holds no file although there are %d test files — the assignment failed, refusing to report a green run of nothing\n' \
           "$shard_k" "$shard_n" "$shard_total" >&2
         exit 2
       fi ;;
  esac
  # SHARD has done its job; it must not reach the test files. They run with
  # the environment a developer's `bash tests/test-x.sh` gives them, and two
  # of them (tests/test-runner.sh, tests/test-run-shards.sh) run a COPY of
  # this script over fixture files: with SHARD still exported, that copy
  # sharded the fixtures as well, skipped the one that was meant to die, and
  # the first real shard run reported both files red. Found by running it,
  # not by reading it.
  unset SHARD
fi
if [ "${1:-}" = "--list" ]; then
  shard_files "$shard_k" "$shard_n"
  exit 0
fi

pass=0 fail=0
crashed=""
# Pane records (#42): nothing in the suite may land in the developer's real
# record directory. tests/lib.sh switches records off for every file, and this
# checks that it held. A record made during the run whose socket no longer
# exists came from a test server — the suite tears every server down — while a
# live agent's record, made by the developer's own roost during a long run,
# names a socket that is still there, and is not a failure. The marker is
# created before the first file runs, so only records made during the run count.
case "${XDG_STATE_HOME:-}" in /*) rec_real="$XDG_STATE_HOME/roost/panes" ;; *) rec_real="${HOME:-/nonexistent}/.local/state/roost/panes" ;; esac
rec_marker="$(mktemp /tmp/amx.XXXX)"
for t in test-*.sh; do
  [ -e "$t" ] || continue
  # A file outside this shard is skipped silently rather than printed as
  # skipped: the shard's output is meant to read as a slice of the full run,
  # and 40-odd "skipped" headers per job would bury the lines that matter.
  # `--list` is how to see what a shard holds. An EMPTY shard (more shards
  # than files, which the fixture test exercises) runs nothing, prints
  # "0 passed, 0 failed" and exits 0 — nothing failed and nothing died.
  if [ -n "$shard_set" ]; then
    case "$shard_set" in *" $t "*) ;; *) continue ;; esac
  fi
  printf '\n== %s ==\n' "$t"
  # each test file sources lib.sh and prints PASS/FAIL lines; capture counts via env
  out="$(ROOST_TESTS_PASS=0 ROOST_TESTS_FAIL=0 bash "$t" 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  pass=$((pass + $(printf '%s' "$out" | grep -c '^  PASS')))
  fail=$((fail + $(printf '%s' "$out" | grep -c '^  FAIL')))
  # A file's PASS/FAIL lines are silent about a hard death mid-run (syntax
  # error, an unexpected `set -e` abort, a killed server): it just
  # contributes fewer PASS lines and NO FAIL lines, so the counts above
  # would silently under-report and this script could still exit 0. Test
  # files are expected to exit 0 on success, so a non-zero exit here means
  # something died that no PASS/FAIL line accounts for — name it and fail
  # the suite even if every line it did print was a PASS.
  if [ "$rc" -ne 0 ]; then
    printf 'RUNNER: %s exited %d before finishing — treating the run as failed\n' "$t" "$rc"
    crashed="$crashed $t"
  fi
done
rec_leaked=""
if [ -d "$rec_real" ]; then
  while IFS= read -r d; do
    sock=""
    [ -f "$d/socket" ] && IFS= read -r sock < "$d/socket"
    [ -S "$sock" ] || rec_leaked="$rec_leaked $d"
  done < <(find "$rec_real" -mindepth 2 -maxdepth 2 -type d -newer "$rec_marker" 2>/dev/null)
fi
rm -f "$rec_marker"
if [ -n "$rec_leaked" ]; then
  printf 'RUNNER: the suite wrote pane records into the real %s:%s\n' "$rec_real" "$rec_leaked"
  crashed="$crashed (real-record-dir)"
fi
printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ -n "$crashed" ]; then
  printf 'RUNNER: these test files died mid-run (non-zero exit):%s\n' "$crashed"
fi
[ "$fail" -eq 0 ] && [ -z "$crashed" ]
