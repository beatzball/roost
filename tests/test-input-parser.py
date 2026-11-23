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

# Claude Code 2.1.330 row reported in #258, with its escape codes intact.
claude_hint = 'Try "create a util logging.py that…"'
claude_border = "\x1b[38;5;244m" + rule + "\x1b[0m"
for label, body, x, want in [
    ("dim hint", "❯ \x1b[2m" + claude_hint + "\x1b[0m", 2, "empty"),
    ("hint words typed as a draft", "❯ " + claude_hint, 2, "occupied"),
    ("dim hint with cursor past the marker", "❯ \x1b[2m" + claude_hint + "\x1b[0m", 3, "unknown"),
    ("draft after dim reset", "❯\u00a0\x1b[2mghost\x1b[22m draft", 2, "occupied"),
    ("dim carries onto a continuation row", "❯ \x1b[2m" + "x" * 68 + "\nmore\x1b[0m", 2, "empty"),
]:
    output = f"%0|0|0|{x}|1|claude|claude||1|70|idle\n{claude_border}\n{body}\n{claude_border}\n".encode()
    with patch.object(reader.subprocess, "run", return_value=CompletedProcess([], 0, output)):
        got = reader.snapshot(["tmux", "-S", "unused"], "%0")
    print("  %s: claude snapshot %s (got %s)" % ("PASS" if got == want else "FAIL", label, got))
    failed += got != want

# The captured 0.167.2 row includes a background before and after the hint.
# Exercise capture decoding and normalization as well as classification.
ghost = json.loads((Path(__file__).parent / "fixtures/codex-ghost.json").read_text())
hint = "Ask Codex to do anything"
pass_through = ("unknown", "empty")
occupied = ("occupied",)
for label, row, x, y, width, tail, want in [
    ("full-width dim hint", "› \x1b[2m" + hint, 2, 0, 90, "\n\n? for shortcuts", pass_through),
    ("24-column dim hint", "› \x1b[2m" + hint[:22], 2, 0, 24, "\n" + hint[22:], pass_through),
    ("10-column dim hint", "› \x1b[2m" + hint[:8], 2, 0, 10, "\n" + hint[8:18], pass_through),
    ("captured RGB background", ghost, 2, 0, 80, "\n\n? for shortcuts", pass_through),
    ("dim hint missing its footer", ghost, 2, 0, 80, "", pass_through),
    ("different dim wording with cursor after text", "› \x1b[2mContinue?", 11, 0, 80, "", pass_through),
    ("dim survives foreground and indexed background changes",
     "› \x1b[2;38;2;10;22;30mLook\x1b[48;5;0m here", 2, 0, 80, "", pass_through),
    ("dim survives indexed foreground and RGB background changes",
     "› \x1b[2;38;5;22mLook\x1b[48;2;0;22;2m here", 2, 0, 80, "", pass_through),
    ("non-dim hint words at Home", "› " + hint, 2, 0, 80, "", occupied),
    ("non-dim hint words after foreground changes",
     "› \x1b[90mAsk Codex\x1b[39m to do anything", 2, 0, 80, "", occupied),
    ("non-dim hint words after RGB foreground and background",
     "› \x1b[38;2;10;20;2;48;2;65;69;76m" + hint, 2, 0, 80, "", occupied),
    ("non-dim hint words after indexed foreground and background",
     "› \x1b[38;5;2;48;5;2m" + hint, 2, 0, 80, "", occupied),
    ("SGR0 resets dim before typed text", "› \x1b[2mghost\x1b[0m draft", 2, 0, 80, "", occupied),
    ("SGR22 resets dim before typed text", "› \x1b[2mghost\x1b[22m draft", 2, 0, 80, "", occupied),
    ("empty SGR resets dim before typed text", "› \x1b[2mghost\x1b[m draft", 2, 0, 80, "", occupied),
    ("typed text before dim text", "› draft\x1b[2m ghost", 2, 0, 80, "", occupied),
    ("only non-dim spaces after marker", "\x1b[1m› \x1b[2mghost\x1b[22m  ", 2, 0, 80, "", pass_through),
    ("dim continues from a full-width row", "\x1b[2m0123456789\n› hint", 2, 1, 10, "", pass_through),
    ("dim carried from a full-width row resets after the marker",
     "\x1b[2m0123456789\n› \x1b[0mdraft", 2, 1, 10, "", occupied),
    ("marker-only row", "›", 1, 0, 2, "", pass_through),
    ("cursor below marker row", "› human", 0, 1, 80, "\ncontinuation", pass_through),
    ("cursor outside capture", "› human", 0, 5, 80, "", pass_through),
    ("text without a prompt marker", "some human text", 2, 0, 80, "", pass_through),
    ("incomplete extended colour", "› \x1b[48;2;7mpossible draft", 2, 0, 80, "", pass_through),
    ("invalid UTF-8 on the cursor row", "› \udcff", 2, 0, 80, "", pass_through),
]:
    output = (f"%0|0|0|{x}|{y}|codex|codex||1|{width}|idle\n{row}{tail}\n").encode(errors="surrogateescape")
    with patch.object(reader.subprocess, "run", return_value=CompletedProcess([], 0, output)):
        got = reader.snapshot(["tmux", "-S", "unused"], "%0")
    print("  %s: codex snapshot %s (got %s)" % ("PASS" if got in want else "FAIL", label, got))
    failed += got not in want
raise SystemExit(bool(failed))
