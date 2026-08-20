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
