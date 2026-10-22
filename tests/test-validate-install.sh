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
# The report's own section, built the way the real run builds it, so a case
# can assert on the undo lines the tester would paste. Printed BEFORE the
# result block: result_of keeps only what follows ===RESULT===, so nothing in
# the report can be mistaken for one of the values below.
report_install
printf '\n===REPORT===\n'
cat "$BODY"
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
printf '%s' "${REMOVED_LINKS:-}" | while IFS="$(printf '\t')" read -r h p u; do
  [ -n "$h" ] && printf 'REMOVED\t%s\t%s\t%s\n' "$h" "$p" "$u"
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

# make_versioned_shim VERSION-LINE -> a PATH dir like ALL_SHIM's, except that
# its opencode prints VERSION-LINE, so roost_adapter_key reads a version from
# it. A stub, never a link to a real binary: the plan forbids running a real
# opencode here, and 1.x and 2.x cannot share a data directory.
#
# `sleep` is added for these shims only. roost_opencode_version runs
# `opencode --version` under a `sleep 5` watchdog, and with no sleep on PATH
# the watchdog kills the probe at once — the version line can then be lost to
# that race, and the case would read 1.x whatever the stub printed. The other
# shims keep their exact inventory; their silent opencode has no version to lose.
make_versioned_shim() {
  local dir real
  dir="$(make_shim pi copilot)"
  real="$(command -v sleep 2>/dev/null)" && ln -s "$real" "$dir/sleep"
  printf '#!/bin/sh\necho "%s"\n' "$1" > "$dir/opencode"
  chmod +x "$dir/opencode"
  printf '%s' "$dir"
}

# --- one sandboxed offer ---------------------------------------------------
# stdin is /dev/null: with no terminal the offer must resolve to no on its own,
# and a case that inherited the runner's stdin would be answering a question it
# was never asked.
#
# SHIM, when set, replaces ALL_SHIM for one call — the opencode 2 cases below
# need an opencode that prints a version.
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
  PATH="${SHIM:-$ALL_SHIM}" \
    bash "$DRIVER" "${SLICE:-$HEAD}" --out "$box/report.md" "$@" </dev/null 2>&1
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
# 11. opencode 2 gets its own adapter path, and 1.x is the control
# ===========================================================================
# One binary, two adapters: opencode 2 loads a DIRECTORY at plugins/roost,
# linked to adapters/opencode/v2, and 1.x loads plugin/roost.js. The offer
# names whichever one the opencode on PATH gets (roost_adapter_key), and the
# record it reads back after the install is the one for that same path —
# looked up at the 1.x path, a 2.x link the installer really wrote would be
# reported as "could NOT link".
#
# The drive-path skip (h_prepare's H_SKIP for opencode 2) is past the slice
# this file sources; it is checked by hand.
V2_SHIM="$(make_versioned_shim "opencode v2.0.20")"
V1_SHIM="$(make_versioned_shim "1.18.30")"

box="$TMP/oc2"
out="$(SHIM="$V2_SHIM" run_offer "$box" --install)"
res="$(result_of "$out")"
v2path="$(apath "$box" opencode2)"
v1path="$(apath "$box" opencode)"
assert_contains "$out" "    opencode  $v2path" \
  "opencode 2: the offer names plugins/roost"
assert_contains "$out" "  -> $(atarget opencode2)" \
  "opencode 2: the offer names adapters/opencode/v2 as the target"
assert_eq "$(readlink "$v2path" 2>/dev/null)" "$(atarget opencode2)" \
  "opencode 2: plugins/roost is linked to this checkout's 2.x adapter"
assert_contains "$res" "INSTALLED	$v2path" \
  "opencode 2: the link the installer wrote is recorded for the undo"
case "$res" in *"BLOCKED	opencode	"*) s=blocked ;; *) s=absent ;; esac
assert_eq "$s" "absent" "opencode 2: the 2.x link is not reported as could-NOT-link"
case "$out" in *"$v1path"*) s=named ;; *) s=absent ;; esac
assert_eq "$s" "absent" "opencode 2: the 1.x path is never offered"
[ -e "$v1path" ] || [ -L "$v1path" ]; assert_eq "$?" "1" \
  "opencode 2: nothing is created at plugin/roost.js"

box="$TMP/oc1"
out="$(SHIM="$V1_SHIM" run_offer "$box" --install)"
res="$(result_of "$out")"
v2path="$(apath "$box" opencode2)"
v1path="$(apath "$box" opencode)"
assert_contains "$out" "    opencode  $v1path" \
  "opencode 1.x (control): the offer names plugin/roost.js"
