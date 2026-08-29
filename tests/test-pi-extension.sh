#!/usr/bin/env bash
# The pi extension's event mapping, tested without running pi.
#
# Real pi needs a model and is far too slow for CI; tests/live/ has the
# hand-run test that drives it for real. This one covers the whole mapping
# table offline in milliseconds, including the four traps the live probing
# turned up -- agent_end firing once per retry, a human's Esc arriving in the
# same field as a provider failure, /reload stacking a second dialog wrap on
# pi's shared UI object, and a sub-agent's own pi process badging its parent's
# pane.
#
# Gated on node in the same style as test-copilot-extension.sh. The harness
# itself gates on node being new enough to import the adapter's .ts, and says
# so -- see the import comment in that file.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
if ! command -v node >/dev/null 2>&1; then
  echo "  SKIP: node not found — pi extension mapping tests skipped"
  exit 0
fi
exec node "$HERE/pi-extension-harness.mjs"
