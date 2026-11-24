#!/usr/bin/env python3
"""Editor with an external draft control and a byte receipt."""
import json
import os
import select
import subprocess
import sys
import termios
import tty
from pathlib import Path

path = sys.argv[1]
harness = os.environ.get("ROOST_TEST_INPUT_HARNESS")
if harness == "codex":
    ghost = json.loads(Path(__file__).with_name("codex-ghost.json").read_text())
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
line, carry, previous = "human draft", b"", None


def draw():
    width = os.get_terminal_size(fd).columns
    border = "\x1b[38;5;244m" + "─" * width + "\x1b[0m"
    # Large pastes may collapse. The receipt, rather than this screen, proves
    # that the existing transport delivered every byte exactly once.
    visible = "[Pasted text #1]" if len(line) > 1000 else line
    if harness == "codex":
        row = "› " + visible if visible else ghost
        screen = row + "\x1b[0m\r\n\r\n? for shortcuts"
        cursor = "1;"
    else:
        row = "❯ " + visible
        if harness == "claude" and not visible:
            row += '\x1b[2mTry "create a util logging.py that…"\x1b[0m'
        screen = border + "\r\n" + row + "\r\n" + border
        cursor = "2;"
    sys.stdout.write("\x1b[2J\x1b[H" + screen + "\x1b[" + cursor + str(len(visible) + 3) + "H")
    sys.stdout.flush()


try:
    if os.environ.get("ROOST_TEST_INPUT_BRACKETS") != "0":
        sys.stdout.write("\x1b[?2004h")
    while True:
        control = open(path + ".draft").read()
        if control != previous:
            line, previous = control, control
            draw()
        if not select.select([fd], [], [], 0.05)[0]:
            continue
        raw = os.read(fd, 65536)
        with open(path + ".keys", "ab") as receipt:
            receipt.write(raw)
        carry += raw
        # Bracketed paste is one block; its embedded newlines are text.
        while carry:
            if carry.startswith(b"\x1b[200~"):
                end = carry.find(b"\x1b[201~")
                if end < 0:
                    break
                line += carry[6:end].decode().replace("\r", "\n")
                carry = carry[end + 6:]
            elif carry[0] == 27 and len(carry) < 6:
                break
            else:
                ch, carry = carry[:1], carry[1:]
                if ch == b"\x15":
                    line = ""
                elif ch in (b"\r", b"\n"):
                    with open(path, "a") as receipt:
                        receipt.write(json.dumps(line) + "\n")
                    if len(sys.argv) > 2:
                        # Optional real hooks let the receipts and turn records
                        # independently prove which prompt this fixture ran.
                        subprocess.run([sys.argv[2], "working"], stdin=subprocess.DEVNULL, check=True)
                        subprocess.run([sys.argv[2], "done", "--stop-hook"], input=json.dumps(
                            {"last_assistant_message": "REPLY-TO[" + line + "]"}).encode(), check=True)
                    line = ""
                else:
                    line += ch.decode()
            draw()
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
