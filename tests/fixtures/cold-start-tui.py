#!/usr/bin/env python3
# Deterministic stand-in for the cold-start race: an agent TUI that is not
# reading its terminal yet when the pane already exists.
#
#   usage: cold-start-tui.py STARTUP_DELAY_SECONDS SUBMITTED_LINES_FILE
#
# The sequence it models, and each step matters:
#
#   1. Raw with echo OFF from the very first instant. A real TUI does not paint
#      keys it has not accepted, so anything typed during startup has to be
#      invisible as well as doomed. If this fixture echoed here, a screen-based
#      check would find the very bytes that are about to be destroyed and call
#      the delivery good — the fixture would hide the bug it exists to show.
#   2. A startup delay. This is the pane existing before the agent inside it
#      is ready, which is precisely the window `roost spawn` hands a caller.
#   3. tcflush(TCIFLUSH) at takeover. This is where the front of a message
#      stops existing. A TUI does it so it never acts on keys meant for the
#      shell it replaced; the cost is that a fast sender loses everything it
#      typed first, and the remainder arrives looking like a whole message.
#   4. Only then an input box: echo on, a prompt, C-u clears the line, Enter
#      submits. Submitted lines go to a FILE, never to the screen, so a test
#      cannot mistake text still sitting in the input box for a delivery.
#
# ICANON is off throughout, so there is no 1024-byte MAX_CANON ceiling of the
# fixture's own to be mistaken for one of roost's limits.
import os
import sys
import termios
import time
import tty

delay = float(sys.argv[1])
submitted_path = sys.argv[2]
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
out = sys.stdout
PROMPT = "ready> "

tty.setraw(fd)
try:
    time.sleep(delay)
    termios.tcflush(fd, termios.TCIFLUSH)
    tty.setcbreak(fd)                    # ICANON off, ECHO on: a drawn input box
    out.write(PROMPT)
    out.flush()
    line = []
    submitted = open(submitted_path, "a", buffering=1)
    while True:
        chunk = os.read(fd, 4096)
        if not chunk:
            break
        for ch in chunk.decode("utf-8", "replace"):
            if ch in ("\r", "\n"):
                submitted.write("".join(line) + "\n")
                line = []
                out.write("\r\n" + PROMPT)
            elif ch == "\x15":           # C-u — clear the input line
                line = []
                out.write("\r\x1b[K" + PROMPT)
            else:
                line.append(ch)
                out.write(ch)
        out.flush()
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