assert_contains "$res" "INSTALLED	$v1path" \
  "opencode 1.x (control): plugin/roost.js is recorded for the undo"
case "$out" in *"$v2path"*) s=named ;; *) s=absent ;; esac
assert_eq "$s" "absent" "opencode 1.x (control): plugins/roost is never offered"
case "$res" in *"REMOVED	"*) s=removed ;; *) s=none ;; esac
assert_eq "$s" "none" "opencode 1.x (control): nothing is reported as removed"
case "$out" in *"removed "*|*"One thing is removed"*) s=named ;; *) s=absent ;; esac
assert_eq "$s" "absent" "opencode 1.x (control): no removal line is printed"

# --- opencode 2 with roost's own 1.x link still in place ------------------
# `roost install --only opencode` on 2.x removes that link (opencode 2 tries
# to load it and cannot). validate runs that install, so its offer must say a
# link will be removed, and its report must name the removal and carry the
# `ln -s` that puts it back — read from the installer's `removed` record.
box="$TMP/oc2old"
mkdir -p "$box/home/.config/opencode/plugin"
v1path="$(apath "$box" opencode)"
v2path="$(apath "$box" opencode2)"
ln -s "$(atarget opencode)" "$v1path"
out="$(SHIM="$V2_SHIM" run_offer "$box" --install)"
res="$(result_of "$out")"
rep="${out#*===REPORT===}"; rep="${rep%%===RESULT===*}"
undo="ln -s \"$(atarget opencode)\" \"\$HOME/.config/opencode/plugin/roost.js\""
assert_eq "$(readlink "$v2path" 2>/dev/null)" "$(atarget opencode2)" \
  "opencode 2, old 1.x link: plugins/roost is linked"
[ -e "$v1path" ] || [ -L "$v1path" ]; assert_eq "$?" "1" \
  "opencode 2, old 1.x link: the 1.x link is gone"
assert_contains "$out" "    remove    $v1path" \
  "opencode 2, old 1.x link: the offer says the 1.x link will be removed"
case "$out" in *"a symlink each, nothing else"*) s=claimed ;; *) s=absent ;; esac
assert_eq "$s" "absent" "opencode 2, old 1.x link: the offer does not say nothing else"
assert_contains "$out" "  removed $v1path" \
  "opencode 2, old 1.x link: the removal is printed as it happens"
assert_contains "$res" "REMOVED	opencode	$v1path	ln -s \"$(atarget opencode)\" \"$v1path\"" \
  "opencode 2, old 1.x link: the removal and its undo are read from the record"
assert_contains "$rep" "$undo" \
  "opencode 2, old 1.x link: the report's undo list has the ln -s"
assert_contains "$rep" "rm \"\$HOME/.config/opencode/plugins/roost\"" \
  "opencode 2, old 1.x link: the report's undo list still has the rm for plugins/roost"
assert_contains "$res" \
  "DECISION	offered and accepted — this run created 3 adapter symlink(s) and removed 1 opencode 1.x link(s); see the undo below" \
  "opencode 2, old 1.x link: the decision line counts the removal"

# --- opencode 2 with a DANGLING link at plugin/roost.js -------------------
# A dangling link says only that its target is gone, not whose target it was:
# the user's own plugin on a volume that is not mounted reads the same as a
# link to a roost checkout that was deleted. The installer removes it only
# when its text names a roost 1.x adapter (roost_adapter_names_1x), so the
# offer has to predict with that same rule. Asked with `ok|dangling` alone, it
# told the tester a link would be removed that the installer then refused.
box="$TMP/oc2theirs"
mkdir -p "$box/home/.config/opencode/plugin"
v1path="$(apath "$box" opencode)"
ln -s /nowhere/my-own-plugin.js "$v1path"
out="$(SHIM="$V2_SHIM" run_offer "$box" --install)"
res="$(result_of "$out")"
case "$out" in *"    remove    $v1path"*) s=offered ;; *) s=absent ;; esac
assert_eq "$s" "absent" \
  "opencode 2, the user's own dangling link: the offer does not say it will be removed"
assert_contains "$out" "a symlink each, nothing else" \
  "opencode 2, the user's own dangling link: the offer says nothing else is touched"
case "$res" in *"REMOVED	"*) s=removed ;; *) s=none ;; esac
assert_eq "$s" "none" \
  "opencode 2, the user's own dangling link: nothing is reported as removed"
