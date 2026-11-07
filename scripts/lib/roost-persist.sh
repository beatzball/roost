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
    # With the server stopped (decided once, above), Linux does now what the
    # next login would: `enable` without --now runs nothing, so `on` runs
    # --at-login itself, in the foreground, and the person sees the same
    # lines a login would write (§4.4, revision 9, C B2). On macOS the
    # bootstrap's RunAtLoad already ran the job.
    if [ "$running" = 0 ] && [ "${ROOST_PERSIST_WRITE_ONLY:-}" != 1 ]; then
      roost_persist_at_login "$name"
    fi
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
      "$(roost_shape_hdr "$f" saved)" "$(roost_shape_hdr "$f" gen)" \
      "$(roost_shape_hdr "$f" trigger)" "$(grep -c '^session ' "$f")" "$(grep -c '^pane ' "$f")"
  else
    printf '  newest save: none yet\n'
  fi
  printf '  pending: %s\n' "$(roost_persist__pending "$sd")"
  f="$(grep -v '^$' "$sd/login.log" 2>/dev/null | tail -1 || true)"
  printf '  last login restore: %s\n' "${f:-none yet}"
  return 0
}

# roost_persist_os_boot -> this OS boot's id, the name of the login/<os-boot>
# marker (§4.6): Linux's /proc/sys/kernel/random/boot_id, macOS's
# `sysctl kern.boottime` seconds. Exit 1 when neither can be read.
roost_persist_os_boot() {
  local b=""
  if [ -r /proc/sys/kernel/random/boot_id ]; then
    b="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
  else
    b="$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^[{] *sec = \([0-9][0-9]*\).*/\1/p' | head -1)"
  fi
  case "$b" in ''|*[!0-9a-f-]*) return 1 ;; esac
  printf '%s\n' "$b"
}

# roost_persist__log_trim FILE — login.log is truncated to its newest half
# when it passes 1 MB (§4.4), by a temp file and a rename, kept 0600.
roost_persist__log_trim() {
  local f="$1" n tmp
  [ -f "$f" ] || return 0
  n="$(wc -c < "$f" | tr -d ' ')"
  [ "$n" -gt 1048576 ] || return 0
  tmp="$( (umask 077; mktemp "$f.XXXXXX") 2>/dev/null)" || return 0
  # From the first whole line of the newer half on.
  tail -c "$((n / 2))" "$f" | sed '1d' > "$tmp" && mv -f "$tmp" "$f" || rm -f "$tmp"
}

# roost_persist__say TEXT — one stamped login.log line (stdout, which the
# caller points at login.log).
roost_persist__say() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

# roost_persist__sweep SD BOOT — what earlier boots left (§4.6, §3.6a), run
# AFTER this boot's own pending files are written:
#   - pending/<other boot>/, and launch-claims/<server>/claims/<other boot>/
#     (claims live under the state directory, never the shape directory:
#     roost_resume_claims_dir). Only with this server's BOOT known: with no
#     server there is no "this boot" to keep.
#   - closed/<B>/ only when NO save left names boot B: not `shape`, not a
#     file in history/, not `declined`, and not a live offer's pin
#     (`offer/save` while offer/ has a live owner). closed/ is not swept with
#     pending/: a save of an earlier boot still in the ring is restorable by
#     `--from STAMP-GEN`, and its closed record is what keeps a pane closed
#     on purpose out of it (§3.6 step 4).
roost_persist__sweep() {
  local sd="$1" boot="$2" d b keep=" " f cl
  if [ -n "$boot" ]; then
    for d in "$sd"/pending/*/; do
      [ -d "$d" ] || continue
      b="$(basename "$d")"
      [ "$b" = "$boot" ] || rm -rf "$sd/pending/$b"
    done
    if roost_resume_claims_dir -L "$SOCKET" "$boot" >/dev/null 2>&1; then
      cl="${ROOST_RESUME_CLAIMS%/*}"
      for d in "$cl"/*/; do
        [ -d "$d" ] || continue
        b="$(basename "$d")"
        [ "$b" = "$boot" ] || rm -rf "$cl/$b"
      done
    fi
  fi
  [ -d "$sd/closed" ] || return 0
  for f in "$sd/shape" "$sd"/history/* "$sd/declined"; do
    [ -f "$f" ] || continue
    keep="$keep$(roost_shape_hdr "$f" boot) "
  done
  if [ -f "$sd/offer/save" ] && roost_shape_owner_live "$sd/offer"; then
    keep="$keep$(roost_shape_hdr "$sd/offer/save" boot) "
  fi
  for d in "$sd"/closed/*/; do
    [ -d "$d" ] || continue
    b="$(basename "$d")"
    case "$keep" in *" $b "*) ;; *) rm -rf "$sd/closed/$b" ;; esac
  done
}

