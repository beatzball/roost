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
TMP="$(cd -P "$TMP" && pwd)"

# --- tmux, kept away from the live servers ------------------------------------
# The script re-applies wiring on a RUNNING roost server, and with no
# ROOST_SOCKET it looks for `-L roost` — the author's live server, unless
# TMUX_TMPDIR points elsewhere. So every case below runs with TMUX_TMPDIR at a
# throwaway directory (the guard in tests/lib.sh refuses to go on otherwise),
# and $TMUX is dropped so nothing can find the server this suite runs inside.
# The one server this file starts is addressed by a socket PATH ending in
# /roost — roost-wiring only wires a socket that ends /roost, and a path,
# unlike `-L roost`, cannot resolve to the real directory if TMUX_TMPDIR were
# ever lost.
SOCKDIR="$(mktemp -d /tmp/amx.XXXX)"   # short: the ~104-byte socket path limit
export TMUX_TMPDIR="$SOCKDIR/tmpdir"; mkdir -p "$TMUX_TMPDIR"
roost_test_tmux_named_guard
unset TMUX TMUX_PANE ROOST_SOCKET ROOST_SELF_SOCK OPENCODE_CONFIG_DIR
UPG_SOCK="$SOCKDIR/roost"
trap 'tmux -S "$UPG_SOCK" kill-server 2>/dev/null; tmux -S "$SOCKDIR/notroost" kill-server 2>/dev/null; rm -rf "$TMP" "$SOCKDIR"' EXIT

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
export CLAUDE_CONFIG_DIR="$CANARY/claude-config"
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
cp "$HERE/scripts/roost-wiring" "$clone/scripts/roost-wiring"
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
  fake_installer "$1" > "$seed/scripts/roost-install"; chmod +x "$seed/scripts/roost-install"
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
assert_eq "$(tail -n 1 "$LOG")" "installer-v2 --yes" "current: the line it added is the current installer's, with --yes"

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

# --- configuration passed through the environment still reaches git --------------
# GIT_CONFIG_PARAMETERS is how `git -c` (and a proxy set by a wrapper) travels
# in the environment; it is kept on purpose. core.abbrev=12 is the observable:
# the upgrading line's short sha is 12 characters only if it got through.
reset_clone
ALL="$(GIT_CONFIG_PARAMETERS="'core.abbrev=12'" bash "$clone/scripts/roost-upgrade" --yes 2>&1)"
sha12="$(G -C "$clone" rev-parse HEAD | cut -c1-12)"
assert_contains "$ALL" "from $sha12 (" "GIT_CONFIG_PARAMETERS survives: the short sha is 12 characters"

# --- a GIT_INDEX_FILE inherited from elsewhere is ignored ----------------------
# Pointed at another repository's index, it would make the clean clone look
# dirty to `git status` (a refusal for the wrong reason) or, worse, steer the
# pull's checkout. The script unsets every variable git calls repo-local.
reset_clone
new="$(seed_commit v7)"; G -C "$clone" fetch -q origin
OUT="$(GIT_INDEX_FILE="$outer/.git/index" bash "$clone/scripts/roost-upgrade" --yes 2>"$TMP/err")"; RC=$?
ERR="$(cat "$TMP/err")"
assert_eq "$RC" "0" "inherited GIT_INDEX_FILE: rc 0 (no refusal for the wrong reason)"
assert_eq "$ERR" "" "inherited GIT_INDEX_FILE: nothing on stderr"
assert_eq "$(G -C "$clone" rev-parse HEAD)" "$new" "inherited GIT_INDEX_FILE: the pull happened"
assert_eq "$(G -C "$clone" status --porcelain)" "" "inherited GIT_INDEX_FILE: the clone's own index is clean after"
assert_eq "$(tail -n 1 "$LOG")" "installer-v7 --yes" "inherited GIT_INDEX_FILE: the installer ran"

# --- the pull removed the installer: say so, wire nothing ---------------------
reset_clone
G -C "$seed" rm -q scripts/roost-install; G -C "$seed" commit -qm "no installer"
G -C "$seed" push -q origin main
gone="$(G -C "$seed" rev-parse HEAD)"; G -C "$clone" fetch -q origin
log_before="$(cat "$LOG")"
run_upgrade --yes
assert_eq "$RC" "1" "installer gone after the pull: rc 1"
assert_contains "$ERR" "roost upgrade: the pull succeeded but $clone/scripts/roost-install is missing — nothing was wired" \
  "installer gone after the pull: the line names the missing file"
assert_eq "$(G -C "$clone" rev-parse HEAD)" "$gone" "installer gone after the pull: HEAD moved (it did pull)"
assert_eq "$(cat "$LOG")" "$log_before" "installer gone after the pull: no installer ran"
seed_commit v8 >/dev/null   # puts the fake installer back for the cases below

