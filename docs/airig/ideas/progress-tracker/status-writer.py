#!/usr/bin/env python3
"""Write a plan-level progress doc for the roost rename.

Task state is derived from git, not from anything I assert: a task is done when
its plan-specified commit subject appears in the branch log. That makes the doc
impossible to drift from reality — if a task is skipped, it shows as pending
whether or not anyone noticed.

Subtask state (the numbered `**Do:**` steps inside the one task currently in
flight) follows the same rule, one level down: a step is only ever marked done
on the strength of a structural check — a git rename record, a symlink whose
target matches, a path that exists or is absent as the step demands. There is
no general parser for prose steps ("update the README throughout"), and a step
we cannot derive a check for is rendered ❓ *unknown*, never guessed at as done
or pending. A weak, clearly-labelled hint from the agent transcript (a tool
call that touched a path the step names) may be appended to an unknown step,
but it never upgrades the icon — evidence trust ranks git status/filesystem
above transcript mentions, and only the former ever produces a ✅.

Usage: status-writer.py PLAN REPO OUT [TASKDIR]
"""
import json, os, re, subprocess, sys, time
from datetime import datetime, timezone

PLAN, REPO, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
TASKDIR = sys.argv[4] if len(sys.argv) > 4 else None


def git(*a):
    try:
        return subprocess.run(["git", "-C", REPO, *a], capture_output=True,
                              text=True, timeout=10).stdout.strip()
    except Exception:
        return ""


def discovered_transcripts():
    """Full paths of real agent transcripts in TASKDIR — same filter agent_idle
    uses, so a background shell task's output (a different filename shape)
    never gets scanned as if it were agent activity."""
    if not TASKDIR or not os.path.isdir(TASKDIR):
        return []
    return [os.path.join(TASKDIR, name) for name in os.listdir(TASKDIR)
            if re.fullmatch(r"a[0-9a-f]{16}\.output", name)]


def task_blocks():
    """number -> raw block text, for both the task table and the subtask parser."""
    s = open(PLAN).read()
    out = {}
    for b in re.split(r"(?=^### Task \d+ — )", s, flags=re.M)[1:]:
        m = re.match(r"### Task (\d+) — (.+)", b)
        out[int(m.group(1))] = b
    return out


def tasks():
    out = []
    for n, b in sorted(task_blocks().items()):
        m = re.match(r"### Task (\d+) — (.+)", b)
        c = re.search(r"\*\*Commit:\*\* `([^`]+)`", b)
        gate = "HUMAN GATE" if "human confirms" in b or "do not start unattended" in b.lower() else ""
        out.append((n, re.sub(r"`", "", m.group(2)).strip(),
                    c.group(1) if c else "", gate))
    return out


# ---------------------------------------------------------------------------
# Subtasks: parse the numbered **Do:** steps of one task, and try to derive a
# structural (git/filesystem) check for each. Anything we can't build a check
# for stays unknown — see module docstring for why that's a hard rule, not a
# style choice.

DO_RE = re.compile(r"\*\*Do:\*\*\s*\n(.*?)(?=\n\*\*[A-Z][\w /'-]*:\*\*|\n---|\Z)", re.S)
RENAME_RE = re.compile(r"git mv\s+(\S+)\s+(\S+)")
COPY_RE = re.compile(r"Copy\s+`([^`]+)`\s*(?:→|->)\s*`([^`]+)`")
SYMLINK_RE = re.compile(r"ln -s\s+(\S+)\s+(\S+)")
ABSENT_RE = re.compile(r"`([^`]+)`\s+does not exist")
PATHISH_RE = re.compile(r"`([\w][\w./\-]*[\w])`")


def do_steps(block):
    m = DO_RE.search(block)
    if not m:
        return []
    parts = re.split(r"(?m)^(\d+)\.\s+", m.group(1))
    return [(int(parts[i]), parts[i + 1].strip()) for i in range(1, len(parts), 2)]


def _clean(tok):
    return tok.strip("`.,;:) ")


def classify(text):
    """Best-effort: pull a checkable (kind, a, b) out of a step's prose, or
    ("unknown", None, None) if nothing in it maps to a structural check."""
    flat = " ".join(text.split())
    m = RENAME_RE.search(flat)
    if m:
        return ("rename", _clean(m.group(1)), _clean(m.group(2)))
    m = COPY_RE.search(text)
    if m:
        src, dst = m.group(1), m.group(2)
        if "/" not in dst:
            d = os.path.dirname(src)
            dst = f"{d}/{dst}" if d else dst
        return ("copy", src, dst)
    m = SYMLINK_RE.search(flat)
    if m:
        return ("symlink", _clean(m.group(1)), _clean(m.group(2)))
    m = ABSENT_RE.search(flat)
    if m:
        return ("absent", m.group(1), None)
    return ("unknown", None, None)


