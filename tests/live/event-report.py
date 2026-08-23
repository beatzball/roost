#!/usr/bin/env python3
"""Read a tests/live/event-log.js log and answer one question about it.

    event-report.py summary   LOG   # session tree + the events the adapter maps
    event-report.py subagent  LOG   # exit 0 iff a child idled before its parent
    event-report.py childperm LOG   # exit 0 iff a child asked for permission
    event-report.py attempts  LOG   # one line per turn: the retry attempt numbers

Separate from the shell test because the interleaving question is about the
ORDER of events across sessions, and a grep cannot see order across two ids.
The shell asserts on badges; this asserts on the stream that produced them.
"""
import json
import sys

# The events the adapter maps, plus session.created, which is the only place a
# parentID shows up before the child starts emitting status.
MAPPED = (
    "session.status",
    "session.idle",
    "session.error",
    "permission.asked",
    "permission.replied",
    "session.created",
)


def load(path):
    """Return (rows, parents) — rows are (ms since the first mapped event, type,
    sessionID, detail); parents maps every session id seen to its parentID."""
    parents, titles, rows, t0 = {}, {}, [], None
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                # A killed process can leave a half-written last line. It is the
                # only line that can be broken, and dropping it beats refusing
                # to report on the whole run.
                continue
            event = rec.get("event") or {}
            kind = event.get("type")
            props = event.get("properties") or {}
            info = props.get("info") or {}
            # session.* info is a session (its id IS a session id and it may
            # carry parentID); message.* info is a message. Only the first kind
            # tells us anything about the session tree.
            if kind in ("session.created", "session.updated") and info.get("id"):
                parents[info["id"]] = info.get("parentID")
                titles[info["id"]] = info.get("title") or ""
            if kind not in MAPPED:
                continue
            if t0 is None:
                t0 = rec["t"]
            detail = ""
            if kind == "session.status":
                detail = json.dumps(props.get("status") or {})
            elif kind == "session.error":
                detail = json.dumps(props.get("error") or {})[:100]
            rows.append((rec["t"] - t0, kind, props.get("sessionID") or info.get("id") or "?", detail))
    return rows, parents, titles


def summary(path):
    rows, parents, titles = load(path)
    print("    -- sessions --")
    for sid, parent in parents.items():
        kind = "child of %s" % parent if parent else "root"
        print("    %s  %s  %r" % (sid, kind, titles.get(sid, "")[:44]))
    print("    -- events --")
    for ms, kind, sid, detail in rows:
        print("    %7dms  %s  %-18s %s" % (ms, sid[-6:], kind, detail))
    return 0


def subagent(path):
    """Did a child session go idle while its parent's turn was still running?

    That is the whole hazard: unfiltered, the child's idle is what stamps
    `done` on a pane whose real turn has not finished.
    """
    rows, parents, _ = load(path)
    children = [s for s, p in parents.items() if p]
    if not children:
        print("    no child session in the log — the model never called the task tool")
        return 2
    idles = {}
    for ms, kind, sid, _ in rows:
        if kind == "session.idle" and sid not in idles:
            idles[sid] = ms
    for child in children:
        parent = parents[child]
        if child in idles and parent in idles and idles[child] < idles[parent]:
            print("    child %s idled at %dms, parent %s only at %dms (%dms window)"
                  % (child[-6:], idles[child], parent[-6:], idles[parent],
                     idles[parent] - idles[child]))
            return 0
    print("    a child session ran, but none idled before its parent")
    return 1


def childperm(path):
    """Did a child session ask for permission?

    The mirror of `subagent`: a child's start and end are not the pane's, but
    its permission dialog IS -- the human answering it is sitting at this pane.
    The adapter must drop the first and keep the second, so a run that proves
    one should prove the other.
    """
    rows, parents, _ = load(path)
    for _, kind, sid, _ in rows:
        if kind == "permission.asked" and parents.get(sid):
            print("    child %s asked for permission (parent %s)" % (sid[-6:], parents[sid][-6:]))
            return 0
    print("    no permission.asked from a child session")
    return 1


def attempts(path):
    """Print the retry attempt numbers per turn, per session.

    A turn ends at session.idle or session.error. Whether the numbering starts
    again at 1 in the next turn is the question: our own counter resets at those
    same boundaries, so upstream's attempt can only replace it if it does too.
    """
    rows, _, _ = load(path)
    turn, seen = {}, False
    for _, kind, sid, detail in rows:
        if kind == "session.status" and detail:
            status = json.loads(detail)
            if status.get("type") == "retry":
                turn.setdefault(sid, []).append(status.get("attempt"))
                seen = True
        elif kind in ("session.idle", "session.error"):
            if turn.get(sid):
                print("    %s turn ended: attempts %s" % (sid[-6:], turn[sid]))
                turn[sid] = []
    for sid, got in turn.items():
        if got:
            print("    %s turn unfinished: attempts %s" % (sid[-6:], got))
    if not seen:
        print("    no retry status in the log")
        return 1
    return 0


MODES = {"summary": summary, "subagent": subagent, "childperm": childperm, "attempts": attempts}

if len(sys.argv) != 3 or sys.argv[1] not in MODES:
    print(__doc__)
    sys.exit(64)
sys.exit(MODES[sys.argv[1]](sys.argv[2]))
