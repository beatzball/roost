#!/usr/bin/env bash
# tests/test-upgrade.sh — scripts/roost-upgrade: the gate, the pull, the exec.
#
# Everything runs against a throwaway clone of a local bare repository, never
# this checkout: the script under test runs `git pull` and then an installer,
# and this machine runs the author's live agents from the primary checkout.
# The installer it execs is a fake that only records its argv, and every home
# an installer could write to is redirected below.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd -P "$TMP" && pwd)"

# --- the sandbox canary -----------------------------------------------------
# Every variable an installer can be steered by, exported at one directory
# that NOTHING below may write to. The fake installer writes nowhere but its
# log, so a leak here means the REAL installer ran. See tests/test-install.sh
# for the leak this guards against (AGENTS.md §8).
CANARY="$TMP/canary"
export ZDOTDIR="$CANARY/zdot"
export XDG_CONFIG_HOME="$CANARY/xdg-config"
export XDG_DATA_HOME="$CANARY/xdg-data"
export COPILOT_HOME="$CANARY/copilot"
export PI_CODING_AGENT_DIR="$CANARY/pi/agent"
export CODEX_HOME="$CANARY/codex"
export CLAUDE_SETTINGS="$CANARY/claude/settings.json"
export HOME="$TMP/home"; mkdir -p "$HOME"
canary_leaks() { find "$CANARY" -mindepth 1 2>/dev/null | sort; }

# The author's git config (signing, hooks, identity) is never read: every git
# below, and the pull inside the script under test, sees none of it.
export GIT_CONFIG_GLOBAL=/dev/null
G() { git -c core.hooksPath=/dev/null -c commit.gpgsign=false \
        -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }

LOG="$TMP/installer.log"
: > "$LOG"

# fake_installer VERSION -> a POSIX stub that appends "installer-VERSION argv"
fake_installer() {
  cat <<EOF
#!/bin/sh
printf 'installer-$1 %s\n' "\$*" >> "$LOG"
EOF
}

# --- the remote, the seed, the clone ------------------------------------------
G init -q --bare "$TMP/origin.git"
G -C "$TMP/origin.git" symbolic-ref HEAD refs/heads/main
seed="$TMP/seed"
G init -q "$seed"
mkdir -p "$seed/bin" "$seed/scripts" "$seed/tmux"
printf '#!/bin/sh\n' > "$seed/bin/roost"; chmod +x "$seed/bin/roost"
printf '# roost\n' > "$seed/tmux/roost.conf"
printf '0.7.0\n' > "$seed/VERSION"
fake_installer v1 > "$seed/scripts/roost-install"; chmod +x "$seed/scripts/roost-install"
G -C "$seed" add -A; G -C "$seed" commit -qm seed
G -C "$seed" push -q "$TMP/origin.git" main
G -C "$seed" remote add origin "$TMP/origin.git"
G -C "$seed" fetch -q origin; G -C "$seed" branch -q -u origin/main

clone="$TMP/clone"
G clone -q "$TMP/origin.git" "$clone"
# The code under test, committed so it is what the clone's main tracks.
cp "$HERE/scripts/roost-upgrade" "$clone/scripts/roost-upgrade"
cp -R "$HERE/scripts/lib" "$clone/scripts/"
G -C "$clone" add -A; G -C "$clone" commit -qm "the code"
G -C "$clone" push -q origin main
G -C "$seed" pull -q --ff-only

# run_upgrade ARGS... -> sets OUT, ERR, RC
run_upgrade() {
  OUT="$(bash "$clone/scripts/roost-upgrade" "$@" 2>"$TMP/err")"; RC=$?
  ERR="$(cat "$TMP/err")"
}

# seed_commit VERSION [FILE] -> pushes one commit to origin from the seed and
# prints its sha. The fake installer becomes installer-VERSION.
seed_commit() {
  fake_installer "$1" > "$seed/scripts/roost-install"
  [ -n "${2:-}" ] && printf 'new\n' > "$seed/$2"
  G -C "$seed" add -A; G -C "$seed" commit -qm "$1"
  G -C "$seed" push -q origin main
  G -C "$seed" rev-parse HEAD
}

# reset_clone -> a plain main, at origin/main, with an upstream, nothing local.
reset_clone() {
  G -C "$clone" config --unset remote.origin.uploadpack || true
  G -C "$clone" fetch -q origin
  G -C "$clone" checkout -q -f main
  G -C "$clone" reset -q --hard origin/main
  G -C "$clone" branch -q -u origin/main main
  G -C "$clone" clean -qfdx
}

# --- help -------------------------------------------------------------------
run_upgrade --help
assert_eq "$RC" "0" "--help exits 0"
assert_prefix "$OUT" "usage: roost upgrade [-y|--yes] [--dry-run] [--only H[,H...]]" \
  "--help prints the usage line"
assert_contains "$OUT" "Refused when this checkout is not a plain \`main\` with no local work." \
  "--help names the gate"
assert_eq "$(cat "$LOG")" "" "--help runs no installer"

