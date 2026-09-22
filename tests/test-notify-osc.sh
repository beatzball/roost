#!/usr/bin/env bash
# The OSC notification backend (#46): a notification that reaches the human's
# own terminal instead of the desktop of the machine the fleet runs on.
#
# Every assertion here is byte-exact. The payload is an escape sequence going
# to a live terminal, so "close enough" is a corrupted screen: a missing
# terminator leaves the terminal swallowing everything after it as part of the
# OSC string.
#
# MEASURED (tmux 3.6, macOS 25.3.0, 2026-09-21) — why the backend writes to
# #{client_tty} and not to the pane:
#
#   bare OSC 9 -> client tty                      ARRIVES at the outer terminal
#   bare OSC 9 -> pane tty                        absent (tmux parses and drops it)
#   DCS-wrapped OSC 9 from the pane, passthrough on, pane VISIBLE     ARRIVES
#   DCS-wrapped OSC 9 from the pane, passthrough on, pane OFF-SCREEN  absent
#   DCS-wrapped OSC 9 from the pane, passthrough off                  absent
#
# The off-screen row is the whole argument. roost notifies ONLY when the pane
# is off-screen (scripts/roost-agent-state guards the call on
# #{window_active} != 1), so the tmux-passthrough route drops exactly the
# notifications this feature exists to deliver. A write to the client's tty is
# the slave side of the pty whose master is the terminal emulator, so it
# bypasses tmux's parser entirely — which is also why it needs no
# `allow-passthrough` and no DCS wrapper.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
NOTIFY="$HERE/scripts/roost-notify"

roost_test_server; sock="$ROOST_TEST_SOCK"; trap roost_test_teardown EXIT
export ROOST_NOTIFY_SOCK="$ROOST_TEST_SOCK"

# A plain file stands in for a client tty. The backend only ever opens the
# path it is given and writes to it, so a file exercises the identical code
# path and lets the test compare bytes. A real attached client is exercised
# further down, through a pty, because a file cannot prove client discovery.
fake_tty() { : > "$1"; T set-option -g @roost-notify-osc-tty "$1"; }

hexof() { od -An -tx1 -v < "$1" | tr -d ' \n'; }
# hex of the same bytes built independently, so the expectation is spelled as
# the sequence itself rather than as a copy of whatever the script produced.
hexpect() { printf '%b' "$1" | od -An -tx1 -v | tr -d ' \n'; }

# SSH_CONNECTION is how tmux itself reports a remote client: it is in tmux's
# DEFAULT update-environment list (MEASURED on tmux 3.6:
# "DISPLAY KRB5CCNAME MSYSTEM SSH_ASKPASS SSH_AUTH_SOCK SSH_AGENT_PID
# SSH_CONNECTION WINDOWID XAUTHORITY"), so tmux copies it from the attaching
# client into that session's environment, and removes it again when a local
# client attaches. SSH_TTY is NOT in that list, which is why the remote test
# cannot rest on SSH_TTY alone.
REMOTE='10.0.0.2 51000 10.0.0.1 22'
notify_remote() { SSH_CONNECTION="$REMOTE" "$NOTIFY" "$@"; }
notify_local()  { env -u SSH_CONNECTION -u SSH_TTY "$NOTIFY" "$@"; }

T set-option -g @roost-notify-backend auto
T set-option -gu @roost-notify-cmd

# --- remote client, nothing configured: OSC 9 lands, byte for byte ---------
f="$(mktemp)"; fake_tty "$f"
notify_remote "roost · api" "blocked"
assert_eq "$(hexof "$f")" "$(hexpect '\033]9;roost · api — blocked\033\\')" \
  "a remote client gets OSC 9, terminated with ST, byte for byte"

# --- local client, nothing configured: nothing is written ------------------
f="$(mktemp)"; fake_tty "$f"
notify_local "roost · api" "blocked"
assert_eq "$(hexof "$f")" "" "a local client gets no escape sequence at all"

# --- @roost-notify-osc on forces it on for a local client -----------------
f="$(mktemp)"; fake_tty "$f"
T set-option -g @roost-notify-osc on
notify_local "t" "m"
assert_eq "$(hexof "$f")" "$(hexpect '\033]9;t — m\033\\')" \
  "@roost-notify-osc on emits for a local client too"

