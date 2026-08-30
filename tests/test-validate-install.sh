#!/usr/bin/env bash
# tests/test-validate-install.sh — scripts/roost-validate's adapter install
# offer: the policy it has always had, and the fact that the writing itself is
# scripts/roost-install's job now rather than a second copy of the same loop.
#
# WHY THIS FILE EXISTS SEPARATELY from tests/test-adapter-install.sh: that file
# is about the installer's own behaviour, and this one is about the CALLER's
# policy, which is deliberately narrower than the installer's. The sharpest
# case is a dangling adapter symlink: `roost install` is right to relink one
# (it is ours and it is broken), and `roost validate` is right to leave it
# alone (its report promises the tester that nothing but a missing link was
# touched). Both behaviours are correct, they are not the same behaviour, and
# only a test aimed at validate can tell them apart.
#
# EVERY case runs against a scratch HOME, XDG_CONFIG_HOME, XDG_DATA_HOME,
# COPILOT_HOME, PI_CODING_AGENT_DIR and CODEX_HOME under one `mktemp -d`, and
# against FAKE harness binaries on a shim PATH — the developer running this
# suite has live agent configuration in ~/.claude, ~/.codex, ~/.copilot,
# ~/.config/opencode and ~/.pi, and a case that reached any of those would link
# into real config on a machine driving real agents. Per AGENTS.md §8 the XDG
# variables are not enough on their own: copilot, pi and codex each read their
# OWN home variable, so all three are set too.
set -u
. "$(dirname "$0")/lib.sh"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

TMP="$(mktemp -d /tmp/amx.XXXX)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# --- a checkout of our own -------------------------------------------------
# roost validate resolves $HERE from its own file's location and then reaches
# for "$HERE/scripts/lib/roost-adapters.sh" and "$HERE/scripts/roost-install",
# and scripts/lib/roost-adapters.sh resolves the symlink TARGETS from its own
# location in the same way (never from $ROOST_HOME — its comment records the
# measured bug that inherited variable caused). So the slice below has to sit
# in a directory shaped like a checkout, or $HERE lands in /tmp and the offer
# would either fail to source the table or link at paths in the wrong tree.
#
# A copy rather than a symlink farm: with `scripts` copied and `adapters`
# copied, validate's $HERE, the installer's own $HERE and the adapter targets
# all resolve to this one directory and cannot disagree. It is the same bytes
# either way — nothing here rewrites what it copied.
CO="$TMP/co"
mkdir -p "$CO"
cp -R "$REPO/scripts" "$CO/scripts"
cp -R "$REPO/adapters" "$CO/adapters"

# --- the slice under test --------------------------------------------------
# roost validate is not a library: sourcing the whole file runs the whole run
# — every drive, every smoke suite, a tmux server of its own. Everything above
# `# --- main` is definitions plus the report scaffolding, so that is what the
# driver sources, and the marker is the file's own section heading rather than
# a line number that drifts.
HEAD="$CO/scripts/roost-validate-head"
sed '/^# --- main /,$d' "$CO/scripts/roost-validate" > "$HEAD"
# If the slice ever stops containing the function, every case below would pass
# vacuously against a shell that defines nothing. Die loudly instead: a
# non-zero exit is what tests/run.sh reports as a file that died mid-run, and
# no PASS/FAIL count would have shown this.
grep -q '^offer_adapter_install() {' "$HEAD" || {
  printf '  FAIL: the slice of roost-validate carries no offer_adapter_install\n'; exit 1; }
# And the other direction: `offer_adapter_install` on a line of its own is the
# run CALLING it, which is the first thing past the marker. If that survives
# the cut, sourcing the slice starts a real validation run.
grep -q '^offer_adapter_install$' "$HEAD" && {
  printf '  FAIL: the slice reaches past the definitions into the run itself\n'; exit 1; }

DRIVER="$TMP/driver.sh"
cat > "$DRIVER" <<'DRIVER'
#!/usr/bin/env bash
# driver.sh SLICE [roost validate args...] — source the slice, ask the one
# question, and print what the report would have been built from.
set -u
slice="$1"; shift
# shellcheck disable=SC1090
. "$slice" "$@"
# The slice installs roost validate's own EXIT trap, which assembles and writes
# a whole report. Nothing here runs a check, so there is nothing to assemble.
trap - EXIT
offer_adapter_install
rc=$?
# The five things the report is made of, in a shape no prose line can collide
# with. Asserting on the offer's console prose alone is how a case goes green
# against the wrong line; these are the values themselves.
printf '\n===RESULT===\n'
printf 'RC\t%s\n' "$rc"
printf 'DECISION\t%s\n' "$INSTALL_DECISION"
printf '%s' "$INSTALLED_LINKS" | while read -r p; do
  [ -n "$p" ] && printf 'INSTALLED\t%s\n' "$p"
