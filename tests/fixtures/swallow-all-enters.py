#!/usr/bin/env python3
# A permanently stuck TUI: every \r/\n is discarded outright (not even
# swallowed-once like swallow-first-enter.py) and nothing is echoed for it,
# so the screen and cursor stay byte-identical to how they looked right
# after the typed text landed, no matter how many Enters arrive. Typed
# characters other than \r/\n are echoed back, same as a real input box.
#
# This is the "genuinely never submitted" case `send`'s retry loop and its
# final failure message exist for. It is used to pin the EXACT number of
# retries a given @amux-send-retries value expands to, by reading the
# "tried N extra Enter(s)" count straight out of that failure message —
# including normalized/clamped values like "007" -> 7, not just "some
# fallback happened".
import sys
import tty
import termios

fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
out = sys.stdout
# Readiness marker: printed only once tty.setraw() has actually taken effect,
# so a caller polling for it (rather than sleeping a fixed guess) can't start
# typing before raw mode is live and have the kernel echo/interpret \r itself.
out.write("READY\r\n")
out.flush()
try:
    while True:
        ch = sys.stdin.read(1)
        if not ch:
            break
        if ch in ("\r", "\n"):
            continue
        out.write(ch)
        out.flush()
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