# --- --dry-run passes through, and the pull is NOT dry -------------------------
reset_clone
new="$(seed_commit v6)"; G -C "$clone" fetch -q origin
run_upgrade --dry-run
assert_eq "$RC" "0" "--dry-run: rc 0"
assert_eq "$(G -C "$clone" rev-parse HEAD)" "$new" \
  "--dry-run: the pull still happened (only the installer is dry)"
assert_eq "$(tail -n 1 "$LOG")" "installer-v6 --dry-run" "--dry-run: passed through to the installer"

# --- wiring is re-applied on a running server ----------------------------------
# The opencode 2 story in one command: a server wired while opencode was 1.x
# carries roost's OPENCODE_CONFIG_DIR, and the upgrade's apply — run with a
# 2.x opencode on PATH — must take it away. The stubs go IN FRONT of the
# normal PATH rather than replacing it: the run also needs git, tmux and
# cksum, and only `opencode` has to be the stub.
opencode_stub() { # opencode_stub VERSIONLINE -> prints a dir to put first on PATH
  local d; d="$(mktemp -d "$TMP/oc.XXXX")"
  printf "#!/bin/sh\necho '%s'\n" "$1" > "$d/opencode"; chmod +x "$d/opencode"
  printf '%s' "$d"
}
OC1="$(opencode_stub '1.18.30')"; OC2="$(opencode_stub 'opencode v2.0.20')"
WXDG="$TMP/wiring-xdg"
WDIR_OC="$WXDG/roost/wiring/$(printf '%s' "$clone" | cksum | cut -d' ' -f1)/opencode"
ts() { tmux -S "$UPG_SOCK" "$@"; }

reset_clone
ts -f /dev/null new-session -d -x 200 -y 50 'ENV= exec /bin/sh'
# What bin/roost's ensure_session records on a server it starts.
ts set-environment -g ROOST_HOME "$clone"; ts set-option -g @roost-home "$clone"
PATH="$OC1:$PATH" XDG_CONFIG_HOME="$WXDG" ROOST_SOCKET="$UPG_SOCK" \
  "$clone/scripts/roost-wiring" apply
OCDIR_SET="OPENCODE_CONFIG_DIR=$WDIR_OC"
assert_eq "$(ts show-environment -g OPENCODE_CONFIG_DIR)" "$OCDIR_SET" \
  "wiring: with opencode 1.x the server carries roost's OPENCODE_CONFIG_DIR (setup)"

# up_w ARGS... -> an (already current) upgrade with opencode 2.x on PATH,
# against the test server; ALL is stdout and stderr together.
up_w() {
  ALL="$(PATH="$OC2:$PATH" XDG_CONFIG_HOME="$WXDG" ROOST_SOCKET="${UP_SOCK:-$UPG_SOCK}" \
    bash "$clone/scripts/roost-upgrade" "$@" 2>&1)"; RC=$?
}
no_wiring_line() { # NAME
  case "$ALL" in *wiring*) false ;; *) true ;; esac
  assert_true $? "$1: no wiring line at all"
}

# --dry-run: the installer will end with "nothing above was written", so the
# wiring step must not write either.
up_w --dry-run
assert_eq "$RC" "0" "wiring --dry-run: rc 0"
assert_contains "$ALL" "(--dry-run: wiring not re-applied)" "wiring --dry-run: says it skipped the wiring"
assert_eq "$(ts show-environment -g OPENCODE_CONFIG_DIR)" "$OCDIR_SET" \
  "wiring --dry-run: the server's OPENCODE_CONFIG_DIR is unchanged"

# wiring turned off with the marker `roost wiring remove` leaves: apply
# succeeds and does nothing, so "re-applied" would be a lie.
mkdir -p "$WXDG/roost"; : > "$WXDG/roost/wiring.off"
ts set-option -gu @roost-wiring-active
up_w --yes
assert_eq "$RC" "0" "wiring.off: rc 0"
case "$ALL" in *"wiring re-applied"*) false ;; *) true ;; esac
assert_true $? "wiring.off: no re-applied line"
assert_contains "$ALL" "roost: wiring is off on the running server; not re-applied (roost wiring on turns it on)" \
  "wiring.off: says wiring is off"
assert_eq "$(ts show-environment -g OPENCODE_CONFIG_DIR)" "$OCDIR_SET" "wiring.off: the server is unchanged"
rm -f "$WXDG/roost/wiring.off"

# the same through the server option a roost.conf can set. Both are states
# `roost wiring off|remove` leave with @roost-wiring-active unset, as above.
ts set-option -g @roost-wiring-enabled off
up_w --yes
assert_contains "$ALL" "roost: wiring is off on the running server; not re-applied (roost wiring on turns it on)" \
  "@roost-wiring-enabled off: says wiring is off"
