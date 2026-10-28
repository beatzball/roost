#!/usr/bin/env bash
# tests/test-skill-links.sh — the roost skill link (#208): where each harness
# looks for it, the five states a link can be in, and what roost install,
# roost doctor and roost validate each do and say about it.
#
# EVERY case runs against a scratch HOME under one `mktemp -d`, with every
# harness home redirected into it and FAKE harness binaries on a shim PATH. The
# developer running this suite has live agent configuration in ~/.claude,
# ~/.codex, ~/.copilot, ~/.config/opencode and ~/.pi, and a skill link is a
# write into exactly those directories.
#
# CLAUDE_CONFIG_DIR is in the set because of this feature. Claude Code reads
# skills from $CLAUDE_CONFIG_DIR/skills (measured on 2.1.312 for #208), NOT
# from the directory $CLAUDE_SETTINGS sits in, so it is the first roost write
# that variable steers. A runner that exports it would otherwise have it
# inherited straight through the sandboxed HOME (AGENTS.md §8).
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

TMP="$(mktemp -d /tmp/amx.XXXX)"
trap 'rm -rf "$TMP"' EXIT

# --- the sandbox canary -----------------------------------------------------
# The shape tests/test-install.sh uses: every variable an install run can be
# steered by, exported at one directory that NOTHING here may write to. Each
# invocation below overrides all of them; one that forgets even one inherits
# the canary instead, and the check at the bottom of this file fails.
CANARY="$TMP/canary"
export ZDOTDIR="$CANARY/zdot"
export XDG_CONFIG_HOME="$CANARY/xdg-config"
export XDG_DATA_HOME="$CANARY/xdg-data"
export COPILOT_HOME="$CANARY/copilot"
export PI_CODING_AGENT_DIR="$CANARY/pi/agent"
export CODEX_HOME="$CANARY/codex"
export CLAUDE_SETTINGS="$CANARY/claude/settings.json"
export CLAUDE_CONFIG_DIR="$CANARY/claude-config"
canary_leaks() { find "$CANARY" -mindepth 1 2>/dev/null | sort; }

# boxenv BOX -- the assignments that pin every home under BOX, for `env`.
boxenv() {
  printf '%s\n' "HOME=$1/home" "ZDOTDIR=$1/home" \
    "XDG_CONFIG_HOME=$1/home/.config" "XDG_DATA_HOME=$1/home/.local/share" \
    "COPILOT_HOME=$1/home/.copilot" "PI_CODING_AGENT_DIR=$1/home/.pi/agent" \
    "CODEX_HOME=$1/home/.codex" "CLAUDE_SETTINGS=$1/home/.claude/settings.json" \
    "CLAUDE_CONFIG_DIR=$1/home/.claude"
}

# --- checkouts ---------------------------------------------------------------
# Every install case runs an installer from a checkout this file builds, never
# this one: the checkout running the suite is often a git worktree itself, and
# whether a link to another copy of roost is taken over depends on that.
export GIT_CONFIG_GLOBAL=/dev/null
tgit() { git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=t -c user.email=t@t "$@"; }
copy_checkout() { # copy_checkout DIR -- the parts of this checkout an install run reads
  mkdir -p "$1"
  cp -R "$HERE/scripts" "$HERE/bin" "$HERE/adapters" "$HERE/skills" "$HERE/tmux" "$HERE/VERSION" "$1/"
}
plain="$TMP/plain"; copy_checkout "$plain"
co2="$TMP/second"; copy_checkout "$co2"
repo="$TMP/wt-repo"; wt="$TMP/wt-repo-wt"
mkdir -p "$repo"
( cd "$repo" && tgit init -q && tgit commit -q --allow-empty -m one ) >/dev/null 2>&1
copy_checkout "$repo"
( cd "$repo" && tgit add -A && tgit commit -q -m two && tgit worktree add -q "$wt" -b wt ) >/dev/null 2>&1
[ -x "$wt/scripts/roost-install" ]; assert_true $? "setup: the worktree carries the installer"
[ -f "$plain/skills/roost/SKILL.md" ]; assert_true $? "setup: the plain checkout carries skills/roost"

# --- fake harnesses -----------------------------------------------------------
# A shim REPLACES PATH, so the real harnesses on this machine cannot be found.
# python3 or jq is on it so the claude and codex hook writes really happen in a
# full run; git so a worktree reads as one.
CORE_BINS="bash sh cat cp mv rm mkdir mktemp dirname readlink ln find grep sed date env printf true false chmod stat cmp sleep git python3 jq id hostname wc sort"
make_shim() { # make_shim NAME... -> prints a PATH dir
  local dir h real
  dir="$(mktemp -d /tmp/amx.XXXX)"
  for h in $CORE_BINS; do
    real="$(command -v "$h" 2>/dev/null)" && ln -s "$real" "$dir/$h" 2>/dev/null
  done
  for h in "$@"; do
    printf '#!/bin/sh\nexit 0\n' > "$dir/$h"; chmod +x "$dir/$h"
  done
  printf '%s' "$dir"
}
ALL="claude codex opencode copilot pi"
SHIM="$(make_shim $ALL)"

