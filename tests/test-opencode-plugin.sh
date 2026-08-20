#!/usr/bin/env bash
# The opencode plugin's event mapping, tested without running opencode.
#
# Real opencode needs a model and is far too slow for CI; tests/live/ has the
# hand-run test that drives it for real. This one covers the whole mapping
# table offline in milliseconds.
#
# Gated on node in the same style as the python3-gated tests, so the suite
# degrades to a skip rather than a failure if node is ever absent.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
if ! command -v node >/dev/null 2>&1; then
  echo "  SKIP: node not found — opencode plugin mapping tests skipped"
  exit 0
fi
exec node "$HERE/opencode-plugin-harness.mjs"
