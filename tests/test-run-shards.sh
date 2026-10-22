#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

# SHARD=k/n splits tests/run.sh across CI jobs (#169). What has to hold is
# the ASSIGNMENT, not the numbers in the weight table: every file lands in
# exactly one shard, the order is stable and matches the full run, the
# heaviest files spread out instead of stacking, a shard with nothing in it
# is a clean empty run, and a bad spec runs nothing at all. The weights
# themselves are a budget that will drift (see the table's comment); pinning
# them here would turn every re-measurement into a test edit.

# --- the assignment, against the real tests/ directory -----------------------
# `--list` prints what a shard would run and runs nothing, so this part is
# cheap enough to check several shard counts, and it sees the same glob the
# real run sees — a new test file is covered the moment it exists.
# This file asks run.sh what an UNSET SHARD lists, and runs a fixture copy of
# it with no SHARD at all, so one inherited from the shell would fail both.
# run.sh unsets it before it starts a file; this covers a direct run.
unset SHARD
all="$(cd "$HERE/tests" && ls test-*.sh)"
all_n="$(printf '%s\n' "$all" | wc -l | tr -d ' ')"

for n in 1 2 4 7; do
  union=""
  k=1
  while [ "$k" -le "$n" ]; do
    part="$(SHARD="$k/$n" bash "$HERE/tests/run.sh" --list)"
    # Each shard lists its files in the glob's order, so its output reads as
    # a slice of the full run rather than a reshuffle of it.
    printf '%s\n' "$part" | LC_ALL=C sort -c 2>/dev/null
    assert_true $? "shard $k/$n lists its files in run order"
    union="$union$part
"
    k=$((k + 1))
  done
  # Same count and same sorted content as the directory: no file missing, no
  # file twice. Both halves are needed — a file dropped and another doubled
  # would keep the count and change the content.
  union_sorted="$(printf '%s' "$union" | sed '/^$/d' | LC_ALL=C sort)"
  assert_eq "$(printf '%s\n' "$union_sorted" | wc -l | tr -d ' ')" "$all_n" \
    "$n shards together hold exactly $all_n files, each once"
  assert_eq "$union_sorted" "$(printf '%s\n' "$all" | LC_ALL=C sort)" \
    "$n shards together are exactly the files of tests/"
done

# With no SHARD, --list is the whole directory in the order the run uses: the
# same loop with k/n unset, so an unset SHARD is "all of it", not "shard 1".
assert_eq "$(bash "$HERE/tests/run.sh" --list)" "$all" \
  "with SHARD unset, --list is every file in run order"

# Stable: the assignment is a pure function of the file list and the weight
# table, so two calls agree — nothing is kept between jobs, and the four CI
# jobs each recompute it and get disjoint sets.
assert_eq "$(SHARD=3/4 bash "$HERE/tests/run.sh" --list)" \
          "$(SHARD=3/4 bash "$HERE/tests/run.sh" --list)" \
  "the same shard spec lists the same files on two runs"

# Spread: the greedy longest-first rule puts the n heaviest files into n
# different shards, so the 102 s file never shares a job with the 65 s one.
# These four are the top of the weight table; if the table is re-measured and
# the top four change, update them here — the property is what is pinned.
shard_of() { # shard_of FILE N -> which shard of N lists FILE
  local f=$1 n=$2 k=1
  while [ "$k" -le "$n" ]; do
    if SHARD="$k/$n" bash "$HERE/tests/run.sh" --list | grep -qx "$f"; then
      printf '%s' "$k"; return
    fi
    k=$((k + 1))
  done
  printf 'none'
}
spread="$(for f in test-send-turn.sh test-opencode2-plugin.sh test-send-paste.sh test-ext.sh; do
            shard_of "$f" 4; echo
          done | LC_ALL=C sort -u | wc -l | tr -d ' ')"
assert_eq "$spread" "4" "the four slowest files land in four different shards of 4"

# --- running a shard, against an isolated copy with fixture files ----------
# The same fixture shape as tests/test-runner.sh: a copy of run.sh in its own
# directory with files made for the purpose, so nothing here is picked up by a
# normal `bash tests/run.sh`, and so the suite does not have to run a real
# shard of itself (minutes) to prove a shard runs.
fixdir="$(mktemp -d /tmp/amx.XXXX)"
trap 'rm -rf "$fixdir"' EXIT
cp "$HERE/tests/run.sh" "$fixdir/run.sh"
cp "$HERE/tests/lib.sh" "$fixdir/lib.sh"
cat > "$fixdir/test-a.sh" <<'EOT'
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
assert_eq 1 1 "fixture a passes"
assert_eq 1 1 "fixture a passes again"
printf 'SHARD-IN-FILE=%s\n' "${SHARD:-unset}"
EOT
cat > "$fixdir/test-b.sh" <<'EOT'
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
assert_eq 1 2 "fixture b fails"
EOT
chmod +x "$fixdir"/test-*.sh