assert_eq "$(ts show-environment -g OPENCODE_CONFIG_DIR)" "$OCDIR_SET" "@roost-wiring-enabled off: the server is unchanged"
ts set-option -gu @roost-wiring-enabled; ts set-option -g @roost-wiring-active on

# a server started from ANOTHER checkout is left alone
mkdir -p "$TMP/elsewhere"
ts set-environment -g ROOST_HOME "$TMP/elsewhere"; ts set-option -g @roost-home "$TMP/elsewhere"
up_w --yes
assert_eq "$RC" "0" "other checkout's server: rc 0"
assert_contains "$ALL" "roost: the running server was started from $TMP/elsewhere, not this checkout; wiring not re-applied" \
  "other checkout's server: says whose server it is"
assert_eq "$(ts show-environment -g OPENCODE_CONFIG_DIR)" "$OCDIR_SET" "other checkout's server: unchanged"
ts set-environment -g ROOST_HOME "$clone"; ts set-option -g @roost-home "$clone"

# a running server whose socket does not end in /roost is not roost's
OTHER_SOCK="$SOCKDIR/notroost"
tmux -S "$OTHER_SOCK" -f /dev/null new-session -d 'ENV= exec /bin/sh'
UP_SOCK="$OTHER_SOCK" up_w --yes
assert_eq "$RC" "0" "non-roost server: rc 0"
no_wiring_line "non-roost server"
tmux -S "$OTHER_SOCK" kill-server

new="$(seed_commit v9)"; G -C "$clone" fetch -q origin

OUT="$(PATH="$OC2:$PATH" XDG_CONFIG_HOME="$WXDG" ROOST_SOCKET="$UPG_SOCK" \
  bash "$clone/scripts/roost-upgrade" --yes 2>"$TMP/err")"; RC=$?
ERR="$(cat "$TMP/err")"
assert_eq "$RC" "0" "wiring: rc 0"
assert_contains "$OUT" "roost: wiring re-applied on the running server" "wiring: says it re-applied"
assert_eq "$(G -C "$clone" rev-parse HEAD)" "$new" "wiring: the pull happened"
# `set-environment -gu` removes the variable from the global environment
# outright, so show-environment fails for it (tmux 3.6 here, and the same
# assertion tests/test-wiring.sh makes) rather than printing `-NAME`.
ts show-environment -g OPENCODE_CONFIG_DIR >/dev/null 2>&1
assert_eq "$?" "1" "wiring: with opencode 2.x on PATH the upgrade removed roost's OPENCODE_CONFIG_DIR"
assert_eq "$(tail -n 1 "$LOG")" "installer-v9 --yes" "wiring: the installer still ran after"

# Control: the same run with no server on that socket wires nothing, says
# nothing about wiring, and still upgrades.
ts kill-server
reset_clone
new="$(seed_commit v10)"; G -C "$clone" fetch -q origin
OUT="$(PATH="$OC2:$PATH" XDG_CONFIG_HOME="$WXDG" ROOST_SOCKET="$UPG_SOCK" \
  bash "$clone/scripts/roost-upgrade" --yes 2>"$TMP/err")"; RC=$?
assert_eq "$RC" "0" "no server: rc 0"
case "$OUT$(cat "$TMP/err")" in *wiring*) false ;; *) true ;; esac
assert_true $? "no server: no wiring line"
assert_eq "$(G -C "$clone" rev-parse HEAD)" "$new" "no server: the pull happened"
assert_eq "$(tail -n 1 "$LOG")" "installer-v10 --yes" "no server: the installer ran"
ts list-sessions >/dev/null 2>&1; assert_eq "$?" "1" "no server: the throwaway server is gone"

# --- `update` is the same command as `upgrade` --------------------------------
# Through bin/roost itself, from THIS checkout: --help prints and exits before
# the gate, so nothing is pulled. Identical stdout and rc 0 is what pins one
# dispatch arm; the usage text proves the upgrade script is what answered.
UP_HELP="$(bash "$HERE/bin/roost" upgrade --help </dev/null 2>&1)"; UP_RC=$?
UPD_HELP="$(bash "$HERE/bin/roost" update --help </dev/null 2>&1)"; UPD_RC=$?
assert_eq "$UP_RC" "0" "bin/roost upgrade --help: rc 0"
assert_eq "$UPD_RC" "0" "bin/roost update --help: rc 0"
assert_contains "$UP_HELP" "usage: roost upgrade" "bin/roost upgrade --help: the upgrade script answered"
assert_eq "$UPD_HELP" "$UP_HELP" "bin/roost update --help is identical to upgrade --help"

# --- the canary must be empty ------------------------------------------------
assert_eq "$(canary_leaks)" "" "nothing wrote outside the scratch homes"
unset GIT_CONFIG_GLOBAL

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