run_install_from() { # run_install_from CHECKOUT BOX [args...]
  local co="$1" box="$2"; shift 2
  mkdir -p "$box/home"
  env $(boxenv "$box") PATH="$SHIM" bash "$co/scripts/roost-install" "$@" </dev/null 2>&1
}

# The table, asked the way the code asks it. For a box, so a case can never
# restate where a link goes; the expected folders themselves are pinned once,
# in section 1, against what each harness was measured to read.
lib_in() { # lib_in BOX CHECKOUT FN ARGS...
  local box="$1" co="$2" fn="$3"; shift 3
  env $(boxenv "$box") PATH="$SHIM" bash -c '. "$1/scripts/lib/roost-adapters.sh"; f="$2"; shift 2; "$f" "$@"' _ "$co" "$fn" "$@"
}
spath() { lib_in "$1" "$plain" roost_skill_path "$2"; }

# ===========================================================================
# 1. Where each harness's link goes, and which variable moves it
# ===========================================================================
# Restated here ON PURPOSE, unlike every other path in this file: these are
# the folders each harness was MEASURED to read skills from (#208's report,
# one live listing per harness), so this is the one place a change to the
# table must be argued with rather than silently followed.
b="$TMP/where"
assert_eq "$(spath "$b" claude)"   "$b/home/.claude/skills/roost"           "claude's link is in \$CLAUDE_CONFIG_DIR/skills"
assert_eq "$(spath "$b" codex)"    "$b/home/.codex/skills/roost"            "codex's link is in \$CODEX_HOME/skills"
assert_eq "$(spath "$b" opencode)" "$b/home/.config/opencode/skills/roost"  "opencode's link is in \$XDG_CONFIG_HOME/opencode/skills"
assert_eq "$(spath "$b" copilot)"  "$b/home/.copilot/skills/roost"          "copilot's link is in \$COPILOT_HOME/skills"
assert_eq "$(spath "$b" pi)"       "$b/home/.pi/agent/skills/roost"         "pi's link is in \$PI_CODING_AGENT_DIR/skills"
assert_eq "$(lib_in "$b" "$plain" roost_skill_target)" "$(cd -P "$plain" && pwd)/skills/roost" "the link points at this checkout's skills/roost"

# opencode 1.x and 2.x read the same folder, so the version must not matter.
ocv="$(mktemp -d /tmp/amx.XXXX)"; printf '#!/bin/sh\necho "opencode v2.0.20"\n' > "$ocv/opencode"; chmod +x "$ocv/opencode"
assert_eq "$(env $(boxenv "$b") PATH="$ocv:$SHIM" bash -c '. "$1/scripts/lib/roost-adapters.sh"; roost_skill_path "$(roost_adapter_key opencode)"' _ "$plain")" \
  "$b/home/.config/opencode/skills/roost" "opencode 2 gets the same skills folder as 1.x"

# Each variable moves its own harness's folder.
assert_eq "$(env $(boxenv "$b") CLAUDE_CONFIG_DIR="$TMP/cc" bash -c '. "$1/scripts/lib/roost-adapters.sh"; roost_skill_path claude' _ "$plain")" \
  "$TMP/cc/skills/roost" "CLAUDE_CONFIG_DIR moves claude's link"
# The trap this feature exists to avoid: claude does NOT look beside its
# settings file, so moving $CLAUDE_SETTINGS alone must not move the link.
assert_eq "$(env $(boxenv "$b") CLAUDE_SETTINGS="$TMP/elsewhere/settings.json" bash -c '. "$1/scripts/lib/roost-adapters.sh"; roost_skill_path claude' _ "$plain")" \
  "$b/home/.claude/skills/roost" "CLAUDE_SETTINGS alone does not move claude's link"
assert_eq "$(env $(boxenv "$b") CLAUDE_CONFIG_DIR= bash -c '. "$1/scripts/lib/roost-adapters.sh"; roost_skill_path claude' _ "$plain")" \
  "$b/home/.claude/skills/roost" "an empty CLAUDE_CONFIG_DIR means ~/.claude"
assert_eq "$(env $(boxenv "$b") CODEX_HOME="$TMP/cx" bash -c '. "$1/scripts/lib/roost-adapters.sh"; roost_skill_path codex' _ "$plain")" \
  "$TMP/cx/skills/roost" "CODEX_HOME moves codex's link"
assert_eq "$(env $(boxenv "$b") COPILOT_HOME="$TMP/cp" bash -c '. "$1/scripts/lib/roost-adapters.sh"; roost_skill_path copilot' _ "$plain")" \
  "$TMP/cp/skills/roost" "COPILOT_HOME moves copilot's link"
assert_eq "$(env $(boxenv "$b") PI_CODING_AGENT_DIR="$TMP/pa" bash -c '. "$1/scripts/lib/roost-adapters.sh"; roost_skill_path pi' _ "$plain")" \
  "$TMP/pa/skills/roost" "PI_CODING_AGENT_DIR moves pi's link"
