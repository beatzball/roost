#!/usr/bin/env bash
# The opencode 2 plugin (adapters/opencode/v2/tui.js), tested without running
# opencode.
#
# Real opencode needs a model and is far too slow for CI; tests/live/ has the
# hand-run test that drives it for real. This one replays the recorded 2.0.20
# event logs in tests/fixtures/opencode2/ through the plugin's real entry point
# offline.
#
# Gated on node in the same style as the python3-gated tests, so the suite
# degrades to a skip rather than a failure if node is ever absent. A node too
# old for node:test's mock timers is the harness's own skip, for the same
# reason.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
if ! command -v node >/dev/null 2>&1; then
  echo "  SKIP: node not found — opencode 2 plugin tests skipped"
  exit 0
fi
exec node "$HERE/opencode2-plugin-harness.mjs"