def status_renames():
    """(old, new) pairs git already sees as renames — the strongest evidence
    available, since it's git's own move-detection, not ours."""
    pairs = []
    for line in git("status", "--short").splitlines():
        if line[:1] in ("R", "C") and " -> " in line:
            rest = line[3:]
            src, dst = rest.split(" -> ", 1)
            pairs.append((src.strip(), dst.strip()))
    return pairs


def eval_step(kind, a, b):
    """-> (state, note). state in {done, pending, unknown}. note is a short,
    honest tag naming the evidence — never longer than needed to calibrate."""
    if kind == "rename":
        for src, dst in status_renames():
            if src.endswith(a) and dst.endswith(b):
                return ("done", "git: rename recorded")
        src_gone = not os.path.exists(os.path.join(REPO, a))
        dst_here = os.path.exists(os.path.join(REPO, b))
        if src_gone and dst_here:
            return ("done", "fs: rename detected")
        if dst_here:
            return ("unknown", "fs: dest exists, src remains too")
        return ("pending", "fs: source still in place")
    if kind == "copy":
        if os.path.exists(os.path.join(REPO, b)):
            return ("done", "fs: destination exists")
        return ("pending", "fs: destination missing")
    if kind == "symlink":
        full = os.path.join(REPO, b)
        if os.path.islink(full):
            rt = os.readlink(full)
            if rt == a or rt == os.path.join(os.path.dirname(b), a):
                return ("done", f"fs: symlink → {rt}")
            return ("pending", f"fs: wrong target ({rt})")
        return ("pending", "fs: not yet a symlink")
    if kind == "absent":
        if not os.path.exists(os.path.join(REPO, a)):
            return ("done", "fs: absent, as required")
        return ("pending", "fs: still present")
    return ("unknown", "no auto-check for this step")


# Transcript scan: the weakest evidence tier, used only to annotate an
# already-unknown step, never to promote it to done. We stream each JSONL
# transcript line by line and keep only short tool_use command/file_path
# strings (a few KB total, not the raw transcript, which can be 1MB+), and
# cache per (path, mtime) so a steady stream of ticks doesn't re-scan.
_tcache = {}


def transcript_text(path):
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        return ""
    cached = _tcache.get(path)
    if cached and cached[0] == mtime:
        return cached[1]
    # Only Edit/Write targets, not Bash commands: a path is a strong-ish hint
    # when a tool actually wrote to it, but a path merely *mentioned* in a
    # shell command (every task's tests run `bin/amux --help`, grep it, cat
    # it...) is true of almost every transcript regardless of which step is
    # in flight, and would make the hint fire on everything — noise, not
    # signal. Restricting to Edit/Write file_path keeps it rare and specific.
    paths = []
    try:
        with open(path, "r", errors="replace") as fh:
            for line in fh:
                if '"tool_use"' not in line:
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                content = (o.get("message") or {}).get("content")
                if not isinstance(content, list):
                    continue
                for c in content:
                    if not isinstance(c, dict) or c.get("type") != "tool_use":
                        continue
                    if c.get("name") not in ("Edit", "Write"):
                        continue
                    inp = c.get("input")
                    if not isinstance(inp, dict):
                        continue
                    v = inp.get("file_path")
                    if isinstance(v, str):
                        paths.append(v[:300])
    except OSError:
        return ""
    text = "\n".join(paths)
    _tcache[path] = (mtime, text)
    return text


def transcript_hint(needle):
    """True only when some transcript shows a tool actually writing to a path
    ending in `needle` — an exact path-segment match, not a raw substring, so
    "amux" doesn't light up on "roost-agent-state" or vice versa."""
    for path in discovered_transcripts():
        for line in transcript_text(path).splitlines():
            if line == needle or line.endswith("/" + needle):
                return "no auto-check · edited in transcript"
    return None


def short(text, n=42):
    flat = " ".join(text.split())
    return flat if len(flat) <= n else flat[: n - 1].rstrip() + "…"


