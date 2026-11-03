# roost-persist.sh — `roost persist on|off|status [--name NAME]` and the
# hidden `--at-login NAME` the login unit runs (#192).
#
# The design is docs/airig/specs/2026-10-24-persistent-sessions-design.md
# §4.4 (the verb, the plist, the unit, `service.env`), §4.5 (what doctor
# reads back) and §4.6 (the login half of the pending record). The plan is
# docs/airig/plans/2026-10-26-persistent-sessions-plan.md, Part 5.
#
# ONE UNIT PER SERVER, never a shared template: `off` for one server touches
# nothing of another's. macOS: a LaunchAgent plist labelled
# dev.roosting.roost.<server>. Linux: a systemd user unit
# roost-persist-<server>.service. Both run THIS checkout's
# `bin/roost persist --at-login <server>` with the roots of `service.env`.
#
# NEVER STOPPED. `off` is `launchctl bootout` (macOS) or `systemctl --user
# disable` (Linux) — never `stop`, never `--now`. The fleet lives in the
# unit's cgroup on Linux, and stopping a unit is how forty agents end at once
# (§4.4). Measured: under §4.4's unit a `stop` leaves the server running
# (KillMode=process), and without RemainAfterExit the server dies the moment
# the oneshot exits (docs/airig/probes/persist-5-systemd.md); on macOS a
# bootout of a job with AbandonProcessGroup leaves the server it started
# running (docs/airig/probes/persist-5-terminal-quit.md).
#
# Uses bin/roost's `t`, `server_running`, `server_lost_socket`, SOCKET,
# _SOCKET_FLAG and ROOST_HOME, and scripts/lib/roost-shape.sh (sourced by
# the arm before this file). Every function is bash 3.2 safe and `set -u`
# clean: bin/roost runs on macOS /bin/bash.

# The variables service.env may hold, in the order it writes them (§4.4).
# The roots, so the service reads the same directories the saves were
# written to — a custom state root is otherwise simply not found at login —
# and the harness homes §2.8's store checks read. OPENCODE_CONFIG_DIR is not
# what roost reads for opencode (the adapter table resolves its home from
# XDG_CONFIG_HOME, already here); it is carried so a resumed opencode finds
# the wiring it was started with. LANG and LC_ALL because a launchd job and a
# systemd user service both start with a minimal environment, and tmux reads
# its locale once at start (the `_` glyphs of a C locale).
ROOST_PERSIST_VARS="HOME PATH LANG LC_ALL XDG_STATE_HOME XDG_CONFIG_HOME ROOST_SHAPE_DIR TMUX_TMPDIR CLAUDE_CONFIG_DIR CODEX_HOME COPILOT_HOME PI_CODING_AGENT_DIR OPENCODE_CONFIG_DIR"

# The roots `status` and doctor compare with the caller's: every variable
# above but HOME, PATH and the locale, which differ between a login shell and
# a terminal for reasons that change nothing roost reads.
ROOST_PERSIST_ROOTS="XDG_STATE_HOME XDG_CONFIG_HOME ROOST_SHAPE_DIR TMUX_TMPDIR CLAUDE_CONFIG_DIR CODEX_HOME COPILOT_HOME PI_CODING_AGENT_DIR OPENCODE_CONFIG_DIR"

# roost_persist_name_ok NAME -> exit 0 when NAME may be put in a unit name
# and a plist label: [A-Za-z0-9._-]+, and not `.` or `..` (the name is also
# the shape directory's key, and `..` would name its parent). Unit names and
# labels are not escaped, they are refused (§4.4).
roost_persist_name_ok() {
  case "$1" in ''|.|..|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

# roost_persist_os -> prints `launchd` or `systemd`; exit 17 when this
# machine has neither (§4.4: named, never guessed). `uname -s` decides which
# one to look for, so a Linux box that happens to carry a `launchctl` of some
# other tool is not mistaken for a Mac.
roost_persist_os() {
  case "$(uname -s 2>/dev/null || true)" in
    Darwin) command -v launchctl >/dev/null 2>&1 && { printf 'launchd\n'; return 0; } ;;
    Linux) command -v systemctl >/dev/null 2>&1 && { printf 'systemd\n'; return 0; } ;;
  esac
  return 17
}

roost_persist_label() { printf 'dev.roosting.roost.%s\n' "$1"; }

