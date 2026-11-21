#!/usr/bin/env python3
"""Measured renderer boundaries distinguish drafts from transcript rules."""
import importlib.util
import sys
from pathlib import Path
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
    ("codex", ["› Ask Codex to do anything", ""], 2, 0, "occupied"),
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
raise SystemExit(bool(failed))
