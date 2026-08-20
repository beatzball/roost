# test-switcher Flake Fix Implementation Plan

> **For agentic workers:** implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `tests/test-switcher.sh`'s last assertion — *an unnamed pane's
switcher row falls back to the command* — from failing intermittently, and land
a forced trigger that makes the fix provable instead of merely unobserved.

**Architecture:** The flake is entirely in the test. `scripts/amux-switch` is
correct and is not modified by this plan. The test compares two independent
reads of `#{pane_current_command}`, taken tens of milliseconds apart, as if they
were one snapshot. The fix removes the second read by pinning the pane under
test to a command whose reported name is a known constant, so the expected value
is a literal in the test file and no live read is compared against another.

**Tech Stack:** bash 3.2+, tmux 3.4+ floor, isolated `-S <path>` tmux servers.

---

## Investigation record

### The bug is real and the hypothesis in the brief is correct

Measured on this machine at `7bd1ed4`, unmodified `tests/test-switcher.sh`:

| Batch | Runs | Failures |
|---|---|---|
| 4 parallel streams × 40 | 160 | 3 |
| 8 parallel streams × 30 | 240 | 0 |
| **Total** | **400** | **3 (0.75%, ~1 in 133)** |

The two batches ran the same code minutes apart. That spread — 1-in-53 then
0-in-240 — is the same instability already reported across worktrees, and it is
the reason the natural loop cannot prove a fix. A forced trigger is required.

Captured failure text (from `assert_contains`, which prints both sides):

```
FAIL: an unnamed pane's switcher row falls back to the command
     [$0 @0 %0   B blocked    --  %0     apiwin·awk] does not contain [zsh]
FAIL: an unnamed pane's switcher row falls back to the command
     [$0 @0 %0   B blocked    --  %0     apiwin·zsh] does not contain [awk]
FAIL: an unnamed pane's switcher row falls back to the command
     [$0 @0 %0   B blocked    --  %0     apiwin·printf] does not contain [zsh]
```

The mismatch goes in **both directions**: sometimes the switcher's read is the
odd one out, sometimes the test's read is. Both reads are equally untrustworthy.

### The confirmed mechanism

`tests/lib.sh:13` starts the session with no command:

```sh
tmux -S "$AMUX_TEST_SOCK" -f /dev/null new-session -d -x 200 -y 50
```

so pane `%0` runs the **developer's interactive login shell**, and that shell
sources its startup files inside the pane. Each external helper those files run
becomes the pane's foreground process for a few milliseconds, and
`#{pane_current_command}` reports it faithfully.

Tracing the value from server start (three consecutive fresh servers):

```
  0.020  zsh          0.024  zsh          0.019  zsh
  0.049  stty         0.086  grep         0.078  grep
  0.057  zsh          0.095  zsh          0.085  zsh
                      0.434  awk          0.117  ls
                      0.442  zsh          0.125  zsh
```

Names observed across all sampling: `stty`, `grep`, `awk`, `ls`, `mkdir`,
`diff`, `printf`. The churn tail reached **0.434 s** on an otherwise idle
machine. `tests/test-switcher.sh` completes in ~0.9 s, so its final assertion
lands just past the usual end of that tail — and under parallel load the tail
stretches past it. That is the whole 1-in-30.

Two supporting measurements:

- **Idle interactive shell pane:** 10 stray values in 12 000 reads (0.08 %). At
  the moment of a stray read the pane shell had **no live children** and no
  process of that name was alive — consistent with a helper that had already
  exited between the read and the follow-up check, i.e. the same startup churn,
  not a second mechanism.
- **Pinned pane** (`new-session -d 'exec sleep 600'`): **0 stray values in
  6 000 reads.** A pane whose command is long-lived does not churn.

So: it is not a transient child of the *switcher*, not an empty string, and not
a shell fork in the abstract. It is the developer's shell rc still running, and
the two reads sample it at different instants.

### The forced trigger

`repro-forced.sh` below runs the exact read-pair from
`tests/test-switcher.sh:115-117` against a pane whose `#{pane_current_command}`
alternates ~50/50 between `sleep` and `perl`. Nothing in `scripts/amux-switch`
and nothing in the assertion is changed — only how often the live value moves.

