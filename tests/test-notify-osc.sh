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
#
# Two kinds of case live here, and the split matters:
#
#   * byte-exact cases, which use @roost-notify-osc-tty to aim the write at a
#     plain file and @roost-notify-osc on to take the "is anyone remote"
#     question out of the picture;
#   * DECISION cases, which attach REAL clients through ptys, because who gets
#     written to is decided from tmux's own view of its clients and nothing
#     else. A review found the first round's decision cases were all reachable
#     through the notifier's own environment instead, which is why a
#     separator bug in the client-list parser survived to a commit.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
NOTIFY="$HERE/scripts/roost-notify"

roost_test_server; sock="$ROOST_TEST_SOCK"; trap roost_test_teardown EXIT
export ROOST_NOTIFY_SOCK="$ROOST_TEST_SOCK"

# A plain file stands in for a client tty. The backend only ever opens the path
# it is given and writes to it, so a file exercises the identical code path and
# lets the test compare bytes.
fake_tty() { : > "$1"; T set-option -g @roost-notify-osc-tty "$1"; }

hexof() { od -An -tx1 -v < "$1" | tr -d ' \n'; }
# hex of the same bytes built independently, so the expectation is spelled as
# the sequence itself rather than as a copy of whatever the script produced.
hexpect() { printf '%b' "$1" | od -An -tx1 -v | tr -d ' \n'; }

# A skipped case prints SKIP, never PASS. tests/run.sh counts only lines
# starting "  PASS" and "  FAIL", so this is visible in the output and counts
# as neither — where `assert_true 0 "...skipped..."` would have banked a PASS
# for a case that never ran, which is how the first round hid the fact that
# client discovery was only ever exercised on one platform.
skip() { printf '  SKIP: %s\n' "$1"; }

# SSH_CONNECTION is how tmux itself reports a remote client: it is in tmux's
# DEFAULT update-environment list (MEASURED on tmux 3.6:
# "DISPLAY KRB5CCNAME MSYSTEM SSH_ASKPASS SSH_AUTH_SOCK SSH_AGENT_PID
# SSH_CONNECTION WINDOWID XAUTHORITY"), so tmux copies it from the attaching
# client into that session's environment, and removes it again when a local
# client attaches. SSH_TTY is NOT in that list, which is why nothing here may
# rest on SSH_TTY alone.
REMOTE='10.0.0.2 51000 10.0.0.1 22'
# The notifier's OWN environment must never decide anything: it runs in an
# agent's pane, and a pane keeps SSH_CONNECTION for life once the server (or
# the window) was created over ssh, long after the human came back to the
# machine. Several cases below deliberately run WITH it set to prove it is
# ignored.
notify()     { env -u SSH_CONNECTION -u SSH_TTY "$NOTIFY" "$@"; }
notify_env() { SSH_CONNECTION="$REMOTE" "$NOTIFY" "$@"; }

T set-option -g @roost-notify-backend auto
T set-option -gu @roost-notify-cmd

# =========================================================================
# Byte-exact cases — @roost-notify-osc on, writing into a file
# =========================================================================
T set-option -g @roost-notify-osc on

f="$(mktemp)"; fake_tty "$f"
notify "roost · api" "blocked"
assert_eq "$(hexof "$f")" "$(hexpect '\033]9;roost · api — blocked\033\\')" \
  "OSC 9 by default, terminated with ST, byte for byte"

f="$(mktemp)"; fake_tty "$f"
T set-option -g @roost-notify-osc-codes "9 777"
notify "T" "M"
assert_eq "$(hexof "$f")" "$(hexpect '\033]9;T — M\033\\\033]777;notify;T;M\033\\')" \
  "codes \"9 777\" emits OSC 9 then OSC 777, both ST-terminated"

f="$(mktemp)"; fake_tty "$f"
T set-option -g @roost-notify-osc-codes "777"
notify "T" "M"
assert_eq "$(hexof "$f")" "$(hexpect '\033]777;notify;T;M\033\\')" \
  "codes \"777\" emits the rxvt form only, title and body in their own fields"

# OSC 777's fields are delimited by ";", so a ";" in the title or the body
# shifts every field after it: "a;b" as a title makes "b" the body and drops
# the real one. OSC 9 has no such problem — its payload is everything after the
# first ";" — so the rewrite is applied to the 777 form ONLY, where leaving the
# text alone would mean showing the wrong text.
f="$(mktemp)"; fake_tty "$f"
notify "a;b" "c;d"
assert_eq "$(hexof "$f")" "$(hexpect '\033]777;notify;a,b;c,d\033\\')" \
  "a semicolon in the title or body cannot shift OSC 777's fields"

