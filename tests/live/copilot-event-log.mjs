// A second, read-only copilot extension for tests/live/copilot-smoke.sh: record
// the raw event stream the adapter is reacting to, one JSON object a line, into
// $ROOST_EVENT_LOG.
//
// The badge assertions in the smoke test say WHAT the pane showed; this log is
// the only thing that says why, and a re-run costs minutes of model time.
//
// It registers NO handlers — no `hooks:` block and no onPermissionRequest — on
// purpose. Either would make copilot raise a second "wants elevated
// permissions" consent dialog for this extension, which the smoke test would
// then have to answer, and would put a second onPermissionRequest handler in
// front of the one under test.
import { appendFileSync } from "node:fs"

const path = process.env.ROOST_EVENT_LOG
if (path) {
  try {
    const { joinSession } = await import("@github/copilot-sdk/extension")
    const session = await joinSession({})
    const started = Date.now()
    session.on((event) => {
      try {
        appendFileSync(
          path,
          JSON.stringify({ ms: Date.now() - started, type: event?.type, agentId: event?.agentId ?? null, data: event?.data }) + "\n"
        )
      } catch {
        // A log that cannot be written must never take the pane's agent down.
      }
    })
  } catch {
    // Outside copilot there is no SDK and nothing to join.
  }
}
