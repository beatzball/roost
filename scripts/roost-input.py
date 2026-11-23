#!/usr/bin/env python3
"""Read a visible composer. Unknown renderers pass through the initial gate.

The screen is evidence about an editor, not about the agent's working badge.
An empty cursor line alone is insufficient: a multiline draft can have its
cursor on an empty line, or at Home before the text. Never inspect scrollback.
"""
import re
import subprocess
import sys

ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
SGR = re.compile(r"\x1b\[([0-9;]*)m")


def renderer_borders(harness, raw_rows, width):
    """Only renderer-colored, full-pane rules can delimit an editor.

    Pi reserves a column for its cursor; Claude indents input by two columns.
    Human rules therefore cannot fill a renderer rule's full width. Color is
    checked as well: Pi's measured muted borders are dim, Claude's are fg244.
    Themes/styles that do not match these measured renderings are unreadable.
    """
    dim, fg = False, None
    borders = []
    for row_no, raw in enumerate(raw_rows):
        visible, proof, offset = "", True, 0
        for match in ANSI.finditer(raw):
            chunk = raw[offset:match.start()]
            visible += chunk
            if chunk and not (dim if harness == "pi" else fg == 244):
                proof = False
            seq = match.group()
            if seq.endswith("m"):
                params = [int(v or 0) for v in seq[2:-1].split(";")]
                i = 0
                while i < len(params):
                    v = params[i]
                    if v == 0: dim, fg = False, None
                    elif v == 2: dim = True
                    elif v == 22: dim = False
                    elif v == 39: fg = None
                    elif v == 38 and params[i + 1:i + 2] == [5] and i + 2 < len(params):
                        fg = params[i + 2]; i += 2
                    elif v == 38 and params[i + 1:i + 2] == [2]:
                        fg = None; i += 4
                    elif 30 <= v <= 37 or 90 <= v <= 97: fg = v
                    i += 1
            offset = match.end()
        chunk = raw[offset:]
        visible += chunk
        if chunk and not (dim if harness == "pi" else fg == 244): proof = False
        if proof and width and visible == "─" * width:
            borders.append(row_no)
    return borders


def sgr_dim(sgr, dim):
    params = iter(int(value or 0) for value in sgr.split(";"))
    for attr in params:
        if attr in (38, 48, 58):
            # RGB channels and palette indices can have the same numbers as
            # SGR attributes. Consume the color payload before reading more.
            mode = next(params, None)
            if mode not in (2, 5):
                raise ValueError("unsupported SGR color mode")
            for _ in range(3 if mode == 2 else 1):
                if not 0 <= next(params, -1) <= 255:
                    raise ValueError("invalid SGR color payload")
        elif attr == 2:
            dim = True
        elif attr in (0, 22):
            dim = False
    return dim


def input_row(raw, dim):
    parts = SGR.split(raw)
    chunks = parts[::2]
    if any("\x1b" in chunk for chunk in chunks):
        raise ValueError("unsupported input escape sequence")
    non_dim = []
    for chunk, sgr in zip(chunks, parts[1::2] + [None]):
        # Dim runs keep their character positions so the marker is always excluded.
        non_dim.append(" " * len(chunk) if dim else chunk)
        if sgr is not None:
            dim = sgr_dim(sgr, dim)
    return "".join(chunks), "".join(non_dim), dim


def codex_input(raw_rows, y):
    if not 0 <= y < len(raw_rows):
        return "unknown"
    # Inspect text only on the cursor's marker row. A marker in the transcript
    # or a cursor below the marker cannot establish that the composer is occupied.
    # tmux can carry SGR across a full-width row, so reconstruct the style from
    # the start of the capture even though earlier text is not draft evidence.
    dim = False
    for raw in raw_rows[:y + 1]:
        visible, non_dim, dim = input_row(raw.decode("utf-8"), dim)
    # Codex 0.167.2 draws its ghost text in DIM. Use the cell styling even
    # when the hint is clipped or changed, and when a draft's cursor is at Home.
    if visible.startswith("› ") and non_dim[2:].strip():
        return "occupied"
    return "unknown"