assert_eq "$(env $(boxenv "$b") XDG_CONFIG_HOME="$TMP/xc" bash -c '. "$1/scripts/lib/roost-adapters.sh"; roost_skill_path opencode' _ "$plain")" \
  "$TMP/xc/opencode/skills/roost" "XDG_CONFIG_HOME moves opencode's link"

# ===========================================================================
# 2. The five states, planted
# ===========================================================================
# plant BOX HARNESS KIND -- put one kind of thing at the harness's link path.
printf -- '---\nname: roost\ndescription: a stranger'"'"'s own skill\n---\nmine\n' > "$TMP/stranger-skill.md"
mkdir -p "$TMP/stranger/skills/roost"; cp "$TMP/stranger-skill.md" "$TMP/stranger/skills/roost/SKILL.md"
# A copy of roost whose skills/roost is gone: what a dangling link must name
# for roost to call it its own. The rule has to hold without the target, so
# the proof is the checkout the text names, not the directory it pointed at.
mkdir -p "$TMP/gone-co/scripts/lib"; cp "$HERE/scripts/lib/roost-adapters.sh" "$TMP/gone-co/scripts/lib/"
plant() {
  local p; p="$(spath "$1" "$2")"
  mkdir -p "$(dirname "$p")"
  case "$3" in
    ours)     ln -s "$plain/skills/roost" "$p" ;;
    dangling) ln -s "$TMP/gone-co/skills/roost" "$p" ;;
    # Two dangling links that are NOT provably roost's, so both must read
    # foreign and never be replaced: a user's broken link to some other
    # tool's skill, and a link whose text ends in /skills/roost but names a
    # place that is not there at all (a volume that is not mounted), so
    # nothing can show it was ever a roost checkout.
    dangling-bare) ln -s "$TMP/unrelated-tool/missing-skill" "$p" ;;
    dangling-away) ln -s "$TMP/unmounted/skills/roost" "$p" ;;
    other)    ln -s "$co2/skills/roost" "$p" ;;
    # A stranger's link whose text ALSO ends in /skills/roost. The tail alone
    # is too common a name to prove a link is roost's, so this must read as
    # foreign, not as another copy of roost.
    stranger) ln -s "$TMP/stranger/skills/roost" "$p" ;;
    realdir)  mkdir -p "$p"; cp "$TMP/stranger-skill.md" "$p/SKILL.md" ;;
  esac
}
for h in $ALL; do
  for kind in missing ours dangling dangling-bare dangling-away other stranger realdir; do
    b="$TMP/state-$h-$kind"; mkdir -p "$b/home"
    [ "$kind" = missing ] || plant "$b" "$h" "$kind"
    case "$kind" in
      missing) want=missing ;; ours) want=ok ;; dangling) want=dangling ;;
      other) want=other-checkout ;; stranger|realdir|dangling-bare|dangling-away) want=foreign ;;
    esac
    assert_eq "$(lib_in "$b" "$plain" roost_skill_state "$h")" "$want" "$h skill, $kind: reads $want"
  done
done

# sq VALUE -- VALUE as one single-quoted shell word, each ' written '\''.
# A second spelling of roost_shell_quote, through sed, so the two can disagree.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
# skill_undo PATH TARGET [OLD] -- the undo line install prints for a skill
# link it wrote: it acts only while PATH is still a symlink whose text is
# exactly TARGET, and says it left the path alone otherwise. Spelled out here
# rather than read back from the installer, so a change to it is argued with.
skill_undo() {
  local act="rm $(sq "$1")"
  [ -n "${3:-}" ] && act="rm $(sq "$1") && ln -s $(sq "$3") $(sq "$1")"
  printf 'if [ -L %s ] && [ "$(readlink %s)" = %s ]; then %s; else printf '"'"'%%s\\n'"'"' %s; fi' \
    "$(sq "$1")" "$(sq "$1")" "$(sq "$2")" "$act" "$(sq "left $1 alone: it is not the link roost made")"
}
# The text the installer writes is its checkout's PHYSICAL path
# (roost_skill_target, through `cd -P`), which on macOS is /private/tmp/...
# for a checkout under /tmp. The guard compares text, so it must be this one.
PT="$(cd -P "$plain" && pwd)/skills/roost"

# ===========================================================================
# 3. roost install, plain checkout: the plan, the links, the undo, the record
# ===========================================================================
b="$TMP/full"
out="$(run_install_from "$plain" "$b" --yes --records "$b/records")"; rc=$?
assert_eq "$rc" "0" "install: exits 0"
plan="${out%%Writing:*}"
for h in $ALL; do
  p="$(spath "$b" "$h")"
  [ -L "$p" ] && [ "$p" -ef "$plain/skills/roost" ]; assert_true $? "install: $h skill linked to this checkout"
  assert_contains "$plan" "$p" "install: $h skill is in the plan printed before the prompt"
  assert_contains "$out" "$(skill_undo "$p" "$PT")" "install: $h skill has a guarded undo line"
  assert_contains "$(cat "$b/records")" "$(printf 'wrote\t%s\t%s\t%s' "$h" "$p" "$(skill_undo "$p" "$PT")")" "install: --records says $h's skill was written"