done
printf '%s' "$BLOCKED_LINKS" | while IFS="$(printf '\t')" read -r h p; do
  [ -n "$h" ] && printf 'BLOCKED\t%s\t%s\n' "$h" "$p"
done
# :- so that a slice which does not define this variable at all fails the
# assertions that name it, rather than dying on `set -u` and taking every
# other case in the file down with it.
printf '%s' "${ALREADY_LINKED:-}" | while IFS="$(printf '\t')" read -r h p; do
  [ -n "$h" ] && printf 'ALREADY\t%s\t%s\n' "$h" "$p"
done
rm -rf "$WORK"
DRIVER

# --- fake harness binaries -------------------------------------------------
# The offer detects harnesses with `command -v` (roost-validate's have()), so
# the shim IS the machine's harness inventory as far as a case is concerned,
# and it REPLACES PATH rather than prepending to it: the developer running this
# suite really does have opencode installed, and a prepended shim would leave
# the real one findable.
#
# `tr` and `cut` are deliberately absent, exactly as they are from
# tests/test-adapter-install.sh's shim. Both scripts build their harness lists
# with bash's own parameter expansion for that reason, and a shim that carried
# the two would let a reintroduced `tr` pass here and fail on a thin PATH.
#
# python3 and jq are on the list, and that is load-bearing rather than
# convenience: without a JSON engine `roost install` cannot edit a config file
# at all and prints the block to paste instead, so a case built on a shim
# without one would pass the "nothing but symlinks was written" assertion on a
# machine where nothing COULD be written — and dropping --symlinks-only from
# the call would sail straight through it.
CORE_BINS="bash sh cat cp mv rm mkdir mktemp dirname readlink ln find grep sed date env printf true false chmod stat cmp id hostname wc sort python3 jq"
make_shim() { # make_shim NAME... -> prints a PATH dir
  local dir h real
  dir="$(mktemp -d /tmp/amx.XXXX)"
  for h in $CORE_BINS; do
    real="$(command -v "$h" 2>/dev/null)" && ln -s "$real" "$dir/$h" 2>/dev/null
  done
  for h in "$@"; do
    printf '#!/bin/sh\nexit 0\n' > "$dir/$h"
    chmod +x "$dir/$h"
  done
  printf '%s' "$dir"
}
ALL_SHIM="$(make_shim opencode pi copilot)"

# --- one sandboxed offer ---------------------------------------------------
# stdin is /dev/null: with no terminal the offer must resolve to no on its own,
# and a case that inherited the runner's stdin would be answering a question it
# was never asked.
run_offer() { # run_offer BOX [validate args...]
  local box="$1"; shift
  mkdir -p "$box/home"
  HOME="$box/home" \
  XDG_CONFIG_HOME="$box/home/.config" \
  XDG_DATA_HOME="$box/home/.local/share" \
  COPILOT_HOME="$box/home/.copilot" \
  PI_CODING_AGENT_DIR="$box/home/.pi/agent" \
  CODEX_HOME="$box/home/.codex" \
  CLAUDE_SETTINGS="$box/home/.claude/settings.json" \
  PATH="$ALL_SHIM" \
    bash "$DRIVER" "$HEAD" --out "$box/report.md" "$@" </dev/null 2>&1
}

# result_of OUTPUT -> just the ===RESULT=== block, so an assertion about
# INSTALL_DECISION can never match the same words in the offer's own prose.
result_of() { printf '%s' "${1##*===RESULT===}"; }

# The paths, computed the way the code computes them — via the copied
# scripts/lib/roost-adapters.sh, never restated here. If this test and the
# table ever disagreed about where an adapter goes, that disagreement is the
# bug, and a second spelling would hide it.
apath() { # apath BOX HARNESS
  local box="$1" h="$2"
  HOME="$box/home" \
  XDG_CONFIG_HOME="$box/home/.config" \
  COPILOT_HOME="$box/home/.copilot" \
  PI_CODING_AGENT_DIR="$box/home/.pi/agent" \
  CODEX_HOME="$box/home/.codex" \
    bash -c '. "'"$CO"'/scripts/lib/roost-adapters.sh"; roost_adapter_path "$1"' _ "$h"
}
atarget() { bash -c '. "'"$CO"'/scripts/lib/roost-adapters.sh"; roost_adapter_target "$1"' _ "$1"; }
links_in() { local n; n="$(find "$1/home" -type l 2>/dev/null | wc -l)"; printf '%s' "$((n))"; }