def classify(harness, rows, x, y, borders, draft_rows=None):
    if not 0 <= y < len(rows):
        return "unknown"
    if harness in ("claude", "pi"):
        # Claude's composer and pi's editor are enclosed by horizontal rules.
        # pi's editor.js render() puts scroll indicators IN those rules: a
        # rule with an arrow/count deliberately fails this pattern, because
        # offscreen draft text cannot be proved empty.
        # A draft may contain short OR full-width rules. Only rules proved
        # by the raw renderer attributes, width and margins are candidates.
        trusted = borders or []
        top = next((i for i in range(y - 1, -1, -1) if i in trusted), None)
        bottom = next((i for i in range(y + 1, len(rows)) if i in trusted), None)
        if top is None or bottom is None:
            return "unknown"
        body = rows[top + 1:bottom]
        if harness == "claude":
            if not body or not body[0].startswith("❯ "):
                return "unknown"
            if draft_rows is not None:
                body = draft_rows[top + 1:bottom]
            body[0] = body[0][2:]
        if any(s.strip() for s in body):
            return "occupied"
        # A cursor after spaces, on a continuation line, or inside a menu
        # does not prove an empty editor even if capture trimmed the spaces.
        want_x = 2 if harness == "claude" else 0
        return "empty" if y == top + 1 and x == want_x else "unknown"
    return "unknown"


def snapshot(tmux, pane):
    fmt = "#{pane_id}|#{pane_dead}|#{pane_in_mode}|#{cursor_x}|#{cursor_y}|#{pane_current_command}|#{@roost-harness}|#{@roost-name}|#{pane_pid}|#{pane_width}|#{@agent_state}"
    try:
        r = subprocess.run(tmux + ["display-message", "-p", "-t", pane, fmt,
                                  ";", "capture-pane", "-p", "-e", "-t", pane],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5)
        # Only LF separates terminal rows. str.splitlines() also splits a
        # person's literal Unicode line-separator characters, shifting the
        # cursor index onto a different row and potentially hiding a draft.
        lines = r.stdout.split(b"\n")
        fields = lines[0].decode("utf-8", "replace").split("|")
        ident, dead, in_mode, sx, sy, command, harness, name, pid, swidth, state = fields
        if r.returncode or ident != pane or dead != "0":
            return "unknown"
        if in_mode != "0":
            return "unknown"
        # Identity options survive an agent leaving its shell. Prefer a
        # proved bare foreground shell over that stale harness name. A sh
        # tool running inside an agent is NOT that shell: its pane process
        # either has script arguments or does not own the foreground group.
        if command.lstrip("-") in ("sh", "bash", "dash", "zsh", "ksh", "fish"):
            args = subprocess.check_output(["ps", "-o", "args=", "-p", pid], timeout=5).decode().split()
            foreground = subprocess.check_output(["ps", "-o", "tpgid=", "-p", pid], timeout=5).decode().strip()
            if foreground == pid and args and all(a.startswith("-") and a not in ("-c", "-s") for a in args[1:]):
                harness = "shell"
        if not harness:
            if command in ("claude", "codex", "opencode", "copilot", "pi"):
                harness = command
            elif re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", command):
                harness = "claude"
            elif name in ("claude", "codex", "opencode", "copilot", "pi"):
                harness = name
        x, y, width = int(sx), int(sy), int(swidth)
        if harness == "codex":
            return codex_input(lines[1:], y)
        raw_rows = [line.decode("utf-8", "replace") for line in lines[1:]]
        rows = [ANSI.sub("", s).rstrip() for s in raw_rows]
        # Claude Code 2.1.322 draws a non-breaking space after its marker
        # (measured in an isolated home). It separates the marker from text
        # just like an ordinary space; it is not itself a human draft.
        rows = ["❯ " + s[2:] if s.startswith("❯\u00a0") else s for s in rows]
        # capture-pane strips trailing spaces, including the one after ❯.
        rows = [s + " " if s == "❯" else s for s in rows]
        borders = renderer_borders(harness, raw_rows, width)
        draft_rows = None
        if harness == "claude":
            # Claude Code 2.1.330 shows `❯ ESC[2mTry "create a util logging.py
            # that…"ESC[0m` in the measured empty editor row (#258).
            draft_rows = []
            dim = False
            for raw, visible in zip(raw_rows, rows):
                try:
                    _, non_dim, dim = input_row(raw, dim)
                except ValueError:
                    # With uncertain styling, keep visible text as draft evidence.
                    non_dim, dim = visible, False
                draft_rows.append(non_dim)
        result = classify(harness, rows, x, y, borders, draft_rows)
        return result
    except (ValueError, IndexError, OSError, subprocess.SubprocessError):
        return "unknown"


if __name__ == "__main__":
    # Explicit flag and socket: never fall back to the production server.
    print(snapshot(["tmux", sys.argv[1], sys.argv[2]], sys.argv[3]))
