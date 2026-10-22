# roost-adapters.sh — the adapter path table: where each harness keeps its
# configuration, and where roost's symlink-shaped adapters go and must point.
#
# Shared by scripts/roost-validate (report + optional install offer),
# scripts/roost-install (the installer) and scripts/roost-doctor (the report).
# One table, because a tester's report, a doctor report and the installer's
# plan must never disagree about which file any of them means.
#
# opencode has two keys: `opencode` for 1.x (a file symlink at
# plugin/roost.js) and `opencode2` for 2.x (a DIRECTORY symlink at
# plugins/roost). roost_adapter_key, at the bottom, says which one the
# opencode on PATH gets (#150).

# roost_adapter_key needs roost_opencode_v2. Sourced by path relative to THIS
# file rather than from an inherited $ROOST_HOME, for the reason
# _roost_adapter_root below spells out at length: bin/roost exports ROOST_HOME
# into every pane of the session it starts, so a caller running inside a roost
# session would otherwise read the version check out of a DIFFERENT checkout.
# Guarded the way scripts/lib/roost-json.sh guards its own sibling:
# scripts/roost-doctor sources both files, and re-sourcing is wasted work
# rather than a bug.
if ! declare -f roost_opencode_v2 >/dev/null 2>&1; then
  . "$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/roost-opencode.sh"
fi

# roost_adapter_home HARNESS — the directory that harness actually keeps its
# configuration and credentials in. Per harness, and never assumed to be the
# XDG one: AGENTS.md §8 exists because copilot ignores XDG entirely, and pi and
# codex each have their own override too.
roost_adapter_home() {
  case "$1" in
    # opencode 2 keeps the same configuration directory as 1.x; only where
    # the adapter goes inside it changed.
    opencode|opencode2) printf '%s/opencode' "${XDG_CONFIG_HOME:-$HOME/.config}" ;;
    pi)       printf '%s' "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}" ;;
    copilot)  printf '%s' "${COPILOT_HOME:-$HOME/.copilot}" ;;
    codex)    printf '%s' "${CODEX_HOME:-$HOME/.codex}" ;;
    # Derived from the settings FILE rather than stated independently, so the
    # two can never disagree when $CLAUDE_SETTINGS moves the file somewhere
    # this directory does not contain. claude is the only harness whose
    # override names a file instead of a directory.
    claude)   local cs; cs="$(roost_adapter_settings claude)"; printf '%s' "${cs%/*}" ;;
  esac
}

# roost_adapter_settings HARNESS — the JSON file roost has to edit for the
# harnesses that are configured by JSON rather than by a symlink. Added
# because scripts/roost-install had restated claude's path inline and
# scripts/roost-doctor kept its own copy of the same expression, the
# $CLAUDE_SETTINGS override and all — two definitions of one path, and roost install WRITES to that
# path, which is where a divergence stops being cosmetic. One definition,
# here, for the same reason roost_adapter_path exists for the symlink three.
#
# $CLAUDE_SETTINGS is honoured because roost-doctor honoured it first; a
# report and an installer that disagreed about which file they mean is the
# exact failure this file's header exists to prevent. Both callers are on this
# function FOR CLAUDE — scripts/roost-doctor sources this file and asks it for
# the path it reports on — which is the one that matters most, because it is
# the path `roost install` writes to under an override the user chose.
#
# The rest of the duplication is still here, and this comment used to say it
# was gone. roost-doctor spells copilot's settings.json and codex's hooks.json
# itself, and builds the three adapter paths and their targets from its own
# expressions rather than from roost_adapter_path / roost_adapter_target.
# Pre-existing, and none of those copies honour an override this file does not
# — but "no copy is left to drift" is not true of them, and the next person
# must not read it as an invariant they can lean on.
#
# Named by file and not by line number, because the line number this comment
# used to carry is exactly what went stale first.
#
# Prints nothing for a harness with no JSON config of its own (the symlink
# three), the same way roost_adapter_path prints nothing for codex.
roost_adapter_settings() {
  case "$1" in
    claude)  printf '%s' "${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}" ;;
    copilot) printf '%s/settings.json' "$(roost_adapter_home copilot)" ;;
    codex)   printf '%s/hooks.json' "$(roost_adapter_home codex)" ;;
  esac
}