| Instrument | Reproduction rate |
|---|---|
| Unmodified test, natural | 3 / 400 runs (0.75 %) |
| Forced trigger, `N=10` | **19 / 20 runs (95 %)**; 34 mismatches per 200 read-pairs (17 %) |
| Forced trigger, `N=30` | ≥ 99 % per run (extrapolated from the 17 % per-pair rate) |

The recommended fix, prototyped against that same churn, produced **0 mismatches
in 200 read-pairs** across 5 independent servers.

---

## Global Constraints

- **bash 3.2 compatible.** macOS ships `/bin/bash` 3.2.
- **Never contact the live `-L amux` server.** Tests use isolated `-S <path>`
  sockets from `mktemp -d /tmp/amx.XXXX` only.
- **Public repo.** No usernames, real names, `/Users/...` paths, or email
  addresses in tracked files. Run `grep -rn "/Users/[a-z]"` over the diff before
  committing; it must return nothing.
- **Do not merge, push, force-push, or interact with GitHub PRs.** Commit
  locally only.
- **Every new assertion needs a negative control.** Task 1 exists so Task 2 has
  one: run the trigger against unfixed code and watch it fail first.
- **`scripts/amux-switch` is not modified by this plan.** Production behaviour is
  correct; the defect is in how the test observes it.

## Files

**Create:**
- `docs/airig/plans/2026-08-20-switcher-flake-fix.md` — this file.
- `tests/live/switcher-read-race.sh` — the forced trigger. Lives in
  `tests/live/` deliberately, outside `tests/run.sh`'s flat `test-*.sh` glob,
  because it is a diagnostic that takes seconds and needs `perl`.

**Modify:**
- `tests/test-switcher.sh:114-118` — the flaky assertion.
- `tests/lib.sh:8-16` — `amux_test_server` (Task 3, hardening).

---

### Task 1: Land the forced trigger

Without this, no fix can be proven — the natural failure rate is 0.75 % and
swings to 0 across batches. This task ships the instrument first, and confirms
it fails against today's unfixed test logic.

**Files:**
- Create: `tests/live/switcher-read-race.sh`

**Interfaces:**
- Consumes: `tests/lib.sh` (`amux_test_server`, `T`), `scripts/amux-switch`.
- Produces: an executable that exits **non-zero** when the two-read comparison
  disagrees, and prints each disagreement with both values.

**Deviation from this plan, made during execution:** as drafted below the
trigger replicated only the PRE-FIX comparison, so once Task 2 landed it would
have failed forever and proved nothing. The shipped
`tests/live/switcher-read-race.sh` runs **two arms** against the same churn
instead — `CONTROL` (the pre-fix two-read shape, expected to mismatch) and
`SHIPPED` (the pinned-pane shape, expected to be clean) — and its exit status
tracks `SHIPPED` only. That gives a before/after from a single run and keeps the
file useful as a standing regression guard. It also warns when `CONTROL` fails
to fire, since a blunt trigger is a silent loss of proof.

- [x] **Step 1: Write the trigger**

