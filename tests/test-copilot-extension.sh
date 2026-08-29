#!/usr/bin/env bash
# The copilot extension's event mapping, tested without running copilot.
#
# Real copilot needs a model and is far too slow for CI; tests/live/ has the
# hand-run test that drives it for real. This one covers the whole mapping
# table offline in milliseconds, including the four traps the live scouting
# turned up — the gated permission handler, the sub-agent filter, the idle that
# follows an error, and the startup consent that arrives as a permission event.
#
# Gated on node in the same style as the python3-gated tests, so the suite
# degrades to a skip rather than a failure if node is ever absent.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
if ! command -v node >/dev/null 2>&1; then
  echo "  SKIP: node not found — copilot extension mapping tests skipped"
  exit 0
fi
exec node "$HERE/copilot-extension-harness.mjs"
