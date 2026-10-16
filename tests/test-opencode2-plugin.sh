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
# reason -- and so is a node whose mock.timers.enable() takes neither the
# { apis: [...] } object nor node 18's bare array: the harness tries both and
# prints one SKIP line, never a crash. So is a node that cannot load the
# adapter at all (node 18 does not load ES-module syntax from a `.js` file).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
if ! command -v node >/dev/null 2>&1; then
  echo "  SKIP: node not found — opencode 2 plugin tests skipped"
  exit 0
fi
exec node "$HERE/opencode2-plugin-harness.mjs"
