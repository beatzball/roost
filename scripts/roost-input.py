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


def classify(harness, rows, x, y, borders):
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
            body[0] = body[0][2:]
        if any(s.strip() for s in body):
            return "occupied"
        # A cursor after spaces, on a continuation line, or inside a menu
        # does not prove an empty editor even if capture trimmed the spaces.
        want_x = 2 if harness == "claude" else 0
        return "empty" if y == top + 1 and x == want_x else "unknown"
    if harness == "codex":
        # Only the plain empty composer is proved. Placeholder text, menus,
        # clipped editors and a cursor below the marker are not guessed at.
        # In particular, a historic '›' in the transcript is not the editor.
        if rows[y].startswith("› "):
            if rows[y][2:].strip():
                return "occupied"
            # A blank line separates the composer from its shortcut footer.
            # Any continuation text, even BELOW a cursor moved to Home,
            # makes this a draft; no visible separator means unreadable.
            tail = rows[y + 1:]
            if not tail or tail[0].strip():
                return "unknown"
            # A blank continuation line is NOT necessarily the separator.
            # Account for every nonblank row down to the known footer, or
            # text below a blank line could be mistaken for empty input.
            footer = [s for s in tail[1:] if s.strip()]
            if not 1 <= len(footer) <= 2 or not re.fullmatch(
                    r"(?:← for agents · )?\? for shortcuts(?:\s.*)?", footer[-1].strip()):
                return "unknown"
            if len(footer) == 2 and not re.fullmatch(
                    r"  [A-Za-z0-9_.-]+ (?:low|medium|high|xhigh|max|default) · .+", footer[0]):
                return "unknown"
            return "empty" if x == 2 else "unknown"
        return "unknown"
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
        lines = r.stdout.decode("utf-8", "replace").split("\n")
        fields = lines[0].split("|")
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
        raw_rows = lines[1:]
        rows = [ANSI.sub("", s).rstrip() for s in raw_rows]
        # Claude Code 2.1.322 draws a non-breaking space after its marker
        # (measured in an isolated home). It separates the marker from text
        # just like an ordinary space; it is not itself a human draft.
        rows = ["❯ " + s[2:] if s.startswith("❯\u00a0") else s for s in rows]
        if harness == "codex" and int(sy) < len(raw_rows):
            # Measured on 0.167.2 in an isolated home: the default ghost
            # placeholder is DIM, while typed text is not. Matching words
            # alone would mistake a person typing that sentence for empty.
            ghost = "\x1b[1m›\x1b[0m \x1b[2mAsk Codex to do anything\x1b[0m"
            if raw_rows[int(sy)].rstrip() == ghost and int(sx) == 2:
                rows[int(sy)] = "› "
        # capture-pane strips trailing spaces, including the one after ❯/›.
        rows = [s + " " if s in ("❯", "›") else s for s in rows]
        borders = renderer_borders(harness, raw_rows, int(swidth))
        result = classify(harness, rows, int(sx), int(sy), borders)
        return result
    except (ValueError, IndexError, OSError, subprocess.SubprocessError):
        return "unknown"


if __name__ == "__main__":
    # Explicit flag and socket: never fall back to the production server.
    print(snapshot(["tmux", sys.argv[1], sys.argv[2]], sys.argv[3]))