assert_eq "$(readlink "$v1path" 2>/dev/null)" "/nowhere/my-own-plugin.js" \
  "opencode 2, the user's own dangling link: the link is still there afterwards"

# The control: roost's own link to a checkout that is gone. Its text ends in
# /adapters/opencode/roost.js, so it is offered as removed, and removed.
box="$TMP/oc2gone"
mkdir -p "$box/home/.config/opencode/plugin"
v1path="$(apath "$box" opencode)"
ln -s "$TMP/gone-checkout/adapters/opencode/roost.js" "$v1path"
out="$(SHIM="$V2_SHIM" run_offer "$box" --install)"
res="$(result_of "$out")"
assert_contains "$out" "    remove    $v1path" \
  "opencode 2, roost's own dangling link (control): the offer says it will be removed"
assert_contains "$res" "REMOVED	opencode	$v1path	" \
  "opencode 2, roost's own dangling link (control): the removal is recorded"
[ -e "$v1path" ] || [ -L "$v1path" ]; assert_eq "$?" "1" \
  "opencode 2, roost's own dangling link (control): the link is gone"

rm -rf "$V2_SHIM" "$V1_SHIM"

# ===========================================================================
# 11b. a link to ANOTHER copy of roost: predicted exactly as the installer acts
# ===========================================================================
# scripts/roost-install relinks such a link from a plain checkout and refuses
# it from a git worktree (its IN_WORKTREE rule), and the offer runs that
# installer right after it speaks, so the offer must say the same thing the
# installer will do. Both checkouts here are built by this test, never $REPO:
# the checkout running this suite is a worktree on the machine it is developed
# on and a plain clone on CI, and git is on the shim PATH so the question is
# really asked.
tgit() { GIT_CONFIG_GLOBAL=/dev/null git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=t -c user.email=t@t "$@"; }
GIT_SHIM="$(make_shim opencode pi copilot)"
real_git="$(command -v git 2>/dev/null)" && ln -s "$real_git" "$GIT_SHIM/git"
mk_slice() { # mk_slice CHECKOUT -> a roost-validate head for that checkout
  sed '/^# --- main /,$d' "$1/scripts/roost-validate" > "$1/scripts/roost-validate-head"
}
vplain="$TMP/v-plain"
cp -R "$CO" "$vplain"; rm -rf "$vplain/.git"; mk_slice "$vplain"
vrepo="$TMP/v-repo"; vwt="$TMP/v-repo-wt"
cp -R "$CO" "$vrepo"
( cd "$vrepo" && tgit init -q && tgit add -A && tgit commit -q -m one && tgit worktree add -q "$vwt" -b vwt ) >/dev/null 2>&1
mk_slice "$vwt"
# The setup checks itself: a worktree that was never made would leave every
# "blocked" assertion below passing for the wrong reason.
PATH="$GIT_SHIM" bash -c '. "$1/scripts/lib/roost-adapters.sh"; roost_checkout_is_worktree "$1"' _ "$vwt"
assert_eq "$?" "0" "other-checkout offer setup: the worktree reads as a worktree"
PATH="$GIT_SHIM" bash -c '. "$1/scripts/lib/roost-adapters.sh"; roost_checkout_is_worktree "$1"' _ "$vplain"
assert_eq "$?" "1" "other-checkout offer setup: the plain checkout does not"

oc2="$TMP/v-second-checkout"
mkdir -p "$oc2"; cp -R "$REPO/adapters" "$oc2/"
ptail="$(atarget pi)"; ptail="${ptail#"$(cd -P "$CO" && pwd)"}"
# The adapter table resolves physical paths (/private/tmp on a Mac), so the
# expectations below are spelled with the physical path of each checkout too.
vplain_p="$(cd -P "$vplain" && pwd)"; vwt_p="$(cd -P "$vwt" && pwd)"

# plain checkout: the link is one the run will make, and install makes it
box="$TMP/oc-plain"
mkdir -p "$box/home/.pi/agent/extensions"
ln -s "$oc2$ptail" "$box/home/.pi/agent/extensions/roost.ts"
ppath="$box/home/.pi/agent/extensions/roost.ts"
SHIM="$GIT_SHIM" SLICE="$vplain/scripts/roost-validate-head" out="$(run_offer "$box" --install)"
res="$(result_of "$out")"
# After the offer's own header and not in the blocked note: the path alone
# also appears under "left alone", so the "replaces" line is what tells them apart.
assert_contains "$out" "replaces the link to another copy of roost, $oc2$ptail" \
  "other-checkout, plain checkout: the offer lists the link as one it will make, and names what it replaces"