# roost_persist_unit_path OS NAME -> the unit file's path. HOME and
# XDG_CONFIG_HOME are the caller's: a test's are temp dirs.
roost_persist_unit_path() {
  if [ "$1" = launchd ]; then
    printf '%s/Library/LaunchAgents/%s.plist\n' "$HOME" "$(roost_persist_label "$2")"
  else
    printf '%s/systemd/user/roost-persist-%s.service\n' "$(roost_persist__xdg XDG_CONFIG_HOME)" "$2"
  fi
}

# roost_persist__xdg VAR -> the resolved XDG root: the variable when it is an
# absolute path, else the spec's default under HOME (a relative value is
# ignored, as the XDG spec says and roost_shape_saving does).
roost_persist__xdg() {
  local v
  eval "v=\${$1:-}"
  case "$v" in /*) printf '%s\n' "$v"; return 0 ;; esac
  case "$1" in
    XDG_STATE_HOME) printf '%s/.local/state\n' "$HOME" ;;
    XDG_CONFIG_HOME) printf '%s/.config\n' "$HOME" ;;
  esac
}

# roost_persist__value VAR -> the value service.env carries for VAR, or exit
# 1 when it carries none: the XDG roots and ROOST_SHAPE_DIR resolved (the
# service must read the very directories this shell does), anything else as
# set. Never a value holding a newline: one `NAME=value` per line.
roost_persist__value() {
  local v=""
  case "$1" in
    XDG_STATE_HOME|XDG_CONFIG_HOME) v="$(roost_persist__xdg "$1")" ;;
    ROOST_SHAPE_DIR) v="$(roost_shape_saving)" || return 1 ;;
    *) eval "[ \"\${$1+set}\" = set ]" || return 1; eval "v=\${$1}" ;;
  esac
  [ -n "$v" ] || return 1
  case "$v" in *$'\n'*) return 1 ;; esac
  printf '%s\n' "$v"
}

# roost_persist__secret VAR -> exit 0 for a name the file must never hold:
# one containing KEY, TOKEN, SECRET or PASSWORD (§4.4). None of the names
# above does; the check stays so that adding one to the list cannot carry a
# credential into a file a login job reads. The service needs roots, not
# credentials.
roost_persist__secret() {
  case "$1" in *KEY*|*TOKEN*|*SECRET*|*PASSWORD*) return 0 ;; esac
  return 1
}

# roost_persist__env_write DIR -> writes DIR/service.env, 0600, by a temp
# file and a rename. Written by `on` and ONLY by `on` (the plan's Task 5.5
# rule): status, doctor and --at-login read it and never write it. Another
# tool rewrote its unit on every start, lost the edits people made to it and
# raised a system notification each time.
roost_persist__env_write() {
  local d="$1" tmp n v
  tmp="$( (umask 077; mktemp "$d/.service.env.XXXXXX") 2>/dev/null)" || return 1
  for n in $ROOST_PERSIST_VARS; do
    roost_persist__secret "$n" && continue
    v="$(roost_persist__value "$n")" || continue
    printf '%s=%s\n' "$n" "$v"
  done > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$d/service.env" || { rm -f "$tmp"; return 1; }
}

# roost_persist__env_get FILE VAR -> the value FILE holds for VAR; exit 1
# when it holds none.
roost_persist__env_get() {
  local l
  l="$(grep -m1 "^$2=" "$1" 2>/dev/null)" || return 1
  printf '%s\n' "${l#*=}"
}

# roost_persist__xml TEXT -> TEXT with the five XML specials escaped.
roost_persist__xml() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

# roost_persist__plist NAME DIR -> the LaunchAgent plist on stdout (§4.4).
# EnvironmentVariables are read from DIR/service.env, so the job and the file
# cannot disagree. RunAtLoad: the bootstrap runs the job at once, which
# meets the live fleet, skips it as existing and writes the login marker.
# AbandonProcessGroup: launchd otherwise kills what is left of the job's
# process group when it exits; the tmux server daemonizes into its own
# session anyway, and saying so costs one line and removes the question.
roost_persist__plist() {
  local name="$1" d="$2" l n v
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0">' '<dict>'
  printf '  <key>Label</key>\n  <string>%s</string>\n' "$(roost_persist__xml "$(roost_persist_label "$name")")"
  printf '  <key>ProgramArguments</key>\n  <array>\n'
  printf '    <string>%s</string>\n' "$(roost_persist__xml "$ROOST_HOME/bin/roost")" persist --at-login "$name"
  printf '  </array>\n  <key>EnvironmentVariables</key>\n  <dict>\n'
  while IFS= read -r l; do
    case "$l" in *=*) ;; *) continue ;; esac
    n="${l%%=*}" v="${l#*=}"
    printf '    <key>%s</key>\n    <string>%s</string>\n' "$(roost_persist__xml "$n")" "$(roost_persist__xml "$v")"
  done < "$d/service.env"
  printf '  </dict>\n'
  printf '  <key>RunAtLoad</key>\n  <true/>\n'
  printf '  <key>AbandonProcessGroup</key>\n  <true/>\n'
  printf '  <key>StandardOutPath</key>\n  <string>%s</string>\n' "$(roost_persist__xml "$d/login.log")"
  printf '  <key>StandardErrorPath</key>\n  <string>%s</string>\n' "$(roost_persist__xml "$d/login.log")"
  printf '</dict>\n</plist>\n'
}

# roost_persist__sd TEXT -> TEXT for a systemd unit line: `%` doubled (a
# specifier otherwise).
roost_persist__sd() { printf '%s' "$1" | sed 's/%/%%/g'; }

# roost_persist__unit NAME DIR -> the systemd user unit on stdout (§4.4).
# Type=oneshot with RemainAfterExit is what keeps systemd from treating the
# unit as finished when --at-login exits and killing its cgroup — the tmux
# server and every agent in it — under the default KillMode=control-group.
# KillMode=process is belt and braces: an explicit `stop` reaches only the
# main process, which has already exited. Both measured on a VM
# (docs/airig/probes/persist-5-systemd.md: each control without its line lost
# the server). No ExecStop, ever.
roost_persist__unit() {
  printf '[Unit]\nDescription=roost: bring the %s fleet back at login (#192)\n\n' "$(roost_persist__sd "$1")"
  printf '[Service]\nType=oneshot\nRemainAfterExit=yes\nKillMode=process\n'
  printf 'EnvironmentFile=%s\n' "$(roost_persist__sd "$2/service.env")"
  printf 'ExecStart="%s" persist --at-login %s\n\n' "$(roost_persist__sd "$ROOST_HOME/bin/roost")" "$1"
  printf '[Install]\nWantedBy=default.target\n'
}

# roost_persist__write FILE -> stdin into FILE by a temp file and a rename,
# 0600 (the unit names the shape directory, which lists every project).
roost_persist__write() {
  local f="$1" tmp
  ( umask 077; mkdir -p "${f%/*}" ) 2>/dev/null || return 1
  tmp="$( (umask 077; mktemp "$f.XXXXXX") 2>/dev/null)" || return 1
  cat > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# roost_persist__loaded OS NAME -> exit 0 when the unit is loaded (macOS) or
# enabled (Linux).
roost_persist__loaded() {
  if [ "$1" = launchd ]; then
    launchctl print "gui/$(id -u)/$(roost_persist_label "$2")" >/dev/null 2>&1
  else
    systemctl --user is-enabled "roost-persist-$2.service" >/dev/null 2>&1
  fi
}

# roost_persist__undo DIR UNIT — what a failed `on` wrote, removed, so it
# leaves nothing behind: otherwise doctor would read "login restore on" and
# ensure_session would run a login restore with no service behind it (§4.4,
# revision 10, F N4).
roost_persist__undo() {
  rm -f "$1/persist" "$1/service.env"
  [ -n "${2:-}" ] && rm -f "$2"
  return 0
}

# roost_persist_on NAME -> §4.4 `on`. Exit 0, 1, or 17.
#
# The order is the spec's: the marker, service.env, the save (only with the
# server running), then the unit, then the load. With the server running the
# save is PUBLISHED before the unit is loaded (revision 8, F B1): it is not
# `--auto`, so a live saver's lock/ is waited for by the owner rule
# (roost_shape_save), and only then is the unit loaded — otherwise RunAtLoad
# could run --at-login while `shape` is still a crashed save, skip the live
# `main` and place every other saved session. Running or not is decided ONCE,
# here, by server_running: a server that dies during the save is a failed
# save, not the stopped case.
#
# ROOST_PERSIST_WRITE_ONLY=1 (the plan's seam): write the unit, load nothing.
roost_persist_on() {
  local name="$1" os sd unit running=0 r
  os="$(roost_persist_os)" || {
    printf 'roost persist: this machine has neither launchd nor systemd; nothing done\n' >&2; return 17; }
  if ! roost_shape_saving >/dev/null; then
    printf 'roost persist: saving is off (ROOST_SHAPE_DIR is empty or not an absolute path), so there is nothing to restore at login; nothing done\n' >&2
    return 1
  fi
  if [ "$os" = systemd ]; then
    # A unit line is not escaped beyond `%`: a path with a quote or a
    # backslash is refused rather than half-quoted.
    case "$ROOST_HOME$(roost_shape_saving)" in *\"*|*\\*)
      printf 'roost persist: the checkout or the shape root holds a quote or a backslash, which a systemd unit line cannot carry; nothing done\n' >&2
      return 1 ;;
    esac
  fi
  sd="$(roost_shape_dir -L "$name")" || {
    printf 'roost persist: cannot make the shape directory for %s; nothing done\n' "$name" >&2; return 1; }
  unit="$(roost_persist_unit_path "$os" "$name")"
  server_running && running=1
  ( umask 077; : > "$sd/persist" ) 2>/dev/null || {
    printf 'roost persist: cannot write in %s; nothing done\n' "$sd" >&2; return 1; }
  if ! roost_persist__env_write "$sd"; then
    roost_persist__undo "$sd"
    printf 'roost persist: cannot write %s/service.env; nothing done\n' "$sd" >&2
    return 1
  fi
  if [ "$running" = 1 ]; then
    if ! roost_shape_save -L "$name" "" persist-on >/dev/null; then
      roost_persist__undo "$sd"
      printf 'roost persist: the save failed, so the login unit was not installed; nothing left behind\n' >&2
      return 1
    fi
  fi
  # login.log exists before launchd opens it, so it keeps its 0600 (§4.4).
  ( umask 077; [ -e "$sd/login.log" ] || : > "$sd/login.log" ) 2>/dev/null || true
  if [ "$os" = launchd ]; then r=0; roost_persist__plist "$name" "$sd" | roost_persist__write "$unit" || r=$?
  else r=0; roost_persist__unit "$name" "$sd" | roost_persist__write "$unit" || r=$?; fi
  if [ "$r" != 0 ]; then
    roost_persist__undo "$sd" "$unit"
    printf 'roost persist: cannot write %s; nothing left behind\n' "$unit" >&2
    return 1
  fi
  if [ "${ROOST_PERSIST_WRITE_ONLY:-}" != 1 ]; then
    if ! roost_persist__load "$os" "$name" "$unit"; then
      roost_persist__undo "$sd" "$unit"
      printf 'roost persist: could not load %s; nothing left behind\n' "$unit" >&2
      return 1
    fi
  fi
  printf "persist: on for '%s' (%s: %s)\n" "$name" "$os" "$unit"
  if [ "$os" = systemd ]; then
    printf 'the unit runs at your next login; to start it at boot without a login: loginctl enable-linger\n'
  fi
  return 0
}

# roost_persist__load OS NAME UNIT -> loads the unit. macOS: bootstrap into
# the gui domain; a job already loaded (a second `on`) is booted out first,
# which with AbandonProcessGroup ends no server. Linux: enable, WITHOUT
# `--now` (the unit runs at the next login).
roost_persist__load() {
  local dom
  if [ "$1" = launchd ]; then
    dom="gui/$(id -u)"
    if launchctl print "$dom/$(roost_persist_label "$2")" >/dev/null 2>&1; then
      launchctl bootout "$dom/$(roost_persist_label "$2")" >/dev/null 2>&1 || true
    fi
    launchctl bootstrap "$dom" "$3" >/dev/null 2>&1
  else
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user enable "roost-persist-$2.service" >/dev/null 2>&1
  fi
}

# roost_persist_off NAME -> §4.4 `off`. Unload (never stop), then remove the
# unit file, the `persist` marker and service.env — NOTHING else: shapes,
# history and pending stay (#192 requirement 2). Another server's unit is a
# different file and is not touched. Exit 0 or 17.
roost_persist_off() {
  local name="$1" os sd unit root
  os="$(roost_persist_os)" || {
    printf 'roost persist: this machine has neither launchd nor systemd; nothing done\n' >&2; return 17; }
  unit="$(roost_persist_unit_path "$os" "$name")"
  if [ "${ROOST_PERSIST_WRITE_ONLY:-}" != 1 ]; then
    if [ "$os" = launchd ]; then
      launchctl bootout "gui/$(id -u)/$(roost_persist_label "$name")" >/dev/null 2>&1 || true
    else
      systemctl --user disable "roost-persist-$name.service" >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$unit"
  if root="$(roost_shape_saving)"; then
    sd="$root/$name"
    rm -f "$sd/persist" "$sd/service.env"
  fi
  printf "persist: off for '%s' (no agent was stopped; saves, history and pending resumes are kept)\n" "$name"
  return 0
}

# roost_persist__roots_diff FILE -> prints `VAR (unit: X, yours: Y)` for
# every root service.env names differently from this shell; nothing when
# they match. Reads the file, never writes it.
roost_persist__roots_diff() {
  local n a b
  for n in $ROOST_PERSIST_ROOTS; do
    a="$(roost_persist__env_get "$1" "$n" || true)"
    b="$(roost_persist__value "$n" || true)"
    [ "$a" = "$b" ] || printf '%s (unit: %s, yours: %s)\n' "$n" "${a:-unset}" "${b:-unset}"
  done
}

# roost_persist__unit_checkout OS UNIT -> the bin/roost the unit runs.
roost_persist__unit_checkout() {
  if [ "$1" = launchd ]; then
    sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/{s/^ *<string>\(.*\)<\/string>$/\1/p;}' "$2" 2>/dev/null | head -1 \
      | sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e "s/&apos;/'/g" -e 's/&amp;/\&/g'
  else
    sed -n 's/^ExecStart="\(.*\)" persist --at-login .*/\1/p' "$2" 2>/dev/null | head -1 | sed 's/%%/%/g'
  fi
}

