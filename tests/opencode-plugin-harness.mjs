// Fire synthetic opencode events at adapters/opencode/roost.js and assert which
// `roost state` calls come out, with a recording shim standing in for roost on
// PATH. Runs offline, in milliseconds, with no model call.
//
// Prints "  PASS:" / "  FAIL:" lines so tests/run.sh counts them like any bash
// test, and always exits 0 — run.sh treats a non-zero exit as a crash.
import { mkdtempSync, rmSync, writeFileSync, readFileSync, existsSync, chmodSync } from "node:fs"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

const HERE = fileURLToPath(new URL(".", import.meta.url))
// Short path: the ~104-char unix socket limit bites elsewhere in this suite,
// and /tmp/amx.* is the prefix its cleanup tooling knows about.
const dir = mkdtempSync("/tmp/amx.")
const log = join(dir, "calls")
const shim = join(dir, "roost")
// Record the state ($2) and whether ROOST_AGENT_NAME arrived, tab-separated,
// so calls() (state only) and envNames() (ROOST_AGENT_NAME only) can each
// read their own column without disturbing the other's assertions.
writeFileSync(shim, `#!/bin/sh\nprintf '%s\\t%s\\n' "$2" "\${ROOST_AGENT_NAME:-}" >> "${log}"\n`)
chmodSync(shim, 0o755)
const REAL_PATH = process.env.PATH
process.env.PATH = `${dir}:${REAL_PATH}`

let pass = 0
let fail = 0
const check = (got, want, what) => {
  if (got === want) {
    pass++
    console.log(`  PASS: ${what}`)
  } else {
    fail++
    console.log(`  FAIL: ${what}\n       want [${want}] got [${got}]`)
  }
}

const rows = () => (existsSync(log) ? readFileSync(log, "utf8").split("\n").filter(Boolean) : [])
const calls = () => rows().map((r) => r.split("\t")[0]).join(",")
const envNames = () => rows().map((r) => r.split("\t")[1])

const { RoostState } = await import(join(HERE, "..", "adapters", "opencode", "roost.js"))

// A fresh plugin instance per case, so one case's debounce state cannot leak
// into the next and make a later assertion pass for the wrong reason.
const fresh = async () => {
  if (existsSync(log)) rmSync(log)
  const { event } = await RoostState()
  return async (...events) => {
    for (const e of events) await event({ event: e })
  }
}
const status = (type) => ({ type: "session.status", properties: { status: { type } } })
const plain = (type) => ({ type, properties: {} })
const errored = (name) => ({ type: "session.error", properties: { error: { name } } })

// The subagent cases below replay a REAL interleave, captured by
// tests/live/event-log.js from opencode 1.18.20 driving the `general` subagent
// through the task tool. The session ids are the recorded ones, kept verbatim
// so the shapes are the ones opencode actually emits rather than ones invented
// here — parent and child both carry properties.sessionID, and only the child
// carries properties.info.parentID.
const PARENT = "ses_fd0144131ffe4LzGD55GeBuNRE"
const CHILD = "ses_fd013652effeTt5cu9L5Kbhn8S"
const from = (sessionID, event) => ({
  ...event,
  properties: { ...event.properties, sessionID },
})
const born = (sessionID, parentID) => ({
  type: "session.created",
  properties: { sessionID, info: { id: sessionID, parentID } },
})

let fire = await fresh()
await fire(status("busy"))
check(calls(), "working", "session.status busy reports working")
check(envNames().every((n) => n === "opencode"), true, "roost is called with ROOST_AGENT_NAME=opencode")

fire = await fresh()
await fire(status("busy"), status("busy"), status("busy"))
check(calls(), "working", "repeated busy events are debounced to one call")

fire = await fresh()
await fire(status("busy"), plain("permission.asked"), plain("permission.replied"), plain("session.idle"))
check(calls(), "working,blocked,working,done", "a full permission turn walks working -> blocked -> working -> done")

fire = await fresh()
await fire(status("busy"), status("retry"))
check(calls(), "working", "a single retry stays working — it may be a blip")

fire = await fresh()
await fire(status("busy"), status("retry"), status("retry"))
check(calls(), "working,error", "two consecutive retries report error")

fire = await fresh()
await fire(status("busy"), status("retry"), status("retry"), status("busy"))
check(calls(), "working,error", "busy alone does not resurrect a pane out of error — only a turn boundary does")