# roost_persist_at_login NAME -> the hidden form the login unit runs (§4.4,
# §4.6): place the saved fleet and STOP. The agents come back at the first
# attach (§9 Q1 A; the client-attached[98] hook, tmux/roost.conf). ALWAYS exit
# 0: a skipped session is a line in the log, not a failed login job.
#
# Everything goes to login.log (0600, halved past 1 MB): launchd already
# points stdout there; run from a terminal (Linux `on`, or ensure_session)
# the lines this run wrote are printed to the caller as well, so a person
# sees what a login would have done. Never a screen capture.
roost_persist_at_login() {
  local name="$1" sd log before=0 r=0
  sd="$(roost_shape_dir -L "$name" 2>/dev/null)" || return 0
  log="$sd/login.log"
  ( umask 077; [ -e "$log" ] || : > "$log" ) 2>/dev/null || return 0
  chmod 600 "$log" 2>/dev/null || true
  roost_persist__log_trim "$log"
  if [ /dev/stdout -ef "$log" ]; then
    roost_persist__at_login "$name" "$sd" || true
  else
    before="$(wc -c < "$log" | tr -d ' ')"
    roost_persist__at_login "$name" "$sd" >> "$log" 2>&1 || true
    tail -c "+$((before + 1))" "$log" 2>/dev/null || true
  fi
  return 0
}

roost_persist__at_login() {
  local name="$1" sd="$2" own=0 i dir osboot rc=0 sg dsg boot n
  . "$ROOST_HOME/scripts/lib/roost-restore.sh"
  . "$ROOST_HOME/scripts/lib/roost-resume.sh"
  ROOST_RESUME_TFLAG="-L" ROOST_RESUME_TSOCK="$SOCKET"
  ROOST_SHAPE_TFLAG="-L" ROOST_SHAPE_TSOCK="$SOCKET"
  # This form's own settings, never the environment's (the restore arm's
  # rule): placement as a plain restore would do it, every key resumable.
  ROOST_RESTORE_NORESUME=0 ROOST_RESTORE_RECENT=""
  ROOST_RESTORE_ONLY=()
  osboot="$(roost_persist_os_boot || true)"
  roost_persist__say "login restore for '$name' (pid $$, os boot ${osboot:-unknown})"
  # restoring/ FIRST, under the owner rule (§4.4), so a `roost` typed
  # meanwhile waits for this owner however long it takes (ensure_session,
  # §4.6) — the socket wait below included.
  roost_shape_owner_take "$sd/restoring" || own=$?
  case "$own" in
    # ROOST_PERSIST_LOST tells a caller in this shell (ensure_session's
    # login_restore_first) that it lost restoring/ to another restore, which
    # is still placing: it must wait for that one again, not go on and make
    # a session the restore is about to place (fix round 1).
    1) ROOST_PERSIST_LOST=1
       roost_persist__say "another restore (pid ${ROOST_SHAPE_OWNER_PID:-?}) is placing panes; nothing done"; return 0 ;;
    3) roost_persist__say "${ROOST_SHAPE_OWNER_FAULT:-cannot own $sd/restoring}; nothing done"; return 0 ;;
  esac
  # Up to 60 s for the socket directory to be writable: at login /tmp (or
  # TMUX_TMPDIR) may not be ready yet, and a server started into a directory
  # that is not there fails, or lands where nothing will look.
  dir="${TMUX_TMPDIR:-/tmp}"
  i=0
  while [ "$i" -lt 60 ] && ! { [ -d "$dir" ] && [ -w "$dir" ]; }; do sleep 1; i=$((i + 1)); done
  [ "$i" -ge 60 ] && roost_persist__say "the socket directory $dir is still not writable after 60 s; trying anyway"
  # R2 before anything else is decided (plan Task 5.4): a server still
  # running with its socket gone must not get a second one under its name.
  if ! server_running && server_lost_socket; then
    roost_persist__say "$(lost_socket_line)"
    roost_shape_owner_drop "$sd/restoring"
    return 0
  fi
  # Which save: §3.6's reading rule, steps 1 to 3 (its lines go to the log:
  # which save it chose, and why).
  r=0; roost_restore_pick "$sd" "" 2>&1 || r=$?
  if [ "$r" != 0 ]; then
    roost_persist__say "nothing to restore: no save for this server"
    roost_persist__done "$sd" "$osboot" ""
    return 0
  fi
  sg="$(roost_restore__stampgen "$ROOST_RESTORE_FILE")"
  roost_persist__say "picked $sg ($ROOST_RESTORE_WHY)"
  # A save a person declined at the restore offer is never restored by an
  # automatic path (§4.4, §4.8): `declined` is a hard link to that save, so
  # its header's boot and gen name it.
  if [ -f "$sd/declined" ]; then
    dsg="$(roost_restore__stampgen "$sd/declined")"
    if [ "$dsg" = "$sg" ]; then
      roost_persist__say "nothing placed: $sg was declined at the restore offer (roost restore --from $sg brings it back)"
      roost_persist__done "$sd" "$osboot" ""
      return 0
    fi
  fi
  # §3.6 step 4 (the closed record), BEFORE the Server step: a fleet ended on
  # purpose places nothing and so starts nothing (§8.1 test 8 (e)).
  r=0; roost_restore_prepare "$ROOST_RESTORE_FILE" "$sd" 2>&1 || r=$?
  if [ "$r" = 3 ]; then
    roost_persist__say "nothing to restore: every saved pane was closed on purpose (roost restore --from $ROOST_RESTORE_FILE brings it back)"
    rm -rf "${ROOST_RESTORE_PD:-}"
    roost_persist__done "$sd" "$osboot" ""
    return 0
  fi
  if [ "$r" != 0 ]; then
    roost_persist__say "the save was refused (exit $r); nothing placed"
    rm -rf "${ROOST_RESTORE_PD:-}"
    roost_persist__done "$sd" "$osboot" ""
    return 0
  fi
  # Placement, and NOT the loop: every keyed pane waits in its placeholder
  # with its pending file, written before the placeholder starts (§4.6).
  rc=0; roost_restore_run "$ROOST_RESTORE_FILE" "$sd" "$own" 2>&1 || rc=$?
  rm -rf "${ROOST_RESTORE_PD:-}"
  boot="$(t display -p '#{start_time}-#{pid}' 2>/dev/null || true)"
  n=0
  if [ -n "$boot" ] && [ -d "$sd/pending/$boot" ]; then
    n="$(ls "$sd/pending/$boot" 2>/dev/null | grep -c '^%' || true)"
  fi
  roost_persist__say "placed ${ROOST_RESTORE_SESSIONS:-0} sessions, ${ROOST_RESTORE_WINDOWS:-0} windows, ${ROOST_RESTORE_PANES:-0} panes (exit $rc); $n agents wait for the first attach"
  roost_persist__done "$sd" "$osboot" "$boot"
  # Restore's own final save, now that restoring/ is gone (§3.5 step 4).
  server_running && roost_shape_save_now -L "$SOCKET" restore
  return 0
}