done
# Re-run: nothing to do, nothing to undo.
out="$(run_install_from "$plain" "$b" --yes --records "$b/records2")"
case "$out" in *"To undo"*) s=undo ;; *) s=quiet ;; esac
assert_eq "$s" "quiet" "install, second run: nothing to undo"
assert_contains "$(cat "$b/records2")" "$(printf 'unchanged\tclaude\t%s' "$(spath "$b" claude)")" "install, second run: claude's skill is unchanged"

# Consent: the skill links follow the same single answer as everything else.
b="$TMP/dry"
run_install_from "$plain" "$b" --dry-run >/dev/null
assert_eq "$(find "$b/home" -name roost -path '*skills*' | wc -l | tr -d ' ')" "0" "--dry-run: no skill link"
b="$TMP/noyes"
out="$(run_install_from "$plain" "$b")"
assert_eq "$(find "$b/home" -name roost -path '*skills*' | wc -l | tr -d ' ')" "0" "no terminal and no --yes: no skill link"
assert_contains "$out" "$(spath "$b" codex)" "no terminal: the skill link was still shown in the plan"

# --symlinks-only is roost validate's call, and validate reports every link
# that call makes; it does not link skills, so it must not make one.
b="$TMP/symonly"
run_install_from "$plain" "$b" --symlinks-only --yes >/dev/null
assert_eq "$(find "$b/home" -name roost -path '*skills*' | wc -l | tr -d ' ')" "0" "--symlinks-only: no skill link"

# --only scopes the skill links too.
b="$TMP/only"
run_install_from "$plain" "$b" --only claude --yes >/dev/null
[ -L "$(spath "$b" claude)" ]; assert_true $? "--only claude: claude's skill is linked"
assert_eq "$(find "$b/home" -name roost -path '*skills*' | wc -l | tr -d ' ')" "1" "--only claude: no other harness's skill"

# A harness that is not installed gets no link.
b="$TMP/notinstalled"
mkdir -p "$b/home"
env $(boxenv "$b") PATH="$(make_shim pi)" bash "$plain/scripts/roost-install" --yes </dev/null >/dev/null 2>&1
assert_eq "$(find "$b/home" -name roost -path '*skills*' | sed "s#$b/home/##")" ".pi/agent/skills/roost" "only the installed harness gets a skill link"

# ===========================================================================
# 4. roost install against each planted state
# ===========================================================================
for h in $ALL; do
  # dangling, and provably roost's -> relinked, and the undo puts the old
  # text back
  b="$TMP/inst-$h-dangling"; mkdir -p "$b/home"; plant "$b" "$h" dangling
  out="$(run_install_from "$plain" "$b" --yes --only "$h")"
  p="$(spath "$b" "$h")"
  [ "$p" -ef "$plain/skills/roost" ]; assert_true $? "$h, dangling skill link: relinked to this checkout"
  assert_contains "$out" "$(skill_undo "$p" "$PT" "$TMP/gone-co/skills/roost")" \
    "$h, dangling skill link: the undo puts the old link text back"
  case "$out" in *"a second copy of roost"*) s=second ;; *) s=plain ;; esac
  assert_eq "$s" "plain" "$h, dangling skill link: not called a second copy of roost"

  # dangling, and NOT provably roost's -> refused, the link text unchanged
  for kind in dangling-bare dangling-away; do
    b="$TMP/inst-$h-$kind"; mkdir -p "$b/home"; plant "$b" "$h" "$kind"
    p="$(spath "$b" "$h")"; was="$(readlink "$p")"
    out="$(run_install_from "$plain" "$b" --yes --only "$h")"
    assert_eq "$(readlink "$p")" "$was" "$h, $kind skill link: the link is unchanged"
    assert_contains "$out" "Will NOT touch" "$h, $kind skill link: the plan says it is left alone"
    case "$out" in *"relinked $p"*) s=relinked ;; *) s=kept ;; esac
    assert_eq "$s" "kept" "$h, $kind skill link: never relinked"
  done

  # a stranger's link -> refused, untouched, named
  b="$TMP/inst-$h-stranger"; mkdir -p "$b/home"; plant "$b" "$h" stranger
  sum="$(cksum < "$TMP/stranger/skills/roost/SKILL.md")"
  out="$(run_install_from "$plain" "$b" --yes --only "$h")"
  p="$(spath "$b" "$h")"
  assert_eq "$(readlink "$p")" "$TMP/stranger/skills/roost" "$h, stranger's skill link: the link is unchanged"
  assert_eq "$(cksum < "$TMP/stranger/skills/roost/SKILL.md")" "$sum" "$h, stranger's skill link: its skill is byte-identical"
  assert_contains "$out" "Will NOT touch" "$h, stranger's skill link: the plan says it is left alone"
  assert_contains "$out" "If you are sure you want roost's skill" "$h, stranger's skill link: the manual note names the skill, not an adapter"

  # a real directory -> refused, untouched, no rm offered
  b="$TMP/inst-$h-realdir"; mkdir -p "$b/home"; plant "$b" "$h" realdir
  p="$(spath "$b" "$h")"
  out="$(run_install_from "$plain" "$b" --yes --only "$h")"
  [ -d "$p" ] && [ ! -L "$p" ]; assert_true $? "$h, real skill directory: still a real directory"
  assert_eq "$(cksum < "$p/SKILL.md")" "$(cksum < "$TMP/stranger-skill.md")" "$h, real skill directory: its SKILL.md is byte-identical"
  # Either quoting, so the check cannot pass just because the format moved.
  case "$out" in *"rm \"$p\""*|*"rm $(sq "$p")"*) s=rm ;; *) s=none ;; esac
  assert_eq "$s" "none" "$h, real skill directory: no rm is printed for it"
