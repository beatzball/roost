// A second, read-only pi extension for tests/live/pi-smoke.sh: record the raw
// event stream the adapter is reacting to, one JSON object a line, into
// $ROOST_EVENT_LOG.
//
// The badge assertions in the smoke test say WHAT the pane showed; this log is
// the only thing that says why, and a re-run costs minutes of model time.
//
// It subscribes only. It registers no tool, no command and no project_trust
// handler, and it never touches ctx.ui -- pi hands every extension THE SAME ui
// object (dist/core/extensions/runner.js:458), so a spy that wrapped a dialog
// method would be wrapping the very thing the adapter under test wraps.
//
// The file name matters only in that pi discovers `*.ts`; the smoke test
// symlinks it in beside the adapter.
import { appendFileSync } from "node:fs"

const path = process.env.ROOST_EVENT_LOG
const started = Date.now()

export default function (pi: any) {
  if (!path) return
  const w = (o: any) => {
    try {
      appendFileSync(path, JSON.stringify({ ms: Date.now() - started, pid: process.pid, ...o }) + "\n")
    } catch {
      // A log that cannot be written must never take the pane's agent down.
    }
  }
  // Every event the adapter reads, plus the ones a reader diagnosing a failure
  // will ask about next: the retries (agent_end), the turn boundaries, and the
  // tool call that a permission gate hangs off.
  const NAMES = [
    "session_start", "session_shutdown", "input", "before_agent_start",
    "agent_start", "agent_end", "agent_settled", "turn_start", "turn_end",
    "message_end", "tool_call", "tool_execution_end",
  ]
  for (const name of NAMES) {
    pi.on(name, async (event: any, ctx: any) => {
      const rec: any = { ev: name }
      try { rec.mode = ctx?.mode; rec.hasUI = ctx?.hasUI } catch {}
      if (name === "message_end") {
        const m = event?.message
        rec.role = m?.role
        rec.stopReason = m?.stopReason ?? null
        rec.errorMessage = m?.errorMessage ?? null
        rec.partTypes = Array.isArray(m?.content) ? m.content.map((p: any) => p?.type) : null
        rec.textLen = Array.isArray(m?.content)
          ? m.content.filter((p: any) => p?.type === "text").map((p: any) => p?.text ?? "").join("").length
          : 0
      }
      if (name === "tool_call") rec.tool = event?.toolName
      if (name === "tool_execution_end") { rec.tool = event?.toolName; rec.isError = event?.isError }
      w(rec)
    })
  }
}