# _roost_adapter_root — the checkout root, for roost_adapter_target's install
# targets. A lib cannot depend on a caller's variable name (roost-validate
# calls its own copy $HERE; bin/roost calls its own $ROOST_HOME) OR on an
# inherited environment variable of any name: `bin/roost` exports ROOST_HOME
# into every pane of the session it starts (`t set-environment -g ROOST_HOME
# ...`), so a process running inside a roost session — including roost
# validate run by hand from a SECOND checkout, inside a server the FIRST
# checkout started — would otherwise read the wrong checkout's root. Measured
# consequence: with that branch in place, `roost_adapter_state opencode` for
# one unchanged on-disk symlink returned `foreign` outside a roost pane and
# `ok` inside one, and on the write path `offer_adapter_install` would have
# created a symlink pointing at the OTHER checkout while the report claimed it
# linked this one. So this always resolves fresh from this file's own
# location — following symlinks, then two directories up from
# scripts/lib/roost-adapters.sh to the checkout root — the same way bin/roost
# resolves its own, and never reads $ROOST_HOME.
_roost_adapter_root() {
  local source dir root
  source="${BASH_SOURCE[0]}"
  while [ -L "$source" ]; do
    dir="$(cd -P "$(dirname "$source")" && pwd)"
    source="$(readlink "$source")"
    [[ "$source" != /* ]] && source="$dir/$source"
  done
  root="$(cd -P "$(dirname "$source")/../.." && pwd)"
  # Strip a trailing slash so a pathologically-resolved root can never turn
  # the caller's "$root/adapters/..." into "$root//adapters/...".
  printf '%s' "${root%/}"
}

# roost_adapter_path / roost_adapter_target HARNESS — the symlink roost wants,
# and what it must point at. One pair, used by the state check, the install
# offer and the skip text, so those three can never disagree about which file
# they mean.
roost_adapter_path() {
  local home; home="$(roost_adapter_home "$1")"
  case "$1" in
    opencode) printf '%s/plugin/roost.js' "$home" ;;
    # A directory, not a file: 2.x loads a plugin from a folder under
    # plugins/ (plural), and the folder roost links is adapters/opencode/v2.
    opencode2) printf '%s/plugins/roost' "$home" ;;
    pi)       printf '%s/extensions/roost.ts' "$home" ;;
    copilot)  printf '%s/extensions/roost/extension.mjs' "$home" ;;
  esac
}
roost_adapter_target() {
  local here; here="$(_roost_adapter_root)"
  case "$1" in
    opencode) printf '%s/adapters/opencode/roost.js' "$here" ;;
    opencode2) printf '%s/adapters/opencode/v2' "$here" ;;
    pi)       printf '%s/adapters/pi/roost.ts' "$here" ;;
    copilot)  printf '%s/adapters/copilot/extension.mjs' "$here" ;;
  esac
}

# roost_adapter_tail HARNESS -> the path tail every roost checkout's adapter
# for that harness ends in. The one list roost_adapter_target prints from,
# written once more here so a link's TEXT can be matched without resolving
# it (a target under a moved home still names the adapter).
roost_adapter_tail() {
  case "$1" in
    opencode)  printf '/adapters/opencode/roost.js' ;;
    opencode2) printf '/adapters/opencode/v2' ;;
    pi)        printf '/adapters/pi/roost.ts' ;;
    copilot)   printf '/adapters/copilot/extension.mjs' ;;
  esac
}

# roost_adapter_link_names HARNESS PATH — true when the symlink at PATH has
# text ending in HARNESS's adapter tail. A trailing slash is stripped first: a
# directory link may carry one.
roost_adapter_link_names() {
  local text tail; text="$(readlink "$2")" || return 1
  text="${text%/}"
  # A harness with no tail (claude, codex) would make the glob below `*`, which
  # matches every link, so an empty tail must never match.
  tail="$(roost_adapter_tail "$1")"; [ -n "$tail" ] || return 1
  case "$text" in *"$tail") return 0 ;; *) return 1 ;; esac
}

# roost_adapter_state HARNESS -> ok | missing | dangling | other-checkout | foreign | none
#
# Reports what is AT the path. What to do about each value is each caller's
# own policy, not this function's — roost validate currently treats dangling
# exactly like foreign (see h_adapter_fix and offer_adapter_install), but that
# is validate's choice and is not guaranteed to stay true for every caller.
#
#   ok        the symlink is there and points at THIS checkout
#   missing   nothing at that path at all — safe to create
#   dangling  a symlink is there but points at nothing that exists. This is
#             OURS to have broken — the checkout it pointed at moved or was
#             deleted — not a tester's own file, so a caller is free to treat
#             it differently from foreign.
#   other-checkout  a live symlink whose text names a roost adapter in a DIFFERENT checkout — roost's own link, from a second copy of roost
#   foreign   something else occupies the path and is NOT a dangling link:
#             the tester's own extension, or any other file or link that is
#             not roost's.
#             "it is probably ours" is not a good enough reason to delete a
#             file (AGENTS.md §9 — verify, do not assume) — a caller that
#             wants to leave these alone reports the exact fix instead.
#   none      this harness has no symlink-shaped adapter (codex uses a hooks
#             file and a trust prompt, and both are out of scope for
#             installing)
#
# opencode2's adapter is a DIRECTORY symlink where the other three link a
# file, and the four states need no change for it: `-ef` follows a symlink to
# a directory exactly as it does to a file, so it is true for the link and
# its target directory; `-e` and `-L` behave the same for both; and a real
# directory sitting at the path is not `-ef` the target, so it reads foreign.
roost_adapter_state() {
  local h="$1" path want
  case "$h" in opencode|opencode2|pi|copilot) : ;; *) printf 'none'; return 0 ;; esac
  path="$(roost_adapter_path "$h")"; want="$(roost_adapter_target "$h")"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then printf 'missing'
  elif [ -L "$path" ] && [ ! -e "$path" ]; then printf 'dangling'
  elif [ "$path" -ef "$want" ]; then printf 'ok'
  elif [ -L "$path" ] && roost_adapter_link_names "$h" "$path"; then printf 'other-checkout'
  else printf 'foreign'
  fi
}

# roost_checkout_is_worktree [DIR] — true when DIR (default: this checkout) is
# a linked git worktree and not the primary checkout. In the primary checkout
# --git-common-dir and --git-dir are both `.git`; in a worktree --git-dir is
# `<primary>/.git/worktrees/<name>` while the common dir stays the primary's.
# Each is made absolute against DIR first, because git prints them relative
# in the primary checkout and absolute elsewhere. False, not an error, when
# git is missing or DIR is not in a work tree: the caller asks "should I
# worry", and no answer means no.
roost_checkout_is_worktree() {
  local dir="${1:-$(_roost_adapter_root)}" common gitdir
  command -v git >/dev/null 2>&1 || return 1
  common="$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null)" || return 1
  gitdir="$(git -C "$dir" rev-parse --git-dir 2>/dev/null)" || return 1
  common="$(cd -P "$dir" && cd -P "$common" 2>/dev/null && pwd)" || return 1
  gitdir="$(cd -P "$dir" && cd -P "$gitdir" 2>/dev/null && pwd)" || return 1
  [ "$common" != "$gitdir" ]
}

# roost_adapter_names_1x PATH — true when PATH is a symlink whose text names a
# roost 1.x opencode adapter, in this checkout or any other. The same test
# scripts/roost-doctor applies before it calls a leftover link roost's, so the
# two never disagree about whose link it is. Used for a DANGLING link only:
# with the target gone there is nothing to `-ef` against, and the link's own
# text is all that says whose it was.
#
# It lives here, not in scripts/roost-install, because two scripts must agree
# on it: the installer decides with it whether to remove a dangling
# plugin/roost.js on opencode 2, and scripts/roost-validate's offer predicts
# that removal with it. Two copies drifted once already — validate's offer said
# "will be removed" about a link the installer then refused.
roost_adapter_names_1x() {
  [ -L "$1" ] || return 1
  case "$(readlink "$1" 2>/dev/null)" in
    */adapters/opencode/roost.js) return 0 ;;
    *) return 1 ;;
  esac
}

# roost_adapter_key HARNESS -> the table key that harness gets on this
# machine. Prints `opencode2` when HARNESS is `opencode` and the opencode on
# PATH is 2.x or later (roost_opencode_v2, scripts/lib/roost-opencode.sh);
# otherwise prints HARNESS unchanged.
#
# Every caller that acts on the opencode on PATH asks this, so install, doctor
# and validate cannot disagree about which adapter a machine gets. "Not 2.x"
# includes no opencode at all and one whose version could not be read; those
# keep the 1.x key, for the reasons roost_opencode_v2's own comment gives.
#
# It runs `opencode --version` (bounded, in a throwaway directory -- see
# roost_opencode_version) only when HARNESS is `opencode`.
roost_adapter_key() {
  local h="${1-}"
  if [ "$h" = opencode ] && roost_opencode_v2; then
    printf 'opencode2'
  else
    printf '%s' "$h"
  fi
}