# ===========================================================================
# 1. --local -> not applicable, and nothing on the real machine is touched
# ===========================================================================
# --local builds a scratch config directory per harness and links the adapters
# in THERE, so there is nothing on the tester's own machine to offer. This is
# the one branch that must never reach an installer at all.
box="$TMP/local"
out="$(run_offer "$box" --local)"
res="$(result_of "$out")"
assert_contains "$res" \
  "DECISION	not applicable — --local links the adapters inside its own scratch config directories" \
  "--local: the decision line says not applicable"
assert_eq "$(links_in "$box")" "0" "--local: no symlink is created anywhere under HOME"

# ===========================================================================
# 2. --install -> the three links, and nothing else at all
# ===========================================================================
box="$TMP/yes"
out="$(run_offer "$box" --install)"
res="$(result_of "$out")"
assert_eq "$(links_in "$box")" "3" "--install: the three adapter symlinks are created"
for h in opencode pi copilot; do
  p="$(apath "$box" "$h")"
  assert_eq "$(readlink "$p" 2>/dev/null)" "$(atarget "$h")" \
    "--install: the $h link points at this checkout's adapter"
  assert_contains "$res" "INSTALLED	$p" "--install: $h is recorded in INSTALLED_LINKS for the undo"
done
assert_contains "$res" \
  "DECISION	offered and accepted — this run created 3 adapter symlink(s); see the undo below" \
  "--install: the decision line counts the three links"
case "$res" in *"BLOCKED	"*) s=some ;; *) s=none ;; esac
assert_eq "$s" "none" "--install: nothing is reported as blocked when all three were missing"

# Symlinks only. Not "no hooks were wired" by inspection of one file — nothing
# that is not a symlink may appear under HOME at all, which is the promise
# report_install prints to the tester in writing.
notlinks="$(find "$box/home" ! -type d ! -type l 2>/dev/null)"
assert_eq "$notlinks" "" "--install: no hooks file, settings.json or trust entry is written"

# The tester answered validate's question, not the installer's, and must not be
# shown the installer's plan on top of the one they just read.
case "$out" in *"Write the above? [y/N]"*) s=asked ;; *) s=absent ;; esac
assert_eq "$s" "absent" "--install: the installer's own prompt is never printed"
assert_contains "$out" "  Linking them (--install/--yes)." \
  "--install: validate's own wording for the answer is kept"

# ===========================================================================
# 3. --no-install -> nothing is written, and the report says who stayed unlinked
# ===========================================================================
box="$TMP/no"
out="$(run_offer "$box" --no-install)"
res="$(result_of "$out")"
assert_eq "$(links_in "$box")" "0" "--no-install: nothing is linked"
assert_contains "$res" "DECISION	offered and declined — opencode, pi, copilot stayed unlinked" \
  "--no-install: the decision line names the harnesses that stayed unlinked"
assert_contains "$out" "  --no-install was passed. Skipping those harnesses." \
  "--no-install: validate says so in its own words"

# ===========================================================================
# 4. no answer, no terminal -> no
# ===========================================================================
# A pipe, a cron, a CI step. Nobody is there to consent, and a "y" that happens
# to be on stdin is not a person answering.
box="$TMP/pipe"
out="$(run_offer "$box")"
res="$(result_of "$out")"
assert_eq "$(links_in "$box")" "0" "not a terminal: nothing is linked"
assert_contains "$res" "DECISION	offered and declined — opencode, pi, copilot stayed unlinked" \
  "not a terminal: the decision line is the declined one"
assert_contains "$out" "  Not a terminal, so nothing was asked and nothing was linked." \
  "not a terminal: validate says nothing was asked"
assert_contains "$out" "  Pass --install to link them in an unattended run." \
  "not a terminal: the way to opt in is printed"

# ===========================================================================
# 5. a foreign path is never replaced
# ===========================================================================
# Someone's own extension, or another checkout's link. It survives byte for
# byte, it is reported, and the other two harnesses are still linked — the
# offer is not all-or-nothing.
box="$TMP/foreign"
mkdir -p "$box/home/.pi/agent/extensions"
printf 'my own extension\n' > "$box/home/.pi/agent/extensions/roost.ts"
fpath="$(apath "$box" pi)"
fbefore="$(cksum < "$fpath")"
out="$(run_offer "$box" --install)"
res="$(result_of "$out")"
assert_eq "$(cksum < "$fpath")" "$fbefore" "foreign: the file that was there is byte-identical after"
assert_contains "$res" "BLOCKED	pi	$fpath" "foreign: pi is reported as left alone"
case "$res" in *"INSTALLED	$fpath"*) s=claimed ;; *) s=absent ;; esac
assert_eq "$s" "absent" "foreign: the untouched path is not offered as an undo"
assert_contains "$res" \
  "DECISION	offered and accepted — this run created 2 adapter symlink(s); see the undo below" \
  "foreign: the count is the two that were really linked"