```bash
#!/usr/bin/env bash
# Forced trigger for the tests/test-switcher.sh read-pair race.
#
# Runs the EXACT comparison from tests/test-switcher.sh:115-117 against a pane
# whose #{pane_current_command} alternates ~50/50 between "sleep" and "perl".
# Nothing in scripts/amux-switch and nothing in the assertion is modified — only
# how often the live value that the two reads sample happens to change.
#
# Exits non-zero on any disagreement. Not part of tests/run.sh: it needs perl,
# takes seconds, and is a diagnostic rather than a behaviour test.
#
#   N=30 tests/live/switcher-read-race.sh
set -u
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
N="${N:-30}"
. "$HERE/tests/lib.sh"
amux_test_server; trap amux_test_teardown EXIT
T source-file "$HERE/tmux/amux.conf"
T set-option -g @amux-home "$HERE"

p0="$(T display -p '#{pane_id}')"
T split-window -d -t "$p0" 'sh -c "while :; do sleep 5; done"' >/dev/null
T set-option -p -t "$p0" @agent_state blocked
T rename-window apiwin

# Two externals of equal duration: each read of the pane is close to a coin flip.
T send-keys -t "$p0" \
  "while :; do /bin/sleep 0.03; /usr/bin/perl -e 'select(undef,undef,undef,0.03)'; done" Enter
sleep 0.5

bad=0
for i in $(seq 1 "$N"); do
  rows="$(AMUX_SWITCH_SOCK="$AMUX_TEST_SOCK" AMUX_SWITCH_DUMP=1 "$HERE/scripts/amux-switch")"
  cmd="$(T display-message -p -t "$p0" '#{pane_current_command}')"
  row="$(printf '%s\n' "$rows" | awk -F'\t' -v p="$p0" '$3==p')"
  case "$row" in
    *"$cmd"*) ;;
    *) bad=$((bad+1)); printf 'MISMATCH iter=%s switcher_saw=[%s] test_read=[%s]\n' "$i" "$row" "$cmd" ;;
  esac
done
printf 'RESULT: %s mismatches in %s read-pairs\n' "$bad" "$N"
[ "$bad" -eq 0 ]
```

- [x] **Step 2: Confirm it discriminates**

Run it five times. It must fail — that is the negative control for Task 2.

**Check:**
```sh
chmod +x tests/live/switcher-read-race.sh
fails=0; for i in 1 2 3 4 5; do N=30 tests/live/switcher-read-race.sh >/dev/null 2>&1 || fails=$((fails+1)); done
echo "trigger fired in $fails/5 runs"    # expect 5/5, must be >= 4/5
```

---

### Task 2: Remove the second live read from the assertion

The assertion's intent is *"when `@amux-name` is unset, the switcher row falls
back to the pane's command."* That intent needs a pane whose command is known,
not a pane whose command is read twice. Pin the pane to a long-lived command and
compare the row against a **literal** — one live read total, in the switcher,
where it belongs.

**Files:**
- Modify: `tests/test-switcher.sh:114-118`
- Test: `tests/test-switcher.sh` itself, plus `tests/live/switcher-read-race.sh`
  from Task 1 as the adversarial check.

**Interfaces:**
- Consumes: nothing new.
- Produces: the assertion no longer calls `T display-message -p
  '#{pane_current_command}'`. `grep -c pane_current_command
  tests/test-switcher.sh` returns `0`.

- [x] **Step 1: Replace the read-pair**

Today's block, at `tests/test-switcher.sh:114-118`:

```bash
T set-option -pu -t "$p0" @amux-name
rows="$(AMUX_SWITCH_SOCK="$AMUX_TEST_SOCK" AMUX_SWITCH_DUMP=1 "$HERE/scripts/amux-switch")"
cmd="$(T display-message -p -t "$p0" '#{pane_current_command}')"
assert_contains "$(printf '%s\n' "$rows" | awk -F'\t' -v p="$p0" '$3==p')" "$cmd" \
  "an unnamed pane's switcher row falls back to the command"
```

Replace it with:

```bash
T set-option -pu -t "$p0" @amux-name

# The fallback is asserted against a pane PINNED to a long-lived command, not
# against a second read of a live value. `tests/lib.sh` starts the session with
# no command, so %0 runs the developer's login shell, and that shell's startup
# files put short-lived helpers (observed: stty, grep, awk, ls, mkdir, diff,
# printf) in the foreground for up to ~0.4s. #{pane_current_command} reports
# each of them faithfully. Reading it here and comparing it to what the switcher
# read moments earlier compares two different instants: measured 3 failures in
# 400 runs, in BOTH directions. A pane running `exec sleep 600` reported "sleep"
# on 6000 consecutive reads, so "sleep" can be a literal in this file.
pf="$(T split-window -d -P -F '#{pane_id}' -t "$p0" 'exec sleep 600')"
# Bounded gate on the exec landing — deterministic, unlike racing it.
for _ in $(seq 1 50); do
  [ "$(T display-message -p -t "$pf" '#{pane_current_command}')" = sleep ] && break
  sleep 0.05
done
assert_eq "$(T display-message -p -t "$pf" '#{pane_current_command}')" "sleep" \
  "the pinned pane reports a stable command"
rows="$(AMUX_SWITCH_SOCK="$AMUX_TEST_SOCK" AMUX_SWITCH_DUMP=1 "$HERE/scripts/amux-switch")"
assert_contains "$(printf '%s\n' "$rows" | awk -F'\t' -v p="$pf" '$3==p')" "·sleep" \
  "an unnamed pane's switcher row falls back to the command"
```