f="$(mktemp)"; fake_tty "$f"
T set-option -g @roost-notify-osc-codes "9"
notify "a;b" "c;d"
assert_eq "$(hexof "$f")" "$(hexpect '\033]9;a;b — c;d\033\\')" \
  "...and OSC 9, which has no fields to shift, keeps the semicolons"

f="$(mktemp)"; fake_tty "$f"
T set-option -g @roost-notify-osc-codes "99"
notify "T" "M"
assert_eq "$(hexof "$f")" "$(hexpect '\033]99;i=roost:d=0:p=title;T\033\\\033]99;i=roost:d=1:p=body;M\033\\')" \
  "codes \"99\" emits the kitty two-chunk form, title then body"

f="$(mktemp)"; fake_tty "$f"
T set-option -g @roost-notify-osc-codes "9 bogus"
notify "T" "M"
assert_eq "$(hexof "$f")" "$(hexpect '\033]9;T — M\033\\')" \
  "an unknown code is ignored rather than written out raw"
T set-option -gu @roost-notify-osc-codes

# An ESC, a BEL or a newline inside the payload terminates the sequence early,
# and everything after it is printed as garbage on the human's screen — #46's
# requirements 4 and 5. C0 controls and DEL become spaces; non-ASCII is passed
# through untouched (MEASURED through tmux 3.6: a UTF-8 payload arrives at the
# outer terminal byte for byte).
f="$(mktemp)"; fake_tty "$f"
notify "$(printf 't\033[31mX')" "$(printf 'a\nb\ac"d\047e é')"
assert_eq "$(hexof "$f")" "$(hexpect '\033]9;t [31mX — a b c"d\047e é\033\\')" \
  "ESC, BEL and newline in the payload become spaces; quotes and UTF-8 survive"

# C1 controls (U+0080-U+009F) matter because a lone U+009C can be read as an
# 8-bit ST and end the OSC string early. In UTF-8 those are the TWO-byte
# sequences C2 80 .. C2 9F, and it is only ever those that may be removed:
# deleting the bare bytes 0x80-0x9F instead eats the second byte of every
# character that contains one. U+0142 'ł' is C5 82, and this case pins that it
# survives whole — MEASURED, the naive byte strip turns "a<C2 9B>b ł c" into
# "a<C2> b<C5> c", destroying both.
f="$(mktemp)"; fake_tty "$f"
notify "$(printf 'a\302\233b')" "$(printf '\305\202\302\237z')"
assert_eq "$(hexof "$f")" "$(hexpect '\033]9;a b — \0305\0202 z\033\\')" \
  "a C1 control becomes a space while a character whose UTF-8 contains 0x82 survives"

# ConEmu's progress-bar sequence is OSC 9;4 — the same OSC 9, told apart only
# by a leading "4;". A payload that begins "4;" would drive a progress bar
# instead of raising a banner.
f="$(mktemp)"; fake_tty "$f"
notify "4;50" "x"
assert_eq "$(hexof "$f")" "$(hexpect '\033]9; 4;50 — x\033\\')" \
  "a payload starting \"4;\" is shifted so OSC 9 cannot read it as progress"

# The OSC backend reaches the human's TERMINAL; every other backend reaches
# some machine's DESKTOP. They are not alternatives, so in auto mode the OSC
# write is additive and the rest of the chain still runs to its end.
f="$(mktemp)"; fake_tty "$f"
cmdout="$(mktemp)"
T set-option -g @roost-notify-cmd "printf \"%t|%s\" > $cmdout"
notify "TITLE" "MSG"
assert_eq "$(cat "$cmdout")" "TITLE|MSG" "@roost-notify-cmd still runs with the OSC backend live"
assert_eq "$(hexof "$f")" "$(hexpect '\033]9;TITLE — MSG\033\\')" "and the OSC write happened as well"
T set-option -gu @roost-notify-cmd

# --- the option gates ------------------------------------------------------
f="$(mktemp)"; fake_tty "$f"
T set-option -g @roost-notify-osc off
notify_env "t" "m"
assert_eq "$(hexof "$f")" "" "@roost-notify-osc off writes nothing"
T set-option -g @roost-notify-osc on

f="$(mktemp)"; fake_tty "$f"
cmdout="$(mktemp)"; : > "$cmdout"
T set-option -g @roost-notify-backend osc
T set-option -g @roost-notify-cmd "printf ran > $cmdout"
marker="$(mktemp)"
with_path_shim osascript "$marker" -- with_path_shim notify-send "$marker" -- \
  notify "t" "m"