# ===========================================================================
# 6. a DANGLING link is left alone too — validate's policy, not the installer's
# ===========================================================================
# `roost install` relinks a dangling adapter on purpose: it is ours and it is
# broken, so replacing it loses nothing. roost validate does not, and the
# difference is not cosmetic — BLOCKED_LINKS was collected before the question
# was asked, so a relink here would leave the report saying "left alone" about
# a path this run had just rewritten.
#
# This is the case that fails if the offer ever calls the installer without
# restricting it to the harnesses it actually offered.
box="$TMP/dangling"
mkdir -p "$box/home/.config/opencode/plugin"
ln -s "$box/gone/roost.js" "$box/home/.config/opencode/plugin/roost.js"
dpath="$(apath "$box" opencode)"
out="$(run_offer "$box" --install)"
res="$(result_of "$out")"
assert_eq "$(readlink "$dpath")" "$box/gone/roost.js" \
  "dangling: the broken link still points where it did — validate did not relink it"
assert_contains "$res" "BLOCKED	opencode	$dpath" "dangling: opencode is reported as left alone"
assert_contains "$res" \
  "DECISION	offered and accepted — this run created 2 adapter symlink(s); see the undo below" \
  "dangling: only the other two are counted"

# ===========================================================================
# 7. the writing is roost install's job, and a failure says so
# ===========================================================================
# The delegation itself, proved by the thing only the installer produces. On a
# successful run its output is kept back — the tester has just read validate's
# own list of the same paths — so the case that can see it is the one where a
# write fails, which is also the case where that output is the only explanation
# there is.
if [ "$(id -u)" -ne 0 ]; then
  box="$TMP/failed"
  mkdir -p "$box/home/.config/opencode"
  chmod 500 "$box/home/.config/opencode"
  out="$(run_offer "$box" --install)"
  res="$(result_of "$out")"
  chmod 700 "$box/home/.config/opencode"
  fpath="$(apath "$box" opencode)"
  assert_contains "$res" "BLOCKED	opencode	$fpath" "a failed write: opencode is reported as blocked"
  assert_contains "$res" \
    "DECISION	offered and accepted — this run created 2 adapter symlink(s); see the undo below" \
    "a failed write: the count is only what was really created"
  assert_contains "$out" "roost install — wiring these harnesses to" \
    "a failed write: the shared installer is what ran, and its output is shown"
  assert_contains "$out" "roost install exited 1." \
    "a failed write: the installer's exit status is named"
else
  assert_true 0 "a failed write: skipped (running as root, where chmod 500 does not deny)"
fi

# ===========================================================================
# 8. nothing to install -> no installer run at all
# ===========================================================================
box="$TMP/already"
mkdir -p "$box/home/.config/opencode/plugin" "$box/home/.pi/agent/extensions" \
  "$box/home/.copilot/extensions/roost"
ln -s "$(atarget opencode)" "$box/home/.config/opencode/plugin/roost.js"
ln -s "$(atarget pi)" "$box/home/.pi/agent/extensions/roost.ts"
ln -s "$(atarget copilot)" "$box/home/.copilot/extensions/roost/extension.mjs"
before="$(find "$box/home" | sort)"
out="$(run_offer "$box" --install)"
res="$(result_of "$out")"
assert_contains "$res" \
  "DECISION	nothing to install — every adapter for an installed harness was already linked to this checkout" \
  "all linked already: the decision line says there was nothing to do"
assert_eq "$(find "$box/home" | sort)" "$before" "all linked already: nothing under HOME changed"
case "$res" in *"INSTALLED	"*) s=some ;; *) s=none ;; esac
assert_eq "$s" "none" "all linked already: no undo line is offered for a link this run did not make"