done

# Another copy of roost's link: taken over from a plain checkout, with the
# old link named and put back by the undo; left alone from a worktree.
b="$TMP/inst-other-plain"; mkdir -p "$b/home"; plant "$b" claude other
p="$(spath "$b" claude)"
out="$(run_install_from "$plain" "$b" --yes --only claude)"
[ "$p" -ef "$plain/skills/roost" ]; assert_true $? "plain checkout, other copy's skill link: relinked"
assert_contains "$out" "was $co2/skills/roost" "plain checkout, other copy's skill link: names the old link"
assert_contains "$out" "rm $(sq "$p") && ln -s $(sq "$co2/skills/roost") $(sq "$p")" "plain checkout, other copy's skill link: undo puts it back"

b="$TMP/inst-other-wt"; mkdir -p "$b/home"; plant "$b" claude other
p="$(spath "$b" claude)"
out="$(run_install_from "$wt" "$b" --yes --only claude)"
assert_eq "$(readlink "$p")" "$co2/skills/roost" "worktree, other copy's skill link: left alone"
assert_contains "$out" "this is a git worktree" "worktree, other copy's skill link: says why"
# The control: the same worktree installer DOES link a missing skill, so the
# refusal above is about the other copy's link and not about worktrees.
b="$TMP/inst-missing-wt"; mkdir -p "$b/home"
run_install_from "$wt" "$b" --yes --only claude >/dev/null
[ "$(spath "$b" claude)" -ef "$wt/skills/roost" ]; assert_true $? "worktree, missing skill link: linked (the control)"

# The same rule at apply time. The plan sees roost's own dangling skill link
# for claude; then, before claude's row runs, it is swapped. The swap rides on
# `ln`: pi's row runs first (the installer's harness order), and `ln` comes
# from the shim PATH. The shim's `ln` is a SYMLINK to the real binary, so it
# is removed first and the wrapper written to a fresh file: `>` would follow
# the link and overwrite the real `ln`.
#   foreign  a dangling link that is not provably roost's: the re-check must
#            read it as foreign, as the plan would have
#   roost2   ANOTHER dangling roost link: still roost's, but not the link the
#            plan showed, so the undo's old text would be a lie
#   unproven the SAME link text, but the checkout it names no longer carries
#            scripts/lib/roost-adapters.sh: only the ownership rule, asked
#            again, can see that (the old-text check passes)
mkdir -p "$TMP/gone-co2/scripts/lib"; cp "$HERE/scripts/lib/roost-adapters.sh" "$TMP/gone-co2/scripts/lib/"
real_ln="$(command -v ln)"
for swap in foreign roost2 unproven; do
  b="$TMP/swap-$swap"; mkdir -p "$b/home"
  plant "$b" claude dangling; pp="$(spath "$b" pi)"; cp_="$(spath "$b" claude)"
  act=""
  case "$swap" in
    foreign) to="$TMP/unmounted/skills/roost" ;;
    roost2)  to="$TMP/gone-co2/skills/roost" ;;
    # Its own checkout, so taking the proof away cannot touch the others.
    unproven)
      mkdir -p "$TMP/gone-co3/scripts/lib"; cp "$HERE/scripts/lib/roost-adapters.sh" "$TMP/gone-co3/scripts/lib/"
      "$(command -v rm)" -f "$cp_"; ln -s "$TMP/gone-co3/skills/roost" "$cp_"
      to="$TMP/gone-co3/skills/roost"
      act="\"$(command -v rm)\" -f \"$TMP/gone-co3/scripts/lib/roost-adapters.sh\"" ;;
  esac
  [ -n "$act" ] || act="\"$(command -v rm)\" -f \"$cp_\" && \"$real_ln\" -s \"$to\" \"$cp_\""
  SWAP="$(make_shim $ALL)"
  rm -f "$SWAP/ln"
  if [ ! -e "$SWAP/ln" ] && [ ! -L "$SWAP/ln" ]; then
    cat > "$SWAP/ln" <<EOF
#!/bin/sh
case "\$*" in
  *"$pp"*) $act ;;