assert_eq "$(hexof "$f")" "$(hexpect '\033]9;t — m\033\\')" "backend=osc emits on its own"
assert_eq "$(cat "$cmdout")" "" "backend=osc does not run @roost-notify-cmd"
assert_eq "$(cat "$marker")" "" "backend=osc invokes no OS notifier"
assert_eq "$("$NOTIFY" --which)" "osc" "--which reports osc"
T set-option -gu @roost-notify-cmd

f="$(mktemp)"; fake_tty "$f"
T set-option -g @roost-notify-backend none
notify_env "t" "m"
assert_eq "$(hexof "$f")" "" "backend=none writes no escape sequence either"
T set-option -g @roost-notify-backend auto

# Never fails, like every other backend: an unwritable tty is a miss.
T set-option -g @roost-notify-osc-tty /nonexistent/dir/tty
notify "t" "m"; rc=$?
assert_eq "$rc" "0" "an unwritable tty still exits 0"

# =========================================================================
# Decision cases — real clients, attached through ptys
# =========================================================================
# In auto mode nothing but tmux's own view of its clients may decide who is
# written to. These cases attach real clients and read what each one's terminal
# receives.
T set-option -gu @roost-notify-osc
T set-option -gu @roost-notify-osc-tty

if command -v python3 >/dev/null 2>&1; then
  pyf="$(mktemp)"
  cat > "$pyf" <<'PYEOF'
# Attach real clients through ptys and read what each one's terminal receives.
# A pty is the only honest stand-in for a terminal emulator here: tmux writes
# to the slave, and what we read off the master is exactly what the emulator
# would have parsed.
import errno, fcntl, os, pty, subprocess, sys, threading, time

sock, notify, remote = sys.argv[1], sys.argv[2], sys.argv[3]
WANT = b"\x1b]9;roost \xc2\xb7 api \xe2\x80\x94 blocked\x1b\\"

def tm(*a):
    return subprocess.run(["tmux", "-S", sock, *a], capture_output=True, text=True)

def clean_env(extra=None):
    e = {k: v for k, v in os.environ.items()
         if k not in ("TMUX", "TMUX_PANE", "SSH_CONNECTION", "SSH_TTY")}
    e["TERM"] = "xterm-256color"
    if extra:
        e.update(extra)
    return e

def attach(session, control=False, env_extra=None):
    """A session with one client on a pty we own. Returns (master fd, buffer)."""
    tm("new-session", "-d", "-s", session, "-x", "80", "-y", "24", "ENV= exec /bin/sh")
    master, slave = pty.openpty()
    args = ["tmux", "-S", sock] + (["-CC"] if control else []) + ["attach", "-t", session]
    subprocess.Popen(args, stdin=slave, stdout=slave, stderr=slave,
                     start_new_session=True, env=clean_env(env_extra))
    os.close(slave)
    buf = bytearray()
    def reader():
        while True:
            try:
                b = os.read(master, 65536)
            except OSError:
                return
            if not b:
                return
            buf.extend(b)
    threading.Thread(target=reader, daemon=True).start()
    # Poll for the client rather than sleeping a fixed time: a sleep decides
    # the result on a slow machine, and the case it decides in favour of is
    # "skipped", which is the one nobody reads.
    t0 = time.time()
    while time.time() - t0 < 10:
        if session in tm("list-clients", "-F", "#{client_session}").stdout.split():
            return master, buf
        time.sleep(0.1)
    return master, buf

def attached(session):
    return session in tm("list-clients", "-F", "#{client_session}").stdout.split()

# One session per client: SSH_CONNECTION lands in the SESSION environment, so
# two clients sharing a session could never differ, and each attach would
# overwrite what the previous one proved.
rem_m, rem_buf = attach("rem", env_extra={"SSH_CONNECTION": remote})
loc_m, loc_buf = attach("loc")
cc_m,  cc_buf  = attach("cc", control=True, env_extra={"SSH_CONNECTION": remote})

skips = {}
if not attached("rem"):
    skips["remote_client"] = "SKIP no client attached to the remote session"
if not attached("loc"):
    skips["local_client"] = "SKIP no client attached to the local session"
if not attached("cc"):
    skips["control_client"] = "SKIP no control-mode client attached"
if tm("show-environment", "-t", "rem", "SSH_CONNECTION").stdout.strip() != "SSH_CONNECTION=" + remote:
    skips["remote_client"] = "SKIP tmux did not copy SSH_CONNECTION from the client"