# --- behind by one: the NEW installer runs, with the flag ---------------------
new="$(seed_commit v2)"
old_short="$(G -C "$clone" rev-parse --short HEAD)"
G -C "$clone" fetch -q origin   # git must KNOW it is behind; the script never fetches first
run_upgrade --yes
assert_eq "$RC" "0" "behind by one: rc 0"
assert_eq "$OUT" "roost: upgrading $clone from $old_short (0.7.0) — 1 commit(s) behind origin/main" \
  "behind by one: the upgrading line names the sha, version and count"
assert_eq "$(G -C "$clone" rev-parse HEAD)" "$new" "behind by one: HEAD is the pushed commit"
assert_eq "$(tail -n 1 "$LOG")" "installer-v2 --yes" \
  "behind by one: the installer the pull fetched ran, with --yes passed through"

# --- current: still runs the installer ---------------------------------------
lines_before="$(wc -l < "$LOG")"
run_upgrade --yes
assert_eq "$RC" "0" "current: rc 0"
assert_contains "$OUT" "— already current with origin/main" "current: the line says already current"
assert_eq "$(( $(wc -l < "$LOG") - lines_before ))" "1" "current: the installer still ran once"

# --- the refusals ---------------------------------------------------------------
# No-fetch proof, three ways, because one alone can be silenced. Before each
# refusal the clone's remote gets a spy upload-pack: any fetch or pull starts
# it, it records that it ran and fails. So (1) the spy's log must stay empty,
# even if a fetch's own error were hidden; (2) stderr must be EXACTLY the
# gate's three lines, with nothing from git; and (3) FETCH_HEAD, removed first,
# must still be absent (git writes it even for a fetch that fails, measured on
# git 2.50.1 with a fetch planted ahead of the gate).
WORKING="  This looks like a working copy. Sort it out by hand, or install a plain copy with:"
REINSTALL="  To install or reinstall roost:"
CURL="  curl -fsSL https://raw.githubusercontent.com/beatzball/roost/main/install.sh | sh"

# expect_refusal NAME DIR REASON FALLBACK [runner] — run, then assert
expect_refusal() {
  local name="$1" dir="$2" reason="$3" fallback="$4" log_before
  log_before="$(cat "$LOG")"
  OUT="$(bash "$dir/scripts/roost-upgrade" --yes 2>"$TMP/err")"; RC=$?
  ERR="$(cat "$TMP/err")"
  assert_eq "$RC" "1" "$name: rc 1"
  assert_eq "$ERR" "roost upgrade: refused — $reason
$fallback
$CURL" "$name: stderr is the reason, the fallback and the curl line, and nothing from git"
  assert_eq "$OUT" "" "$name: nothing on stdout (no upgrading line)"
  assert_eq "$(cat "$LOG")" "$log_before" "$name: no installer ran"
}

SPY="$TMP/spy-upload-pack"; SPYLOG="$TMP/spy.log"; : > "$SPYLOG"
printf '#!/bin/sh\necho fetched >> "%s"\nexit 1\n' "$SPYLOG" > "$SPY"; chmod +x "$SPY"
break_remote() {
  G -C "$clone" config remote.origin.uploadpack "$SPY"
  rm -f "$clone/.git/FETCH_HEAD"
}
head_unmoved() { # NAME SHA
  assert_eq "$(G -C "$clone" rev-parse HEAD)" "$2" "$1: HEAD did not move"
  assert_file_absent "$clone/.git/FETCH_HEAD" "$1: no FETCH_HEAD was written (no fetch)"
  assert_eq "$(cat "$SPYLOG")" "" "$1: the remote was never contacted"
}

# a worktree of the clone
reset_clone; seed_commit v3 >/dev/null; G -C "$clone" fetch -q origin
wt="$TMP/clone-wt"
G -C "$clone" worktree add -q -b side "$wt"
break_remote
here_wt="$(cd -P "$wt" && pwd)"
expect_refusal "worktree" "$wt" "$here_wt is a git worktree" "$WORKING"
assert_eq "$(G -C "$wt" rev-parse HEAD)" "$(G -C "$clone" rev-parse HEAD)" "worktree: its HEAD did not move"
assert_eq "$(cat "$SPYLOG")" "" "worktree: the remote was never contacted"
G -C "$clone" worktree remove --force "$wt"; G -C "$clone" branch -q -D side

# a branch checked out
reset_clone; sha="$(G -C "$clone" rev-parse HEAD)"
G -C "$clone" checkout -q -b feature
break_remote
expect_refusal "branch" "$clone" "$clone is on branch feature, not main" "$WORKING"
head_unmoved "branch" "$sha"

# a detached HEAD
reset_clone; sha="$(G -C "$clone" rev-parse HEAD)"
G -C "$clone" checkout -q --detach
break_remote
expect_refusal "detached" "$clone" "$clone is on a detached HEAD" "$WORKING"
head_unmoved "detached" "$sha"