# Two files of equal (default) weight across three shards: a goes to 1, b to
# 2, and 3 is EMPTY. The empty shard is the case a workflow hits when a matrix
# names more shards than a small fixture directory has files, and it must be
# a clean nothing: the summary line in its usual shape and exit 0, because
# nothing failed and nothing died. A shard that printed no summary, or exited
# non-zero on an empty list, would turn a quiet job red or hide a red one.
out="$(cd "$fixdir" && SHARD=1/3 bash run.sh 2>&1)"; rc=$?
assert_eq "$rc" "0" "shard 1/3 (the passing file alone) exits 0"
assert_contains "$out" "== test-a.sh ==" "shard 1/3 runs test-a.sh"
printf '%s' "$out" | grep -q '== test-b.sh =='; [ $? -ne 0 ]
assert_true $? "shard 1/3 does not run test-b.sh"
assert_contains "$out" "2 passed, 0 failed" "shard 1/3 sums only its own file"
# The spec must stop at run.sh. A test file that saw SHARD=1/3 and ran a
# copy of run.sh (this file does, and so does tests/test-runner.sh) would
# shard its fixtures too — the first real shard run of the suite turned both
# red exactly that way.
assert_contains "$out" "SHARD-IN-FILE=unset" "the test file itself does not see SHARD"

out="$(cd "$fixdir" && SHARD=2/3 bash run.sh 2>&1)"; rc=$?
assert_eq "$rc" "1" "shard 2/3 (the failing file alone) exits 1"
assert_contains "$out" "0 passed, 1 failed" "shard 2/3 reports its own failure"

out="$(cd "$fixdir" && SHARD=3/3 bash run.sh 2>&1)"; rc=$?
assert_eq "$rc" "0" "an empty shard exits 0"
assert_contains "$out" "0 passed, 0 failed" "an empty shard still prints the summary line"

# Control: the unsharded run over the same fixtures is the sum of the shards
# (2 passed, 1 failed, exit 1), which is what makes the per-shard totals in a
# CI matrix add up to the number a local full run prints.
out="$(cd "$fixdir" && bash run.sh 2>&1)"; rc=$?
assert_eq "$rc" "1" "the full fixture run exits 1 (one file fails)"
assert_contains "$out" "2 passed, 1 failed" "the full fixture run is the sum of the three shards"

# A file that dies mid-run still fails its shard and no other: the death check
# in run.sh is per file, and a shard holding only healthy files has no reason
# to know about it.
cat > "$fixdir/test-c.sh" <<'EOT'
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
assert_eq 1 1 "fixture c runs one assertion before dying"
exit 7
EOT
chmod +x "$fixdir/test-c.sh"
crashed_in=""; clean=0
k=1
while [ "$k" -le 3 ]; do
  out="$(cd "$fixdir" && SHARD="$k/3" bash run.sh 2>&1)"; rc=$?
  case "$out" in
    *"== test-c.sh =="*) crashed_in="$k:$rc" ;;
    *"== test-a.sh =="*) [ "$rc" -eq 0 ] && clean=$((clean + 1)) ;;
  esac
  k=$((k + 1))
done
assert_eq "${crashed_in#*:}" "1" "the shard holding the dying file exits non-zero"
assert_eq "$clean" "1" "the shard holding only the healthy file still exits 0"

# A bad spec is refused before anything runs, with exit 2 — distinct from the
# 1 of a failing suite — because a typo that quietly ran everything, or
# nothing, would look like a green job.
# `1/2/3` and `1/4/4` are the two that once got through: a combined pattern
# took "2/3" for n, the `-gt` errored instead of refusing, and the run was a
# green nothing. Each half is checked on its own now.
for bad in 4 0/4 5/4 a/b 1/ /4 1//4 1/2/3 1/4/4 2/2/3; do
  out="$(cd "$fixdir" && SHARD="$bad" bash run.sh 2>&1)"; rc=$?
  assert_eq "$rc" "2" "SHARD=$bad is refused with exit 2"
  printf '%s' "$out" | grep -q '== test-'; [ $? -ne 0 ]
  assert_true $? "SHARD=$bad runs no file"
done

# The second line of defence: an assignment that breaks underneath a valid
# spec. `sort` is what shard_files leans on, so a `sort` that prints nothing
# (here: shadowed on PATH by a script that exits silently) empties every
# shard. With three fixture files and three shards no shard may be empty, so
# run.sh must refuse with exit 2 and run nothing — not print "0 passed,
# 0 failed" and exit 0. The control is the SHARD=1/3 run above, same files,
# real sort, exit 0.
shim="$(mktemp -d /tmp/amx.XXXX)"
printf '#!/bin/sh\nexit 0\n' > "$shim/sort"
chmod +x "$shim/sort"
out="$(cd "$fixdir" && PATH="$shim:$PATH" SHARD=1/3 bash run.sh 2>&1)"; rc=$?
rm -rf "$shim"
assert_eq "$rc" "2" "a shard emptied by a broken assignment is refused with exit 2"
assert_contains "$out" "holds no file" "the refusal says the shard holds no file"
printf '%s' "$out" | grep -q '== test-'; [ $? -ne 0 ]
assert_true $? "a shard emptied by a broken assignment runs no file"
