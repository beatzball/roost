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
  esac
}

# _roost_adapter_root — the checkout root, for roost_adapter_target's install
# targets. A lib cannot depend on a caller's variable name (roost-validate
# calls its own copy $HERE; bin/roost calls its own $ROOST_HOME), so this
# takes $ROOST_HOME when a caller has already resolved one, and otherwise
# resolves it from this file's own location the same way bin/roost resolves
# its own — following symlinks, then two directories up from
# scripts/lib/roost-adapters.sh to the checkout root.
_roost_adapter_root() {
  if [ -n "${ROOST_HOME:-}" ]; then printf '%s' "$ROOST_HOME"; return; fi
  local source dir
  source="${BASH_SOURCE[0]}"
  while [ -L "$source" ]; do
    dir="$(cd -P "$(dirname "$source")" && pwd)"
    source="$(readlink "$source")"
    [[ "$source" != /* ]] && source="$dir/$source"
  done
  printf '%s' "$(cd -P "$(dirname "$source")/../.." && pwd)"
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

# roost_adapter_state HARNESS -> ok | missing | foreign | none
#
#   ok       the symlink is there and points at THIS checkout
#   missing  nothing at that path at all — safe to create
#   foreign  something else is there. Could be another checkout's link, could
#            be the tester's own extension, could be a dangling link to a
#            checkout they deleted. roost validate does not touch any of them.
#            A tester who keeps their own extension at that path must not lose
#            it to a validation run, and "it is probably ours" is not a good
#            enough reason to delete a file (AGENTS.md §9 — verify, do not
#            assume). Reported with the exact fix so they can decide.
#   none     this harness has no symlink-shaped adapter (codex uses a hooks
#            file and a trust prompt, and both are out of scope for installing)
roost_adapter_state() {
  local h="$1" path want
  case "$h" in opencode|pi|copilot) : ;; *) printf 'none'; return 0 ;; esac
  path="$(roost_adapter_path "$h")"; want="$(roost_adapter_target "$h")"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then printf 'missing'
  elif [ -L "$path" ] && [ ! -e "$path" ]; then printf 'foreign'   # dangling
  elif [ "$path" -ef "$want" ]; then printf 'ok'
  else printf 'foreign'
  fi
}