# ===========================================================================
# 9. a link this run really did create, whose TARGET does not exist
# ===========================================================================
# The report is built from what the INSTALLER did, not from what the disk
# looks like afterwards, and this is the case that tells the two apart. With
# the adapter file missing from the checkout, `ln -s` still succeeds — a
# symlink to a path that is not there is a symlink — so the installer creates
# it, says so, and exits 0. Reading the state back afterwards answers a
# different question: the link points at nothing, so it is `dangling`.
#
# Deriving the report from that state filed a link this run had just created
# under BLOCKED_LINKS, which report_install renders to the tester as "left
# alone", and printed no undo line for it. A report that changed the machine
# it ran on and did not say so is the worse of the two directions, in
# report_install's own words.
box="$TMP/deadtarget"
mkdir -p "$box/home"
# Moved rather than deleted: $CO is one copy shared by every case in this
# file, and a later case linking a pi adapter that is not there would be a
# different test than the one it says it is.
mv "$CO/adapters/pi/roost.ts" "$TMP/pi-roost.ts.away"
out="$(run_offer "$box" --install)"
mv "$TMP/pi-roost.ts.away" "$CO/adapters/pi/roost.ts"
res="$(result_of "$out")"
dtpath="$(apath "$box" pi)"
assert_eq "$(readlink "$dtpath" 2>/dev/null)" "$(atarget pi)" \
  "dead target: the link really was created, pointing into this checkout"
assert_contains "$res" "INSTALLED	$dtpath" \
  "dead target: a link this run created is recorded for the undo"
case "$res" in *"BLOCKED	pi	"*) s=blocked ;; *) s=absent ;; esac
assert_eq "$s" "absent" \
  "dead target: a link this run created is not reported as left alone"
assert_contains "$res" \
  "DECISION	offered and accepted — this run created 3 adapter symlink(s); see the undo below" \
  "dead target: the count includes the link whose target is missing"

# ===========================================================================
# 10. a link that appeared from OUTSIDE this run is not claimed as its work
# ===========================================================================
# The other direction. validate's question sits there for up to 60 seconds,
# and a tester can link an adapter by hand in another terminal while it does.
# The installer sees the path already correct, writes nothing and records
# nothing — so validate must not count it, and must not print `rm <path>`
# under "This run created the following symlinks on this machine". Telling
# someone to delete a link they made themselves is not an undo.
#
# The stand-in for that other terminal is a wrapper around the installer:
# validate calls it by path, so replacing that path for one case reproduces
# the race exactly, with the real installer still doing the real work.
box="$TMP/raced"
mkdir -p "$box/home"
rcpath="$(apath "$box" pi)"
mv "$CO/scripts/roost-install" "$CO/scripts/roost-install.real"
cat > "$CO/scripts/roost-install" <<WRAP
#!/usr/bin/env bash
mkdir -p "\$(dirname "$rcpath")"
ln -s "$(atarget pi)" "$rcpath"
exec "$CO/scripts/roost-install.real" "\$@"
WRAP
chmod +x "$CO/scripts/roost-install"
out="$(run_offer "$box" --install)"
mv "$CO/scripts/roost-install.real" "$CO/scripts/roost-install"
res="$(result_of "$out")"
assert_eq "$(readlink "$rcpath" 2>/dev/null)" "$(atarget pi)" \
  "raced: the link the other terminal made is still there"
case "$res" in *"INSTALLED	$rcpath"*) s=claimed ;; *) s=absent ;; esac
assert_eq "$s" "absent" \
  "raced: a link this run did not make is never offered as an undo"
case "$res" in *"BLOCKED	pi	"*) s=blocked ;; *) s=absent ;; esac
assert_eq "$s" "absent" \
  "raced: a correctly linked path is not reported as something left alone"
assert_contains "$res" "ALREADY	pi	$rcpath" \
  "raced: pi is reported as already linked, by something other than this run"
assert_contains "$res" \
  "DECISION	offered and accepted — this run created 2 adapter symlink(s); see the undo below" \
  "raced: the count is only the two this run really created"

# ===========================================================================
# 11. the file itself
# ===========================================================================
bash -n "$REPO/scripts/roost-validate"; assert_true $? "scripts/roost-validate parses as bash"
# bash 3.2 is the floor (AGENTS.md / the spec's global constraints): no
# associative arrays, no ${var^^}, no printf '\uXXXX'.
n="$(grep -cE 'declare -A|\$\{[A-Za-z_]+\^\^|printf .*\\u[0-9a-fA-F]{4}' "$REPO/scripts/roost-validate" || true)"
assert_eq "${n:-0}" "0" "scripts/roost-validate uses no bash-4-only construct"
# The two flags this offer is driven by. `roost validate --help` exits 2 and
# prints to stderr, which is why both are captured here.
help="$(bash "$REPO/scripts/roost-validate" --help 2>&1 </dev/null)"
assert_contains "$help" "--install           link missing adapter symlinks without asking" \
  "--help still documents --install"
assert_contains "$help" "--no-install        never link anything; skip those harnesses instead" \
  "--help still documents --no-install"

rm -rf "$ALL_SHIM"

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