# --- @roost-notify-osc off silences it even for a remote client ------------
f="$(mktemp)"; fake_tty "$f"
T set-option -g @roost-notify-osc off
notify_remote "t" "m"
assert_eq "$(hexof "$f")" "" "@roost-notify-osc off wins over a remote client"
T set-option -gu @roost-notify-osc

# --- which codes: 9 by default, and any subset on request -----------------
# Ghostty 1.3.1 reads BOTH OSC 9 and OSC 777 as desktop notifications (its own
# built-in documentation for `desktop-notifications`, which defaults to true:
# "applications ... can show desktop notifications using certain escape
# sequences such as OSC 9 or OSC 777"), so emitting both raises two banners for
# one blocked agent. One code is the default; a terminal that needs a different
# one is told, not guessed.
f="$(mktemp)"; fake_tty "$f"
T set-option -g @roost-notify-osc-codes "9 777"
notify_remote "T" "M"
assert_eq "$(hexof "$f")" "$(hexpect '\033]9;T — M\033\\\033]777;notify;T;M\033\\')" \
  "codes \"9 777\" emits OSC 9 then OSC 777, both ST-terminated"

f="$(mktemp)"; fake_tty "$f"
T set-option -g @roost-notify-osc-codes "777"
notify_remote "T" "M"
assert_eq "$(hexof "$f")" "$(hexpect '\033]777;notify;T;M\033\\')" \
  "codes \"777\" emits the rxvt form only, title and body in their own fields"

f="$(mktemp)"; fake_tty "$f"
T set-option -g @roost-notify-osc-codes "99"
notify_remote "T" "M"
assert_eq "$(hexof "$f")" "$(hexpect '\033]99;i=roost:d=0:p=title;T\033\\\033]99;i=roost:d=1:p=body;M\033\\')" \
  "codes \"99\" emits the kitty two-chunk form, title then body"

f="$(mktemp)"; fake_tty "$f"
T set-option -g @roost-notify-osc-codes "9 bogus"
notify_remote "T" "M"
assert_eq "$(hexof "$f")" "$(hexpect '\033]9;T — M\033\\')" \
  "an unknown code is ignored rather than written out raw"
T set-option -gu @roost-notify-osc-codes

# --- a hostile payload must not escape the OSC string ---------------------
# An ESC, a BEL or a newline inside the payload terminates the sequence early,
# and everything after it is printed as garbage on the human's screen — issue
# #46's requirements 4 and 5. C0 controls become spaces; non-ASCII is passed
# through untouched (MEASURED through tmux 3.6: a UTF-8 payload arrives at the
# outer terminal byte for byte).
f="$(mktemp)"; fake_tty "$f"
notify_remote "$(printf 't\033[31mX')" "$(printf 'a\nb\ac"d\047e é')"
assert_eq "$(hexof "$f")" "$(hexpect '\033]9;t [31mX — a b c"d\047e é\033\\')" \
  "ESC, BEL and newline in the payload become spaces; quotes and UTF-8 survive"

# --- OSC 9;4 is a progress bar, not a notification ------------------------
# ConEmu's OSC 9;4 progress sequence shares OSC 9 with the notification form
# (Ghostty 1.3.1 documents both), so a payload that begins "4;" would drive a
# progress bar instead of raising a banner. A leading space is invisible in a
# notification and cannot be read as a subcommand number.
f="$(mktemp)"; fake_tty "$f"
notify_remote "4;50" "x"
assert_eq "$(hexof "$f")" "$(hexpect '\033]9; 4;50 — x\033\\')" \
  "a payload starting \"4;\" is shifted so OSC 9 cannot read it as progress"

# --- the existing chain is untouched --------------------------------------
# The OSC backend reaches the human's TERMINAL; every other backend reaches
# some machine's DESKTOP. They are not alternatives, so in auto mode the OSC
# write is additive and the rest of the chain still runs to its end.
f="$(mktemp)"; fake_tty "$f"
cmdout="$(mktemp)"
T set-option -g @roost-notify-cmd "printf \"%t|%s\" > $cmdout"
notify_remote "TITLE" "MSG"
assert_eq "$(cat "$cmdout")" "TITLE|MSG" "@roost-notify-cmd still runs with the OSC backend live"
assert_eq "$(hexof "$f")" "$(hexpect '\033]9;TITLE — MSG\033\\')" "and the OSC write happened as well"
T set-option -gu @roost-notify-cmd

