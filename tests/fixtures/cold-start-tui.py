#!/usr/bin/env python3
# Deterministic stand-in for the cold-start race: an agent TUI that is not
# reading its terminal yet when the pane already exists.
#
#   usage: cold-start-tui.py STARTUP_DELAY_SECONDS SUBMITTED_LINES_FILE [HEADCUT_BYTES]
#
# HEADCUT_BYTES models a SECOND, separate loss reported from the field and not
# explained by the startup race: two briefs of 3466 and 3502 bytes were cut at
# offsets 3067 and 3066 — mid-word, head discarded, tail kept, `roost send`
# exit 0 both times. The same 3502 bytes went through `send-keys -l` to a
# throwaway socket with a plain reader, and again with that reader asleep for
# five seconds, and 3501 of 3502 arrived both times. So tmux delivers it; the
# ceiling is above tmux and below the agent. A near-CONSTANT discarded prefix
# across two different message lengths is the signature of a fixed boundary
# rather than of a timing race, so it gets its own knob here rather than being
# folded into the startup delay.
#
# The discard is one-time: everything after the first HEADCUT_BYTES is kept.
# Whether the real ceiling repeats on a retyped message is NOT known and is not
# claimed here — see docs/airig/issues/2026-09-07-reply-channel-cutoff.md.
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
headcut = int(sys.argv[3]) if len(sys.argv) > 3 else 0
# COLLAPSE models the behaviour that made the fix look broken against a real
# agent: Claude Code renders a bracketed paste as a `[Pasted text #N]`
# placeholder instead of the text, so the message is nowhere on screen and any
# check that reads the screen for it can never match. The text is still
# submitted in full — the placeholder is a rendering, not a loss.
collapse = len(sys.argv) > 4 and sys.argv[4] == "collapse"
pastes = 0
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
out = sys.stdout
PROMPT = "ready> "

tty.setraw(fd)
try:
    time.sleep(delay)
    termios.tcflush(fd, termios.TCIFLUSH)
    tty.setcbreak(fd)                    # ICANON off, ECHO on: a drawn input box
    # Request bracketed paste (DECSET 2004), which is what a real TUI does when
    # it takes the terminal over. This is not decoration: tmux's `paste-buffer
    # -p` only wraps the text in \e[200~ / \e[201~ if the APPLICATION has asked
    # for bracketed paste. Without this line the markers never arrive, the
    # fixture sees ordinary typing, and a test written to exercise the paste
    # path silently exercises the old one instead — which is exactly what
    # happened the first time this test was run.
    out.write("\x1b[?2004h")
    out.write(PROMPT)
    out.flush()
    line = []
    submitted = open(submitted_path, "a", buffering=1)
    while True:
        chunk = os.read(fd, 4096)
        if not chunk:
            break
        if headcut > 0:
            # Drop bytes, not characters: the reported cut landed mid-word, and
            # a character-counted discard would silently be a different size.
            drop = min(headcut, len(chunk))
            chunk = chunk[drop:]
            headcut -= drop
            if not chunk:
                continue
        text = chunk.decode("utf-8", "replace")
        # Honour bracketed paste the way a real TUI does: the \e[200~ / \e[201~
        # markers say "one block of pasted text, not typing" and are consumed,
        # not shown. Without this they would be echoed into the input box and
        # written into the submitted line, and every assertion about what
        # arrived would be off by the length of two escape sequences.
        pasted = "\x1b[200~" in text
        text = text.replace("\x1b[200~", "").replace("\x1b[201~", "")
        if collapse and pasted:
            # Buffer the whole block, draw a placeholder, echo nothing of it.
            pastes += 1
            line.append(text)
            out.write("[Pasted text #%d]" % pastes)
            out.flush()
            continue
        for ch in text:
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