esac
exec "$real_ln" "\$@"
EOF
    chmod +x "$SWAP/ln"
  fi
  out="$(env $(boxenv "$b") PATH="$SWAP" bash "$plain/scripts/roost-install" --yes --only pi,claude --records "$b/recs" </dev/null 2>&1)"
  assert_contains "$out" "relink $cp_" "swapped for a $swap dangling link during the run: the plan saw roost's link"
  assert_eq "$(readlink "$cp_")" "$to" "swapped for a $swap dangling link during the run: the swapped-in link is still there"
  assert_contains "$(cat "$b/recs")" "$(printf 'refused\tclaude\t%s' "$cp_")" "swapped for a $swap dangling link during the run: --records says it was refused"
  rm -rf "$SWAP"
done

# The printed undo removes only what the run made.
b="$TMP/undo"; mkdir -p "$b/home"; plant "$b" pi stranger
out="$(run_install_from "$plain" "$b" --yes --only claude,pi)"
undo="$(printf '%s\n' "$out" | sed -n '/^To undo/,/^$/p' | grep '^  if ')"
sh -c "$(printf '%s\n' "$undo" | sed 's/^  //')"
[ ! -e "$(spath "$b" claude)" ] && [ ! -L "$(spath "$b" claude)" ]; assert_true $? "undo: claude's skill link is gone"
assert_eq "$(readlink "$(spath "$b" pi)")" "$TMP/stranger/skills/roost" "undo: the stranger's link is still there"
[ -f "$plain/skills/roost/SKILL.md" ]; assert_true $? "undo: the checkout's skill is untouched"

# The undo is run later, by hand, and the path may hold something else by
# then. Each kind below is put where roost's link was AFTER the install, and
# the printed undo must leave it exactly as it is and say so.
undo_for() { # undo_for BOX -- claude's printed undo line, the leading spaces cut
  printf '%s\n' "$1" | sed -n '/^To undo/,/^$/p' | grep -F "$(spath "$2" claude)" | sed 's/^  //'
}
for kind in file dir foreign dangling-foreign; do
  b="$TMP/undo-$kind"; mkdir -p "$b/home"
  out="$(run_install_from "$plain" "$b" --yes --only claude)"
  p="$(spath "$b" claude)"; line="$(undo_for "$out" "$b")"
  rm -f "$p"
  case "$kind" in
    file)             printf 'mine\n' > "$p" ;;
    dir)              mkdir -p "$p"; cp "$TMP/stranger-skill.md" "$p/SKILL.md" ;;
    foreign)          ln -s "$TMP/stranger/skills/roost" "$p" ;;
    dangling-foreign) ln -s "$TMP/unmounted/skills/roost" "$p" ;;
  esac
  said="$(sh -c "$line" 2>&1)"
  case "$kind" in
    file)             [ -f "$p" ] && [ ! -L "$p" ] && [ "$(cat "$p")" = mine ] ;;
    dir)              [ -d "$p" ] && [ ! -L "$p" ] && cmp -s "$p/SKILL.md" "$TMP/stranger-skill.md" ;;
    foreign)          [ "$(readlink "$p")" = "$TMP/stranger/skills/roost" ] ;;
    dangling-foreign) [ "$(readlink "$p")" = "$TMP/unmounted/skills/roost" ] ;;
  esac
  assert_true $? "undo, a $kind at the path by then: left exactly as it is"
  assert_contains "$said" "left $p alone" "undo, a $kind at the path by then: says it left it alone"
done
# The control: the same line, with roost's link still there, removes it.
b="$TMP/undo-control"; mkdir -p "$b/home"
out="$(run_install_from "$plain" "$b" --yes --only claude)"
p="$(spath "$b" claude)"; sh -c "$(undo_for "$out" "$b")" >/dev/null 2>&1
[ ! -e "$p" ] && [ ! -L "$p" ]; assert_true $? "undo, roost's link still there: removed (the control)"
# And a relink of roost's own dangling link: the undo puts the old text back.
b="$TMP/undo-dangling"; mkdir -p "$b/home"; plant "$b" claude dangling
out="$(run_install_from "$plain" "$b" --yes --only claude)"
p="$(spath "$b" claude)"; sh -c "$(undo_for "$out" "$b")" >/dev/null 2>&1
assert_eq "$(readlink "$p")" "$TMP/gone-co/skills/roost" "undo, relinked dangling link: the old link text is back"