Notes for the implementer:

- The new pane joins window `apiwin`, whose name is not `sleep`, so
  `amux-switch`'s suffix-suppression branch does not fire and the row carries
  `·sleep`. Asserting `·sleep` rather than bare `sleep` also keeps the assertion
  from passing on an unrelated substring.
- `@amux-name` and `@agent_state` are unset on `pf`, which is exactly the
  fallback case under test.
- `p0` keeps its `@amux-name` unset line because the preceding assertion
  ("a named pane's switcher row shows the name") sets it.

- [x] **Step 2: Confirm the assertion still discriminates**

An assertion that cannot fail is worse than a flaky one. Break the switcher on
purpose and watch it go red, then revert.

**Check:**
```sh
# 1. the test passes, repeatedly
for i in $(seq 1 30); do bash tests/test-switcher.sh; done | grep -c FAIL   # expect 0

# 2. it is not vacuous — force amux-switch to ignore the command and it must fail
sed -i.bak 's/label = (nm != "" ? nm : cmd)/label = (nm != "" ? nm : "XX")/' scripts/amux-switch
bash tests/test-switcher.sh | grep -c "FAIL: an unnamed pane's switcher row"   # expect 1
mv scripts/amux-switch.bak scripts/amux-switch

# 3. the whole suite is green
tests/run.sh
```

All three were run during the investigation against a prototype of this change:
30/30 clean, the broken-fallback control produced exactly 1 FAIL, and the suite
reported 349 passed, 0 failed.

---

### Task 3: Harden the harness against the whole class

Task 2 fixes one assertion. The enabling condition — every test pane runs the
developer's login shell and its rc files — is still there for every other test,
and it makes local timing differ from CI timing. Starting the session on a
neutral shell removes the churn at the source and makes `#{pane_current_command}`
the same value on every machine.

This is a larger blast radius than Tasks 1-2, so it lands separately and its
Check is the full suite.

**Files:**
- Modify: `tests/lib.sh:8-16` (`amux_test_server`)

**Interfaces:**
- Consumes: nothing.
- Produces: the initial pane of a test server runs `/bin/sh` with no rc files.
  `#{pane_current_command}` for that pane is `sh` on every machine.

- [x] **Step 1: Start the session on a neutral shell**

In `amux_test_server`, change:

```sh
tmux -S "$AMUX_TEST_SOCK" -f /dev/null new-session -d -x 200 -y 50
```

to:

```sh
# Start the initial pane on a bare /bin/sh, not the developer's login shell.
# A login shell sources rc files INSIDE the pane, and every external helper they
# run becomes #{pane_current_command} for a few milliseconds (observed: stty,
# grep, awk, ls, mkdir, diff, printf; tail up to ~0.4s). That churn is the whole
# reason tests/test-switcher.sh flaked. It also makes the reported command
# machine-dependent, so a local pass proves nothing about CI.
tmux -S "$AMUX_TEST_SOCK" -f /dev/null new-session -d -x 200 -y 50 \
  'ENV= exec /bin/sh'
```

- [x] **Step 2: Confirm no test assumed an interactive login shell**

Measured against the whole suite at `7bd1ed4` with this change applied:
**349 passed, 0 failed** — the same result as the unchanged harness. If a later
test does regress here, fix it at its own site; do not revert this task to
accommodate one of them.

**Check:**
```sh
tests/run.sh                                  # expect 0 failed
for i in $(seq 1 30); do bash tests/test-switcher.sh; done | grep -c FAIL   # expect 0
# and the churn is gone at the source
S="$(mktemp -d /tmp/amx.XXXX)/s"
tmux -S "$S" -f /dev/null new-session -d -x 200 -y 50 'ENV= exec /bin/sh'
for i in $(seq 1 2000); do tmux -S "$S" display-message -p '#{pane_current_command}'; done \
  | sort -u | wc -l                           # expect exactly 1 distinct value
tmux -S "$S" kill-server; rm -rf "$(dirname "$S")"
# The value itself is platform-dependent — macOS /bin/sh is bash in sh-mode and
# reports "bash". Assert that it never CHANGES, not what it is.
```

