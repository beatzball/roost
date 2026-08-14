#!/usr/bin/env python3
# Deterministic stand-in for the live bug this task fixes: a full-screen TUI
# reading raw keystrokes that drops the very first Enter after a burst of
# typed text, leaving the text sitting in the input box unsubmitted.
#
# Echoes each typed character (mimicking a TUI's self-drawn input box), then
# discards exactly the first \r/\n it receives. A second Enter is treated as
# a real submit and prints a fixed marker — never the echoed text itself, so
# a test's wait-for-marker check can't be satisfied by the stuck input line.
import sys
import tty
import termios

fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
swallowed = False
out = sys.stdout
try:
    while True:
        ch = sys.stdin.read(1)
        if not ch:
            break
        if ch in ("\r", "\n"):
            if not swallowed:
                swallowed = True
                continue
            out.write("\r\nSUBMITTED-OK\r\n")
            out.flush()
            continue
        out.write(ch)
        out.flush()
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
