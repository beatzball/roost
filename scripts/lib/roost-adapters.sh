# roost-adapters.sh — the adapter path table: where each harness keeps its
# configuration, and where roost's symlink-shaped adapters go and must point.
#
# Shared by scripts/roost-validate (report + optional install offer) and
# scripts/roost-install (the installer). One table, because a tester's report
# and the installer's plan must never disagree about which file either of them
# means.

# roost_adapter_home HARNESS — the directory that harness actually keeps its
# configuration and credentials in. Per harness, and never assumed to be the
# XDG one: AGENTS.md §8 exists because copilot ignores XDG entirely, and pi and
# codex each have their own override too.
roost_adapter_home() {
  case "$1" in
    opencode) printf '%s/opencode' "${XDG_CONFIG_HOME:-$HOME/.config}" ;;
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
# function now — scripts/roost-doctor sources this file and asks it for the
# path it reports on — so no copy is left to drift. Named by file and not by
# line number, because the line number this comment used to carry is exactly
# what went stale first.
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
    pi)       printf '%s/extensions/roost.ts' "$home" ;;
    copilot)  printf '%s/extensions/roost/extension.mjs' "$home" ;;
  esac
}
roost_adapter_target() {
  local here; here="$(_roost_adapter_root)"
  case "$1" in
    opencode) printf '%s/adapters/opencode/roost.js' "$here" ;;
    pi)       printf '%s/adapters/pi/roost.ts' "$here" ;;
    copilot)  printf '%s/adapters/copilot/extension.mjs' "$here" ;;
  esac
}

# roost_adapter_state HARNESS -> ok | missing | dangling | foreign | none
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
#   foreign   something else occupies the path and is NOT a dangling link:
#             another live checkout's symlink, or the tester's own extension.
#             "it is probably ours" is not a good enough reason to delete a
#             file (AGENTS.md §9 — verify, do not assume) — a caller that
#             wants to leave these alone reports the exact fix instead.
#   none      this harness has no symlink-shaped adapter (codex uses a hooks
#             file and a trust prompt, and both are out of scope for
#             installing)
roost_adapter_state() {
  local h="$1" path want
  case "$h" in opencode|pi|copilot) : ;; *) printf 'none'; return 0 ;; esac
  path="$(roost_adapter_path "$h")"; want="$(roost_adapter_target "$h")"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then printf 'missing'
  elif [ -L "$path" ] && [ ! -e "$path" ]; then printf 'dangling'
  elif [ "$path" -ef "$want" ]; then printf 'ok'
  else printf 'foreign'
  fi
}