# no upstream
reset_clone; sha="$(G -C "$clone" rev-parse HEAD)"
G -C "$clone" branch -q --unset-upstream
break_remote
expect_refusal "no upstream" "$clone" "main has no upstream to pull from" "$REINSTALL"
head_unmoved "no upstream" "$sha"

# one local commit
reset_clone
printf 'local\n' > "$clone/local.txt"; G -C "$clone" add local.txt; G -C "$clone" commit -qm local
sha="$(G -C "$clone" rev-parse HEAD)"
break_remote
expect_refusal "local commit" "$clone" "$clone has 1 local commit(s) on main that are not on origin/main" "$WORKING"
head_unmoved "local commit" "$sha"

# a tracked change
reset_clone; sha="$(G -C "$clone" rev-parse HEAD)"
echo x >> "$clone/VERSION"
break_remote
expect_refusal "tracked change" "$clone" "$clone has uncommitted changes to tracked files" "$WORKING"
head_unmoved "tracked change" "$sha"

# not a git checkout: a plain copy of the scripts, outside any repository
plain="$TMP/plain"; mkdir -p "$plain/scripts"
cp "$clone/scripts/roost-upgrade" "$plain/scripts/"; cp -R "$clone/scripts/lib" "$plain/scripts/"
expect_refusal "not a checkout" "$plain" "$plain is not a git checkout" "$REINSTALL"

# a plain copy INSIDE someone else's repository (a dotfiles repo, say) is not
# a roost checkout either: pulling would update THEIR repo.
outer="$TMP/outer"; G init -q "$outer"; mkdir -p "$outer/roost/scripts"
cp "$clone/scripts/roost-upgrade" "$outer/roost/scripts/"; cp -R "$clone/scripts/lib" "$outer/roost/scripts/"
G -C "$outer" add -A; G -C "$outer" commit -qm dotfiles
expect_refusal "nested in another repo" "$outer/roost" "$outer/roost is not a git checkout" "$REINSTALL"

# no git on PATH
nogit="$TMP/nogit"; mkdir -p "$nogit"
for b in bash sh cat cp mv rm mkdir dirname readlink ln find grep sed env printf true false chmod pwd; do
  real="$(command -v "$b" 2>/dev/null)" && [ "$real" != "$b" ] && ln -s "$real" "$nogit/$b" 2>/dev/null
done
reset_clone; sha="$(G -C "$clone" rev-parse HEAD)"
break_remote
log_before="$(cat "$LOG")"
OUT="$(PATH="$nogit" "$nogit/bash" "$clone/scripts/roost-upgrade" --yes 2>"$TMP/err")"; RC=$?
ERR="$(cat "$TMP/err")"
assert_eq "$RC" "1" "no git: rc 1"
assert_eq "$ERR" "roost upgrade: refused — git is not on PATH
$REINSTALL
$CURL" "no git: the reason, the fallback and the curl line"
assert_eq "$(cat "$LOG")" "$log_before" "no git: no installer ran"
head_unmoved "no git" "$sha"

# --- an untracked file is not a refusal ---------------------------------------
reset_clone
printf 'notes\n' > "$clone/roost-validation-notes.md"
new="$(seed_commit v4)"; G -C "$clone" fetch -q origin
run_upgrade --yes
assert_eq "$RC" "0" "untracked file: not refused, rc 0"
assert_eq "$(G -C "$clone" rev-parse HEAD)" "$new" "untracked file: the pull happened"
assert_eq "$(tail -n 1 "$LOG")" "installer-v4 --yes" "untracked file: the installer ran"

# --- the pull fails: nothing is wired ----------------------------------------
reset_clone; sha="$(G -C "$clone" rev-parse HEAD)"
seed_commit v5 newfile >/dev/null; G -C "$clone" fetch -q origin
printf 'mine\n' > "$clone/newfile"
log_before="$(cat "$LOG")"
run_upgrade --yes
assert_eq "$RC" "1" "pull fails: rc 1"
assert_contains "$ERR" "roost upgrade: git pull --ff-only failed — nothing was wired" \
  "pull fails: the pull-failure line"
assert_contains "$OUT" "1 commit(s) behind origin/main" "pull fails: the upgrading line was printed first"
assert_eq "$(cat "$LOG")" "$log_before" "pull fails: no installer ran"
assert_eq "$(G -C "$clone" rev-parse HEAD)" "$sha" "pull fails: HEAD did not move"

# --- --dry-run passes through, and the pull is NOT dry -------------------------
reset_clone
new="$(seed_commit v6)"; G -C "$clone" fetch -q origin
run_upgrade --dry-run
assert_eq "$RC" "0" "--dry-run: rc 0"
assert_eq "$(G -C "$clone" rev-parse HEAD)" "$new" \
  "--dry-run: the pull still happened (only the installer is dry)"
assert_eq "$(tail -n 1 "$LOG")" "installer-v6 --dry-run" "--dry-run: passed through to the installer"

# --- the canary must be empty ------------------------------------------------
assert_eq "$(canary_leaks)" "" "nothing wrote outside the scratch homes"
unset GIT_CONFIG_GLOBAL

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