case "${out##*These roost adapters are not linked yet}" in *"    pi        $ppath"*) s=listed ;; *) s=missing ;; esac
assert_eq "$s" "listed" "other-checkout, plain checkout: the path is in the candidate list, after its header"
assert_contains "$out" "$oc2$ptail" "other-checkout, plain checkout: the offer names the copy it replaces"
case "$res" in *"BLOCKED	pi	"*) s=blocked ;; *) s=absent ;; esac
assert_eq "$s" "absent" "other-checkout, plain checkout: not filed as left alone"
assert_contains "$res" "INSTALLED	$ppath" "other-checkout, plain checkout: the run reports the link as its own work"
assert_eq "$(readlink "$ppath")" "$vplain_p$ptail" "other-checkout, plain checkout: the link now points at this checkout"
rep_body="${out##*===REPORT===}"; rep_body="${rep_body%%===RESULT===*}"
assert_contains "$rep_body" "ln -s \"$oc2$ptail\" \"\$HOME/.pi/agent/extensions/roost.ts\"" \
  "other-checkout, plain checkout: the report's undo (home path redacted to \$HOME) puts the other copy's link back"
# The report redacts the home path to $HOME, as the undo assertion above
# spells it, so the raw $ppath could never match and this could never fail.
case "$rep_body" in *'
rm "$HOME/.pi/agent/extensions/roost.ts"
'*) s=bare ;; *) s=none ;; esac
assert_eq "$s" "none" "other-checkout, plain checkout: no bare rm line for the relinked path"
assert_contains "$res" "relinked 1 that pointed at another copy of roost" \
  "other-checkout, plain checkout: the decision counts the relink apart from the creates"

# worktree: blocked, unchanged, and the installer is not asked to touch it
box="$TMP/oc-wt"
mkdir -p "$box/home/.pi/agent/extensions"
ln -s "$oc2$ptail" "$box/home/.pi/agent/extensions/roost.ts"
ppath="$box/home/.pi/agent/extensions/roost.ts"
SHIM="$GIT_SHIM" SLICE="$vwt/scripts/roost-validate-head" out="$(run_offer "$box" --install)"
res="$(result_of "$out")"
assert_contains "$res" "BLOCKED	pi	$ppath" "other-checkout, worktree: pi is reported as left alone"
assert_eq "$(readlink "$ppath")" "$oc2$ptail" "other-checkout, worktree: the link is exactly as it was"
case "$res" in *"INSTALLED	$ppath"*) s=claimed ;; *) s=absent ;; esac
assert_eq "$s" "absent" "other-checkout, worktree: not claimed as this run's work"

# the manual fix, from both: the same rm && ln -s line doctor prints
cat > "$TMP/fixdriver.sh" <<'FIXDRIVER'
#!/usr/bin/env bash
set -u
slice="$1"; shift
. "$slice" "$@"
trap - EXIT
h_adapter_fix pi
FIXDRIVER
for slice in "$vplain" "$vwt"; do
  here_p="$(cd -P "$slice" && pwd)"
  box="$TMP/oc-fix"; rm -rf "$box"
  mkdir -p "$box/home/.pi/agent/extensions"
  ppath="$box/home/.pi/agent/extensions/roost.ts"
  ln -s "$oc2$ptail" "$ppath"
  fix="$(HOME="$box/home" XDG_CONFIG_HOME="$box/home/.config" PI_CODING_AGENT_DIR="$box/home/.pi/agent" \
    CODEX_HOME="$box/home/.codex" COPILOT_HOME="$box/home/.copilot" PATH="$GIT_SHIM" \
    bash "$TMP/fixdriver.sh" "$slice/scripts/roost-validate-head" --out "$box/r.md" </dev/null 2>&1)"
  assert_contains "$fix" "rm \"$ppath\" && ln -s \"$here_p$ptail\" \"$ppath\"" \
    "other-checkout fix (${slice##*/}): the manual line is rm && ln -s to this checkout"
  assert_contains "$fix" "points at another copy of roost, $oc2$ptail" "other-checkout fix (${slice##*/}): it names the other copy"
  if [ "$slice" = "$vplain" ]; then
    assert_contains "$fix" "(not relinked by this run) — run: roost install, or: rm" "other-checkout fix (plain): says it was not relinked"
  else
    assert_contains "$fix" "(left alone: this is a git worktree, and roost does not relink from one) — run roost install from the primary checkout, or: rm" "other-checkout fix (worktree): says why it was left alone"
  fi
done

# ===========================================================================
# 12. the file itself
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
