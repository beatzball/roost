# roost-shape.sh — the saved shape of a server (#51, #191): which directory a
# save goes to, and whether one is written at all.
#
# Sourced by bin/roost. The design, and every measurement these rules rest on,
# is docs/airig/specs/2026-10-24-persistent-sessions-design.md (§3.1 where it
# lives, §3.4a the one switch). Later tasks add the writer, the checker, the
# parser and the saver to this file; the plan's "Names this plan fixes" table
# says which function lives where.
#
# THE LAYOUT, one directory per server:
#
#   <root>/<server key>/
#     shape, history/, gen, ...   (§3.1 lists every file; each lands with the
#                                  task that first writes it)
#
# <root> is roost_shape_saving's answer. <server key> is roost_shape_key's.
# The directory is 0700 and every file in it 0600, because a shape lists every
# project directory and every session id, and a session id alone is enough to
# `--resume` a conversation on a shared machine (§3.1).

# roost_shape_saving -> prints the shape root, or nothing; exit 0 when saving
# is on, 1 when it is off.
#
# THE ONE SWITCH (§3.4a). Every writer of a shape — `roost save`, the hooks,
# the direct calls in roost's own verbs — asks this function first and nothing
# else. That is the whole point of it: if saving ever became opt-in, this is
# the one place that would change, and the spec lists the sections that would
# change with it. Decided by the human on 2026-10-25: only the login service
# is opt-in, saving is always on, so this reads ROOST_SHAPE_DIR and NOTHING
# else — no `persist` marker, no config file.
#
# ROOST_SHAPE_DIR, when SET, wins outright — even when empty, which is how
# tests/lib.sh switches saving off for the whole suite and how a user turns it
# off. It must be absolute; a relative value saves nothing rather than
# scattering shapes into whatever directory a hook happened to run in. Unset,
# the default is $XDG_STATE_HOME/roost/shapes, beside the pane records and the
# extension state, so `rm -rf ~/.local/state/roost` still means "forget
# everything roost remembered" (§3.1, §9 Q3). A relative XDG_STATE_HOME is
# ignored, as the XDG spec says and roost_record_root does; then
# $HOME/.local/state. No usable HOME either: nothing.
#
# Trailing slashes are dropped, and a root that is then empty — "/" — is
# refused, the record's rule: later parts remove directories under this path.
roost_shape_saving() {
  local r x
  if [ "${ROOST_SHAPE_DIR+set}" = set ]; then
    r="$ROOST_SHAPE_DIR"
  else
    x="${XDG_STATE_HOME:-}"
    case "$x" in
      /*) r="$x/roost/shapes" ;;
      *)
        case "${HOME:-}" in
          /*) r="$HOME/.local/state/roost/shapes" ;;
          *) return 1 ;;
        esac ;;
    esac
  fi
  case "$r" in /*) ;; *) return 1 ;; esac
  while :; do
    case "$r" in */) r="${r%/}" ;; *) break ;; esac
  done
  [ -n "$r" ] || return 1
  printf '%s\n' "$r"
}

# roost_shape_key FLAG SOCKET -> prints the server's directory name.
#
# FLAG and SOCKET are bin/roost's own pair (_SOCKET_FLAG and SOCKET): `-L
# NAME` for a named server, `-S PATH` for a socket path.
#
# A `-L NAME` server is keyed NAME (`roost` for the default), because the name
# is what survives a reboot: the socket FILE under /tmp/tmux-UID/ does not, so
# a key built from it would never find the last boot's shape.
#
# A `-S PATH` server is keyed `path-<cksum of PATH>`. Not PATH with `/` written
# as `-`: that is not one-to-one — `/a/b-c` and `/a-b/c` both become `-a-b-c`
# — and two servers would overwrite each other's shape. `cksum` is POSIX and on
# every machine roost runs on; the save's header keeps the readable path. A
# side effect worth having: a test server whose socket FILE is called `roost`
# still never shares a key with the real server.
roost_shape_key() {
  case "$1" in
    -S) printf 'path-%s\n' "$(printf '%s' "$2" | cksum | cut -d' ' -f1)" ;;
    *) printf '%s\n' "$2" ;;
  esac
}

# roost_shape_dir FLAG SOCKET -> prints <root>/<key>, made and set 0700; exit
# 1, printing and making nothing, when saving is off or the directory cannot
# be made.
#
# The root is made 0700 only when this creates it — a ROOST_SHAPE_DIR the
# user made keeps the mode they gave it, and its parents (…/state/roost is
# shared with the pane records and extension state) are not touched; the
# record's rule (roost_record_ensure). The per-server directory is roost's own
# and is set 0700 every time, so one left 0755 by hand or by an older roost
# stops listing every project to other local users at the next save.
#
# The FILES are the writer's half: whoever writes one sets `umask 077` for that
# write. That cannot be done here — callers run this in a $(...) subshell, and
# a umask set in a subshell does not reach the caller.
roost_shape_dir() {
  local root key d
  root="$(roost_shape_saving)" || return 1
  key="$(roost_shape_key "$1" "$2")"
  [ -n "$key" ] || return 1
  d="$root/$key"
  if [ ! -d "$root" ]; then
    mkdir -p "$root" 2>/dev/null || return 1
    chmod 700 "$root" 2>/dev/null || true
  fi
  mkdir -p "$d" 2>/dev/null || return 1
  chmod 700 "$d" 2>/dev/null || return 1
  printf '%s\n' "$d"
}