# roost_persist__done SD OSBOOT BOOT — the end of every --at-login path that
# got as far as reading the saves: the login/<os-boot> marker ("this OS
# boot's fleet is accounted for", §4.4: without it a server a person later
# kills on purpose in the same boot would be rebuilt by ensure_session), the
# sweep of earlier boots, then restoring/ released — last, so a waiting
# `roost` never sees the gap between the two.
roost_persist__done() {
  local sd="$1" osboot="$2" boot="$3"
  if [ -n "$osboot" ]; then
    ( umask 077; mkdir -p "$sd/login" && roost_persist__say "accounted for" > "$sd/login/$osboot" ) 2>/dev/null || true
  fi
  roost_persist__sweep "$sd" "$boot"
  roost_shape_owner_drop "$sd/restoring"
}

# roost_persist_rewrite_unit NAME -> when NAME's `persist` marker is set and
# its login unit runs another checkout's bin/roost (an upgrade or a relink
# moved checkouts), the unit is written again naming THIS checkout
# ($ROOST_HOME) and reloaded, and one line says so. `roost upgrade` calls it
# (§4.4: "the unit must follow"). The unit's environment is read from the
# existing service.env, which is NOT rewritten: only `persist on` writes it,
# so a person's edit to it survives an upgrade. Exit 0 always; a unit it
# cannot write is one line on stderr.
roost_persist_rewrite_unit() {
  local name="$1" os sd root unit c r=0
  root="$(roost_shape_saving)" || return 0
  sd="$root/$name"
  [ -e "$sd/persist" ] && [ -f "$sd/service.env" ] || return 0
  os="$(roost_persist_os)" || return 0
  unit="$(roost_persist_unit_path "$os" "$name")"
  c="$(roost_persist__unit_checkout "$os" "$unit" 2>/dev/null || true)"
  [ "$c" = "$ROOST_HOME/bin/roost" ] && return 0
  if [ "$os" = launchd ]; then roost_persist__plist "$name" "$sd" | roost_persist__write "$unit" || r=$?
  else roost_persist__unit "$name" "$sd" | roost_persist__write "$unit" || r=$?; fi
  if [ "$r" != 0 ]; then
    printf "roost: could not rewrite the login unit for '%s' (%s); run roost persist on\n" "$name" "$unit" >&2
    return 0
  fi
  if [ "${ROOST_PERSIST_WRITE_ONLY:-}" != 1 ]; then
    roost_persist__load "$os" "$name" "$unit" || \
      printf "roost: rewrote %s but could not load it; run roost persist on\n" "$unit" >&2
  fi
  printf "roost: the login unit for '%s' now runs this checkout (%s)\n" "$name" "$unit"
  return 0
}
