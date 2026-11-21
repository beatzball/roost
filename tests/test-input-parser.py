#!/usr/bin/env python3
"""Measured renderer boundaries distinguish drafts from transcript rules."""
import importlib.util
import json
import sys
from pathlib import Path
from subprocess import CompletedProcess
from unittest.mock import patch
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("reader", Path(__file__).resolve().parents[1] / "scripts/roost-input.py")
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)
rule = "─" * 70
cases = [
    ("claude", [rule, "❯ ", rule], 2, 1, "empty"),
    ("claude", [rule, "❯ human", rule], 2, 1, "occupied"),
    ("claude", [rule, "❯ human", "", rule], 0, 2, "occupied"),
    ("claude", [rule, "❯ ", "  human", rule], 2, 1, "occupied"),
    ("claude", ["❯ old", "response", ""], 0, 2, "unknown"),
    ("claude", ["❯ ", rule], 2, 0, "unknown"),
    ("pi", [rule, "", rule], 0, 1, "empty"),
    ("pi", [rule, "human", "", rule], 0, 2, "occupied"),
    ("pi", ["─ ↑ 3 lines ─", "", rule], 0, 1, "unknown"),
    ("codex", ["› ", "", "? for shortcuts"], 2, 0, "empty"),
    ("codex", ["› human", ""], 2, 0, "occupied"),
    ("codex", ["› Ask Codex to do anything", ""], 26, 0, "occupied"),
    ("codex", ["› ", "", "human", "", "? for shortcuts"], 2, 0, "unknown"),
    ("shell", ["$ human"], 2, 0, "unknown"),
    ("mystery", [rule, "❯ human", rule], 2, 1, "unknown"),
]
for h in ("claude", "pi"):
    prefix = "❯ " if h == "claude" else ""
    for size in (10, 70):
        cases.append((h, [rule, prefix, "─" * size, "human", rule], len(prefix), 1, "occupied"))
        cases.append((h, [rule, prefix + "human", "─" * size, "", rule], len(prefix), 3, "occupied"))
failed = 0
for h, rows, x, y, want in cases:
    raw = list(rows)
    for i in (0, len(raw) - 1):
        if raw[i] == rule:
            raw[i] = ("\x1b[2m" if h == "pi" else "\x1b[38;5;244m") + rule + "\x1b[0m"
    got = reader.classify(h, rows, x, y, reader.renderer_borders(h, raw, 70))
    print("  %s: %s parser case %s (got %s)" % ("PASS" if got == want else "FAIL", h, want, got))
    failed += got != want

# The captured 0.167.2 row includes a background before and after the hint.
# Exercise capture decoding and normalization as well as classification.
ghost = json.loads((Path(__file__).parent / "fixtures/codex-ghost.json").read_text())
hint = "Ask Codex to do anything"
pass_through = ("empty", "unknown")
for label, row, x, footer, want in [
    ("captured RGB background", ghost, 2, True, pass_through),
    ("indexed background and combined styles", "\x1b[1;7m›\x1b[m \x1b[2;48;5;236m" + hint, 2, True, pass_through),
    ("foreground style across the hint", "› \x1b[90mAsk Codex\x1b[39m to do anything", 2, True, pass_through),
    ("ambiguous hint with cursor at Home", "› " + hint, 2, True, ("unknown",)),
    ("ambiguous hint with missing footer", ghost, 2, False, ("unknown",)),
    ("typed hint words with cursor after text", "› " + hint, 2 + len(hint), True, ("occupied",)),
    ("colored human draft at Home", "› \x1b[48;2;65;69;76mhuman draft\x1b[m", 2, True, ("occupied",)),
]:
    screen = row + ("\n\n? for shortcuts\n" if footer else "\n")
    output = (f"%0|0|0|{x}|0|codex|codex||1|80|idle\n" + screen).encode()
    with patch.object(reader.subprocess, "run", return_value=CompletedProcess([], 0, output)):
        got = reader.snapshot(["tmux", "-S", "unused"], "%0")
    print("  %s: codex snapshot %s (got %s)" % ("PASS" if got in want else "FAIL", label, got))
    failed += got not in want
raise SystemExit(bool(failed))