def subtask_lines(n, title, gate, block):
    steps = do_steps(block)
    if not steps:
        return []
    L = [f"\n## In progress — Task {n}: {title}\n"]
    if gate:
        L.append(f"_⛔ {gate} — nothing below can start until it is. Steps still show what's true so far._\n")
    L.append("_Evidence trust: git rename > filesystem check > transcript hint —\n"
              "transcript alone never marks a step ✅._\n")
    counts = {"done": 0, "pending": 0, "unknown": 0}
    for num, text in steps:
        kind, a, b = classify(text)
        state, note = eval_step(kind, a, b)
        if state == "unknown":
            for cand in dict.fromkeys(PATHISH_RE.findall(text)):
                if len(cand) >= 5 and ("/" in cand or "." in cand):
                    hint = transcript_hint(cand)
                    if hint:
                        note = hint
                        break
        counts[state] += 1
        icon = {"done": "✅", "pending": "⬜", "unknown": "❓"}[state]
        L.append(f" {num}. {icon} {short(text)}  _{note}_")
    L.append(f"\n_{counts['done']} done · {counts['pending']} not yet · "
             f"{counts['unknown']} unknown (no automatic check — verify by hand)._\n")
    return L


def agent_idle():
    """Seconds since any agent last acted, across auto-discovered transcripts.

    Discovery matters: a hand-written list goes stale the moment new agents are
    dispatched, and then reports the silence of FINISHED agents as a stall —
    a false alarm indistinguishable from a real one."""
    m = [os.path.getmtime(t) for t in discovered_transcripts() if os.path.exists(t)]
    return (time.time() - max(m)) if m else None


while True:
    log = git("log", "--format=%h|%s", "origin/main..HEAD")
    subjects = {}
    for line in log.splitlines():
        if "|" in line:
            h, s = line.split("|", 1)
            subjects[s.strip()] = h

    rows, done, pending = [], 0, []
    for n, title, commit, gate in tasks():
        sha = subjects.get(commit, "")
        if sha:
            done += 1
            rows.append(f"| {n} | ✅ | `{sha}` | {title} |")
        else:
            pending.append((n, title, gate))
            mark = "⛔" if gate else "⬜"
            rows.append(f"| {n} | {mark} | | {title}{' **' + gate + '**' if gate else ''} |")

    total = len(rows)
    dirty = [l for l in git("status", "--short").splitlines() if l.strip()]
    idle = agent_idle()

    L = []
    L.append("# roost rename — progress\n")
    bar = "█" * round(20 * done / total) + "░" * (20 - round(20 * done / total))
    L.append(f"`{bar}`  **{done} of {total}** tasks committed\n")

    if idle is not None:
        # Buckets, not seconds. A live counter makes the doc change on every
        # tick, which forces a redraw on every tick — that was the flicker.
        if idle < 90:
            state = "🟢 working"
        elif idle < 300:
            state = "🟡 quiet for a few minutes"
        else:
            state = f"🔴 no activity for {int(idle // 60)} min — possibly stalled"
        L.append(f"Newest agent activity: {state}\n")
    if dirty:
        n = len(dirty)
        band = "1" if n == 1 else ("2-5" if n <= 5 else ("6-15" if n <= 15 else "15+"))
        L.append(f"Uncommitted: **{band} files** (work in flight)\n")
    else:
        L.append("Working tree clean — nothing in flight\n")

    L.append("## Tasks\n")
    L.append("| # | | commit | what |")
    L.append("|---|---|---|---|")
    L.extend(rows)

    if pending:
        # Only the task at the front of the queue gets its steps expanded —
        # fifteen tasks times six steps apiece is unreadable, and the other
        # pending tasks haven't been touched yet so there's nothing to show.
        fn, ftitle, fgate = pending[0]
        L.extend(subtask_lines(fn, ftitle, fgate, task_blocks().get(fn, "")))

        L.append("\n## Remaining\n")
        for n, title, gate in pending:
            L.append(f"- **Task {n}** — {title}" + (f"  ⛔ _{gate}_" if gate else ""))

    L.append(f"\n---\n_updated {datetime.now(timezone.utc).strftime('%H:%M:%S')} UTC · "
             f"branch `{git('rev-parse','--abbrev-ref','HEAD')}` · nothing pushed_")

    text = "\n".join(L) + "\n"
    prev = ""
    if os.path.exists(OUT):
        prev = open(OUT).read()
    # Ignore the timestamp line when deciding whether anything changed, so the
    # viewer does not redraw every tick for a clock that nobody is reading.
    if re.sub(r"_updated.*", "", prev) != re.sub(r"_updated.*", "", text):
        open(OUT, "w").write(text)
    time.sleep(5)