# Literal characters in a path. Every printed undo line is shell source the
# person runs later, so each value in it must reach that shell as the exact
# text install used. Inside double quotes `$name`, `$(cmd)` and backticks are
# expanded and `"` ends the word: a config folder named `config$slot` made the
# guard AND the `rm` act on `config-other`, a link install never made (#208,
# round 2). The first three suffixes below each expand to -other under that
# quoting, so a sibling home holding a copy of every link and file the run
# wrote, under the expanded name, is exactly what the old lines removed. The
# last expands to nothing; it holds the characters that end or escape a
# double-quoted word, and a space. Run under sh and under dash, the shell CI's
# /bin/sh is, because the person may paste the lines into either.
lit_shells=sh; command -v dash >/dev/null 2>&1 && lit_shells="sh dash"
# fingerprint DIR -- every link (with its text) and file (with its bytes'
# checksum) under DIR, one per line, so "left exactly as it was" is one compare.
fingerprint() {
  ( cd "$1" 2>/dev/null && find . \( -type l -o -type f \) | sort | while IFS= read -r e; do
      if [ -L "$e" ]; then printf '%s -> %s\n' "$e" "$(readlink "$e")"
      else printf '%s = %s\n' "$e" "$(cksum < "$e")"; fi
    done )
}
i=0
while IFS= read -r sfx; do
  for shl in $lit_shells; do
    i=$((i + 1)); base="$TMP/lit$i"; mkdir -p "$base"
    co="$base/co$sfx"; copy_checkout "$co"
    home="$base/home$sfx"; mkdir -p "$home"
    pbase="$(cd -P "$base" && pwd)"
    # Spelled out rather than through boxenv: its output is word-split, and
    # one of these homes has a space in it.
    out="$(env HOME="$home" ZDOTDIR="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
      COPILOT_HOME="$home/.copilot" PI_CODING_AGENT_DIR="$home/.pi/agent" CODEX_HOME="$home/.codex" \
      CLAUDE_SETTINGS="$home/.claude/settings.json" CLAUDE_CONFIG_DIR="$home/.claude" \
      PATH="$SHIM" bash "$co/scripts/roost-install" --yes --only claude,pi </dev/null 2>&1)"
    what="literal path ($shl, suffix $sfx)"
    undo="$(printf '%s\n' "$out" | sed -n '/^To undo/,/^$/p' | sed -n 's/^  //p')"
    p="$home/.claude/skills/roost"
    assert_eq "$(readlink "$p")" "$pbase/co$sfx/skills/roost" "$what: install linked claude's skill at the literal path"
    # The sibling: every link and file the run wrote, under the name the
    # expanded line would give it. A link's text is renamed the same way, so
    # the old guard's readlink compare would have matched it too.
    sib="$base/home-other"
    ( cd "$home" && find . \( -type l -o -type f \) ) | while IFS= read -r e; do
      mkdir -p "$sib/$(dirname "$e")"
      if [ -L "$home/$e" ]; then
        t="$(readlink "$home/$e")"
        case "$t" in "$pbase/co$sfx"/*) t="$pbase/co-other${t#"$pbase/co$sfx"}" ;; "$base/co$sfx"/*) t="$base/co-other${t#"$base/co$sfx"}" ;; esac
        ln -s "$t" "$sib/$e"
      else
        cp "$home/$e" "$sib/$e"
      fi
    done
    before="$(fingerprint "$sib")"
    said="$(cd "$base" && env slot=-other "$shl" -c "$undo" 2>&1)"; rc=$?
    assert_eq "$rc" "0" "$what: the undo runs cleanly"
    assert_eq "$(fingerprint "$sib")" "$before" "$what: the sibling the expanded line would name is untouched"
    case "$before" in *"skills/roost -> "*) s=yes ;; *) s=no ;; esac
    assert_eq "$s" "yes" "$what: the sibling holds a skill link (the probe is real)"
    assert_eq "$(fingerprint "$home")" "" "$what: the undo removed everything the run wrote (the control)"
    [ -f "$co/skills/roost/SKILL.md" ]; assert_true $? "$what: the checkout's skill is untouched"
    # The else branch prints the path; it must print the literal one.
    printf 'mine\n' > "$p"
    # Found by its folder, not by $p: a `'` in $p is written `'\''` in the line.
    line="$(printf '%s\n' "$undo" | grep '^if ' | grep -F '/.claude/skills/roost')"
    said="$(cd "$base" && env slot=-other "$shl" -c "$line" 2>&1)"
    assert_eq "$said" "left $p alone: it is not the link roost made" "$what: the message names the literal path"
    assert_eq "$(cat "$p")" "mine" "$what: a file put there by then is left alone"
  done
done <<'EOF'
$slot
$(echo -other)
`echo -other`
-"q'\b sp
EOF

# The summary names whole labels. A claude whose skill is linked but whose
# hooks are not yet written must not read "Already correct: claude".
b="$TMP/label"; mkdir -p "$b/home"; plant "$b" claude ours
out="$(run_install_from "$plain" "$b" --dry-run --only claude)"
line="$(printf '%s\n' "$out" | grep '^Already correct:')"
assert_eq "$line" "Already correct: claude skill" "summary, skill linked and hooks missing: names the skill as one label"
case "$out" in *"merge  "*) s=planned ;; *) s=absent ;; esac
assert_eq "$s" "planned" "summary, skill linked and hooks missing: the hooks are still planned (the control)"

# ===========================================================================
# 5. roost doctor reports each state
# ===========================================================================
DSHIM="$(mktemp -d /tmp/amx.XXXX)"
for h in $ALL; do printf '#!/bin/sh\nexit 0\n' > "$DSHIM/$h"; chmod +x "$DSHIM/$h"; done
printf '#!/bin/sh\necho "1.18.30"\n' > "$DSHIM/opencode"
run_doctor_in() { env $(boxenv "$1") PATH="$DSHIM:$PATH" COLORTERM=truecolor bash "$plain/scripts/roost-doctor" 2>&1; }
for kind in missing ours dangling dangling-away other stranger realdir; do
  b="$TMP/doc-$kind"; mkdir -p "$b/home"
  [ "$kind" = missing ] || plant "$b" codex "$kind"
  p="$(spath "$b" codex)"
  out="$(run_doctor_in "$b")"
  line="$(printf '%s\n' "$out" | grep -F "codex" | grep -F "skill" | head -1)"
  case "$kind" in
    ours)     assert_prefix "$line" "  ✓ codex: roost skill linked" "doctor, ours: ✓ line" ;;
    missing)  assert_contains "$line" "! codex: roost skill not linked at $p — run: roost install" "doctor, missing: names the path and the fix" ;;
    dangling) assert_contains "$line" "dangling" "doctor, dangling: says dangling" ;;
    other)    assert_contains "$line" "another copy of roost, $co2/skills/roost" "doctor, other copy: names it" ;;
    stranger) assert_contains "$line" "is not this install" "doctor, stranger's link: not ours" ;;
    dangling-away) assert_contains "$line" "is not this install — look at it first" "doctor, a dangling link not provably roost's: not ours, look first" ;;
    realdir)  assert_contains "$line" "not a symlink" "doctor, real directory: not a symlink, no rm" ;;
  esac
  case "$line" in "  ✗"*) s=bad ;; *) s=fine ;; esac
  assert_eq "$s" "fine" "doctor, $kind: a skill line never fails the run"
done
# A harness that is not installed is not reported on.
b="$TMP/doc-none"; mkdir -p "$b/home"
out="$(env $(boxenv "$b") PATH="$(make_shim):/usr/bin:/bin" COLORTERM=truecolor bash "$plain/scripts/roost-doctor" 2>&1)"
case "$out" in *"roost skill"*) s=mentioned ;; *) s=silent ;; esac
assert_eq "$s" "silent" "doctor: no harness installed, no skill line"

# ===========================================================================
# 6. roost validate predicts what install will do
# ===========================================================================
HEAD="$plain/scripts/roost-validate-head"
sed '/^# --- main /,$d' "$plain/scripts/roost-validate" > "$HEAD"
grep -q '^skill_link_rows() {' "$HEAD"; assert_true $? "validate: the slice defines skill_link_rows"
# --out into the box: loading the slice creates its report file at once (it
# fails early on an unwritable one), and left to its default that file lands
# in whatever directory the suite was started from.
rows_in() { # rows_in BOX CHECKOUT
  env $(boxenv "$1") PATH="$SHIM" bash -c 'co="$1"; out="$2"; shift 2; . "$co/scripts/roost-validate-head" --out "$out" >/dev/null 2>&1; trap - EXIT; skill_link_rows' _ "$2" "$1/report.md" 2>&1
}
for kind in missing ours dangling dangling-bare dangling-away other stranger; do
  b="$TMP/val-$kind"; mkdir -p "$b/home"
  [ "$kind" = missing ] || plant "$b" pi "$kind"
  row="$(rows_in "$b" "$plain" | grep "^pi|")"
  case "$kind" in
    missing)  want="pi|$(spath "$b" pi)|missing|links it" ;;
    ours)     want="pi|$(spath "$b" pi)|ok|nothing — already linked" ;;
    dangling) want="pi|$(spath "$b" pi)|dangling|relinks it" ;;
    other)    want="pi|$(spath "$b" pi)|other-checkout|relinks it" ;;
    stranger|dangling-bare|dangling-away) want="pi|$(spath "$b" pi)|foreign|leaves it alone" ;;
  esac
  assert_eq "$row" "$want" "validate, $kind: predicts what install does"
done
cp -R "$plain/scripts/roost-validate-head" "$wt/scripts/"
b="$TMP/val-wt"; mkdir -p "$b/home"; plant "$b" pi other
assert_eq "$(rows_in "$b" "$wt" | grep "^pi|")" "pi|$(spath "$b" pi)|other-checkout|leaves it alone (this checkout is a git worktree)" \
  "validate, other copy, from a worktree: predicts the refusal"

# ===========================================================================
# 7. Hygiene, and nothing escaped the sandbox
# ===========================================================================
n="$(grep -cE 'declare -A|\$\{[A-Za-z_]+\^\^' "$HERE/scripts/lib/roost-adapters.sh" || true)"
assert_eq "${n:-0}" "0" "roost-adapters.sh uses no bash-4-only construct"

mkdir -p "$CANARY"; : > "$CANARY/detector-check"
assert_contains "$(canary_leaks)" "detector-check" "the sandbox canary reports a file when there is one"
rm -f "$CANARY/detector-check"
assert_eq "$(canary_leaks)" "" "nothing in this file wrote outside its sandbox"

rm -rf "$SHIM" "$DSHIM" "$ocv"
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