# A control-mode client that tmux does not report as one cannot be skipped by
# the code under test either; say so rather than assert something else.
cc_flags = tm("list-clients", "-F", "#{client_session} #{client_control_mode} #{client_flags}").stdout
print("NOTE clients:", " | ".join(cc_flags.split("\n")).strip())
if not any(l.startswith("cc ") and (l.split()[1] == "1" or "control-mode" in l)
           for l in cc_flags.splitlines()):
    skips["control_client"] = "SKIP this tmux does not report a control-mode client"

# The notifier's own environment says "remote" and must be ignored: only
# tmux's view of each client may decide.
subprocess.run([notify, "roost · api", "blocked"],
               env={**clean_env({"SSH_CONNECTION": remote}), "ROOST_NOTIFY_SOCK": sock})

# Poll for the bytes instead of sleeping: the remote client is the one case
# where something IS expected, so wait for it and then judge the others.
t0 = time.time()
while time.time() - t0 < 5 and WANT not in bytes(rem_buf):
    time.sleep(0.1)
time.sleep(0.5)   # give a wrong write to the other two time to show up

def verdict(name, buf, want_bytes):
    if name in skips:
        return skips[name]
    raw = bytes(buf)
    if want_bytes:
        return "EXACT" if WANT in raw else "MISSING"
    return "EMPTY" if b"\x1b]9;" not in raw else "WRITTEN"

print("remote_client", verdict("remote_client", rem_buf, True))
print("local_client", verdict("local_client", loc_buf, False))
print("control_client", verdict("control_client", cc_buf, False))

# --- the write must be bounded ------------------------------------------
# A terminal that has stopped reading (laptop asleep, wifi gone, sshd not
# draining the pty) fills the pty buffer, and the next write to it blocks for
# ever. This runs inside the harness's hook, so "for ever" is the agent's turn
# hanging. Fill a pty, read nothing from it, and time the notifier.
m, s = pty.openpty()
fl = fcntl.fcntl(s, fcntl.F_GETFL)
fcntl.fcntl(s, fcntl.F_SETFL, fl | os.O_NONBLOCK)
filled = 0
try:
    while filled < 8 * 1024 * 1024:
        filled += os.write(s, b"x" * 4096)
except OSError as e:
    if e.errno not in (errno.EAGAIN, errno.EWOULDBLOCK):
        raise
fcntl.fcntl(s, fcntl.F_SETFL, fl)
stuck = os.ttyname(s)
tm("set-option", "-g", "@roost-notify-osc", "on")
tm("set-option", "-g", "@roost-notify-osc-tty", stuck)
t0 = time.time()
try:
    subprocess.run([notify, "t", "m"], timeout=8,
                   env={**clean_env(), "ROOST_NOTIFY_SOCK": sock})
    dt = time.time() - t0
    print("bounded_write %s %.1fs" % ("RETURNED" if dt <= 5 else "SLOW", dt))
except subprocess.TimeoutExpired:
    print("bounded_write HUNG (still running after 8s), filled %d bytes" % filled)
tm("set-option", "-gu", "@roost-notify-osc")
tm("set-option", "-gu", "@roost-notify-osc-tty")
# Closing the master unblocks anything still stuck writing to the slave (the
# write then fails with EIO), so nothing is left behind holding a pty.
os.close(m); os.close(s)
PYEOF
  out="$(python3 "$pyf" "$sock" "$NOTIFY" "$REMOTE" 2>&1)"
  printf '%s\n' "$out" | grep -q '^NOTE' && printf '%s\n' "$out" | grep '^NOTE'
  verdict() { printf '%s\n' "$out" | grep "^$1 " | head -1 | cut -d' ' -f2-; }
  v="$(verdict remote_client)"
  case "$v" in
    SKIP*) skip "a remote client's terminal gets the exact bytes — $v" ;;
    *)     assert_eq "$v" "EXACT" "a remote client's terminal gets the exact bytes, found by discovery alone" ;;
  esac
  v="$(verdict local_client)"
  case "$v" in
    SKIP*) skip "a local client is left alone — $v" ;;
    *)     assert_eq "$v" "EMPTY" "a local client is left alone even when the NOTIFIER's own env has SSH_CONNECTION" ;;
  esac
  v="$(verdict control_client)"
  case "$v" in
    SKIP*) skip "a control-mode client is skipped — $v" ;;
    *)     assert_eq "$v" "EMPTY" "a control-mode (-CC) client is skipped, remote session or not" ;;
  esac
  v="$(verdict bounded_write)"
  case "$v" in
    SKIP*) skip "the write is bounded — $v" ;;
    *)     assert_prefix "$v" "RETURNED" "a terminal that has stopped reading cannot hang the hook" ;;
  esac
else
  skip "decision cases need python3 to attach a client through a pty"
fi