# --- backend=osc selects it alone -----------------------------------------
f="$(mktemp)"; fake_tty "$f"
cmdout="$(mktemp)"; : > "$cmdout"
T set-option -g @roost-notify-backend osc
T set-option -g @roost-notify-cmd "printf ran > $cmdout"
marker="$(mktemp)"
with_path_shim osascript "$marker" -- with_path_shim notify-send "$marker" -- \
  notify_local "t" "m"
assert_eq "$(hexof "$f")" "$(hexpect '\033]9;t — m\033\\')" "backend=osc emits without asking whether the client is remote"
assert_eq "$(cat "$cmdout")" "" "backend=osc does not run @roost-notify-cmd"
assert_eq "$(cat "$marker")" "" "backend=osc invokes no OS notifier"
assert_eq "$("$NOTIFY" --which)" "osc" "--which reports osc"
T set-option -gu @roost-notify-cmd

# --- backend=none silences the OSC path too -------------------------------
f="$(mktemp)"; fake_tty "$f"
T set-option -g @roost-notify-backend none
notify_remote "t" "m"
assert_eq "$(hexof "$f")" "" "backend=none writes no escape sequence either"
T set-option -g @roost-notify-backend auto

# --- never fails: an unwritable tty is a miss, not an error ---------------
T set-option -g @roost-notify-osc-tty /nonexistent/dir/tty
notify_remote "t" "m"; rc=$?
assert_eq "$rc" "0" "an unwritable tty still exits 0"
T set-option -gu @roost-notify-osc-tty

# --- client discovery: a real attached client, over a pty -----------------
# The file-backed cases above cannot prove roost finds the terminal on its
# own. This attaches a real tmux client inside a pty we own and reads what
# that client writes toward its terminal — exactly what the emulator sees.
# python3 is already a CI dependency (tests/test-contrast.py), and the block
# is skipped rather than failed where it is absent, as tests/test-adapter-install.sh does.
if command -v python3 >/dev/null 2>&1; then
  capout="$(mktemp)"
  python3 - "$sock" "$NOTIFY" "$REMOTE" > "$capout" 2>&1 <<'PY'
import os, pty, subprocess, sys, threading, time
sock, notify, remote = sys.argv[1], sys.argv[2], sys.argv[3]
def tm(*a):
    return subprocess.run(["tmux","-S",sock,*a],capture_output=True,text=True)
master, slave = pty.openpty()
env = {k:v for k,v in os.environ.items() if k not in ("TMUX","TMUX_PANE")}
env["TERM"] = "xterm-256color"
# The client is what tmux copies SSH_CONNECTION from, so the remote marker
# goes in the CLIENT's environment, never in the notifier's.
env["SSH_CONNECTION"] = remote
cli = subprocess.Popen(["tmux","-S",sock,"attach","-t","0"],
                       stdin=slave, stdout=slave, stderr=slave,
                       start_new_session=True, env=env)
os.close(slave)
buf = bytearray()
def reader():
    while True:
        try:
            b = os.read(master, 65536)
        except OSError:
            return
        if not b: return
        buf.extend(b)
threading.Thread(target=reader, daemon=True).start()
time.sleep(2)
if tm("show-environment","-t","0","SSH_CONNECTION").stdout.strip() != "SSH_CONNECTION=" + remote:
    print("SKIP: tmux did not copy SSH_CONNECTION from the client"); sys.exit(0)
env2 = {k:v for k,v in os.environ.items() if k not in ("SSH_CONNECTION","SSH_TTY")}
env2["ROOST_NOTIFY_SOCK"] = sock
subprocess.run([notify, "roost · api", "blocked"], env=env2)
time.sleep(1)
tm("kill-server")
time.sleep(0.3)
want = b"\x1b]9;roost \xc2\xb7 api \xe2\x80\x94 blocked\x1b\\"
print("FOUND" if want in bytes(buf) else "MISSING")
PY
  got="$(tail -1 "$capout")"
  case "$got" in
    SKIP*) assert_true 0 "client discovery skipped: $got" ;;
    *)     assert_eq "$got" "FOUND" "an attached REMOTE client's tty is found and written to without any override" ;;
  esac
else
  assert_true 0 "client discovery over a pty skipped (python3 needed)"
fi