# roost_persist__pending SD -> one line: the pending record's counts, by
# state, over every boot left in pending/.
roost_persist__pending() {
  local f st w=0 l=0 fl=0 tk=0 n=0
  for f in "$1"/pending/*/%*; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    st="$(roost_pending_state "$f" 2>/dev/null || true)"
    case "$st" in
      waiting) w=$((w + 1)) ;; launching) l=$((l + 1)) ;; taken) tk=$((tk + 1)) ;; failed-*) fl=$((fl + 1)) ;;
    esac
  done
  printf '%s (%s waiting, %s launching, %s failed, %s taken)\n' "$n" "$w" "$l" "$fl" "$tk"
}

# roost_persist_status NAME -> §4.4 `status`: on/off, the unit, whether it is
# loaded and names this checkout, the roots, the newest save, the pending
# record and the last login.log line. Reads only; makes no directory and
# writes no file. Exit 0, or 17.
roost_persist_status() {
  local name="$1" os sd="" unit root on=off c diff f
  os="$(roost_persist_os)" || {
    printf 'roost persist: this machine has neither launchd nor systemd\n' >&2; return 17; }
  unit="$(roost_persist_unit_path "$os" "$name")"
  if root="$(roost_shape_saving)"; then sd="$root/$name"; fi
  [ -n "$sd" ] && [ -e "$sd/persist" ] && on=on
  printf "persist: %s for '%s'\n" "$on" "$name"
  if [ -f "$unit" ]; then
    if roost_persist__loaded "$os" "$name"; then
      printf '  unit: %s (loaded)\n' "$unit"
    else
      printf '  unit: %s (not loaded)\n' "$unit"
    fi
    c="$(roost_persist__unit_checkout "$os" "$unit")"
    if [ "$c" = "$ROOST_HOME/bin/roost" ]; then printf '  the unit names this checkout\n'
    else printf '  the unit names another checkout: %s (roost persist on rewrites it)\n' "${c:-?}"; fi
  else
    printf '  unit: %s (none)\n' "$unit"
  fi
  [ -n "$sd" ] || { printf '  saving is off (ROOST_SHAPE_DIR is empty)\n'; return 0; }
  if [ -f "$sd/service.env" ]; then
    diff="$(roost_persist__roots_diff "$sd/service.env")"
    if [ -z "$diff" ]; then printf '  service.env: roots match\n'
    else printf '  service.env: differs from yours: %s\n' "$(printf '%s' "$diff" | tr '\n' ';' | sed 's/;/; /g')"; fi
  fi
  f="$sd/shape"
  if [ -f "$f" ]; then
    printf '  newest save: %s gen %s %s, %s sessions / %s panes\n' \
      "$(sed -n 's/^saved //p;/^$/q' "$f")" "$(sed -n 's/^gen //p;/^$/q' "$f")" \
      "$(sed -n 's/^trigger //p;/^$/q' "$f")" "$(grep -c '^session ' "$f")" "$(grep -c '^pane ' "$f")"
  else
    printf '  newest save: none yet\n'
  fi
  printf '  pending: %s' "$(roost_persist__pending "$sd")"
  f="$(grep -v '^$' "$sd/login.log" 2>/dev/null | tail -1 || true)"
  printf '  last login restore: %s\n' "${f:-none yet}"
  return 0
}