---

## Recommendation

Three approaches were considered. **Pin the pane (Task 2) is the one to take.**

| Approach | Verdict |
|---|---|
| **Pin the pane to a known long-lived command** | **Recommended.** The expected value becomes a literal in the test file, so the comparison has **zero** live reads on the test's side and one on the switcher's — and that one is against a pane measured at 0 strays in 6000 reads. Prototyped under the forced trigger: **0 mismatches in 200 read-pairs**, where the current code mismatches 17 % of the time. It also keeps the assertion honest: breaking `amux-switch`'s fallback still turns it red. |
| Capture the expected value **before** the switcher runs | **Rejected.** It still takes two reads of a live value, just in the other order. The captured failures show the mismatch firing in both directions — the switcher's read was the odd one out as often as the test's — so reordering moves the race, it does not close it. The forced trigger still fails against it. |
| Have the switcher **emit what it saw** | **Rejected.** It genuinely reduces the comparison to one read, but the test would then be comparing `amux-switch`'s output against `amux-switch`'s own report of its input. The assertion becomes a tautology: `label = (nm != "" ? nm : cmd)` could be replaced by `label = "XX"` and the test would still pass as long as the emitted field changed with it. Trading a flaky assertion for a vacuous one is a worse deal. |

Task 3 is complementary, not an alternative: it removes the churn that caused
this instance and pre-empts the next one, but on its own it would leave the
unsound two-read comparison in place for any pane that legitimately changes
command — which is the normal case for a real agent pane.

### Also worth knowing

`tests/test-panes.sh:137-144` already hit this exact bug class and fixed it by
collapsing both values into a **single** `list-panes -F` expansion:

```sh
plainrow="$(T list-panes -a -F '#{pane_id}|#{pane_current_command}|#{E:@amux-pane-border}' | grep "^$plain|")"
```

That works there because the rendered border is itself a tmux format, so tmux
expands both halves in one snapshot. It cannot work for the switcher, whose row
is built by an external script that issues its own `list-panes`. Pinning the
pane is the equivalent guarantee for that case.


---

## Execution record

Implemented on `worktree-switcher-flake`, one commit per task. Nothing pushed.

| Commit | Task | Files |
|---|---|---|
| `13af7aa` | 1 | Create `tests/live/switcher-read-race.sh` |
| `c351972` | 2 | Modify `tests/test-switcher.sh` |
| `90ff464` | 3 | Modify `tests/lib.sh` |

`scripts/amux-switch` is byte-identical to `main`. Every change is confined to
`tests/`.

### Proof, under the forced trigger rather than the natural rate

20 runs at `N=30` — 600 read-pairs per arm — with all three tasks applied:

| Arm | Runs that mismatched | Mismatched read-pairs |
|---|---|---|
| `CONTROL` — the pre-fix shape, two live reads | **20 / 20** | **163 / 600 (27 %)** |
| `SHIPPED` — the pinned shape, one read | **0 / 20** | **0 / 600** |

An identical sweep taken before Task 2 landed gave `CONTROL` 20/20 and 125/600,
so the trigger's strength is stable across the change and the fixed shape never
mismatched in 1200 read-pairs total.

For contrast, the natural rate that this replaces was 3 failures in 400 runs,
and it swung 3/160 in one batch to 0/240 in the next.

### Other verification

- `tests/test-switcher.sh`: 30/30 clean after Task 2, and again after Task 3.
- Negative control: replacing `amux-switch`'s `cmd` fallback with a constant
  turns the new assertion red, so it is not vacuous. `amux-switch` restored.
- `tests/run.sh`: **350 passed, 0 failed** (349 before; the pinned-pane
  stability assertion is the extra one).
- Task 3 at source: 2000 consecutive reads of a fresh initial pane return a
  single distinct value, against 10 strays in 12 000 for a login-shell pane.