fire = await fresh()
await fire(status("busy"), status("retry"), plain("session.idle"), status("busy"), status("retry"))
check(calls(), "working,done,working", "the retry counter resets at turn boundaries, so two retries in different turns are not an error")

fire = await fresh()
await fire(status("busy"), status("retry"), status("busy"), status("retry"), status("busy"))
check(calls(), "working,error", "a busy between retries does not reset the counter, and busy past threshold does not flap the badge back to working (opencode's real stream interleaves them)")

fire = await fresh()
await fire(status("busy"), errored("MessageAbortedError"))
check(calls(), "working,done", "MessageAbortedError is the user pressing Esc, so it reports done")

fire = await fresh()
await fire(status("busy"), errored("APICallError"))
check(calls(), "working,error", "any other session.error reports error")

fire = await fresh()
await fire(plain("message.part.delta"), plain("file.edited"), status("idle"))
check(calls(), "", "unmapped events produce no call at all")

// --- subagents: a child session is a different turn on the same bus ---

fire = await fresh()
await fire(
  born(PARENT, undefined),
  from(PARENT, status("busy")),
  born(CHILD, PARENT),
  from(CHILD, status("busy")),
  from(CHILD, plain("session.idle")),
  from(PARENT, status("busy")),
  from(PARENT, plain("session.idle"))
)
check(calls(), "working,done", "a subagent going idle mid-turn does not badge the pane done — only the parent's idle does")

fire = await fresh()
await fire(
  born(PARENT, undefined),
  from(PARENT, status("busy")),
  born(CHILD, PARENT),
  from(CHILD, errored("APICallError")),
  from(PARENT, plain("session.idle"))
)
check(calls(), "working,done", "a subagent's session.error does not badge the pane error")

fire = await fresh()
await fire(
  born(PARENT, undefined),
  from(PARENT, status("busy")),
  from(PARENT, status("retry")),
  born(CHILD, PARENT),
  from(CHILD, plain("session.idle")),
  from(PARENT, status("busy")),
  from(PARENT, status("retry"))
)
check(calls(), "working,error", "a subagent's idle does not reset the parent's retry counter")

// The pane's own session must keep working even when a child has been seen —
// the guard must filter by session id, not switch itself off once a subagent
// has ever run.
fire = await fresh()
await fire(
  born(PARENT, undefined),
  born(CHILD, PARENT),
  from(CHILD, plain("session.idle")),
  from(PARENT, status("busy")),
  from(PARENT, plain("permission.asked")),
  from(PARENT, plain("permission.replied")),
  from(PARENT, plain("session.idle"))
)
check(calls(), "working,blocked,working,done", "the parent's own events are still mapped after a subagent has run")

// The one thing a subagent DOES speak for the pane with. Its permission dialog
// is answered by the human at this pane, so the badge has to say so — a pane
// reading `working` while it waits for a keypress is the silently stuck case.
fire = await fresh()
await fire(
  born(PARENT, undefined),
  from(PARENT, status("busy")),
  born(CHILD, PARENT),
  from(CHILD, plain("permission.asked")),
  from(CHILD, plain("permission.replied")),
  from(CHILD, plain("session.idle")),
  from(PARENT, plain("session.idle"))
)
check(calls(), "working,blocked,working,done", "a subagent's permission dialog still badges the pane blocked")

// message.updated carries properties.info too, but that info is a MESSAGE. Its
// parentID (a message id, in a thread) must never be mistaken for a session
// parent, or the pane's own session would be filtered out and never badged.
fire = await fresh()
await fire(
  { type: "message.updated", properties: { sessionID: PARENT, info: { id: "msg_1", parentID: "msg_0" } } },
  from(PARENT, status("busy")),
  from(PARENT, plain("session.idle"))
)
check(calls(), "working,done", "a message with a parentID does not make its session look like a subagent")

// A missing roost must leave the pane unbadged, never throw into opencode's
// event loop. PATH without the shim is the honest way to stage that.
process.env.PATH = "/nonexistent-roost-dir"
let threw = ""
try {
  const { event } = await RoostState()
  await event({ event: status("busy") })
} catch (e) {
  threw = String(e && e.message ? e.message : e)
}
check(threw, "", "a missing roost on PATH does not throw into opencode")
process.env.PATH = `${dir}:${REAL_PATH}`

rmSync(dir, { recursive: true, force: true })
console.log(`  (${pass} passed, ${fail} failed in the opencode plugin harness)`)
process.exit(0)
