// Replay the recorded opencode 2.0.20 event logs (tests/fixtures/opencode2/)
// through adapters/opencode/v2/tui.js and assert which `roost` calls come out,
// with a recording shim standing in for roost on PATH. Runs offline, with no
// opencode and no model call.
//
// What is driven is the plugin's real entry point: `setup(context)` with a fake
// context, events delivered through the listener it registers, and the real
// execFile path to the shim — so what is asserted is the argv, the stdin,
// ROOST_AGENT_NAME on every call, and the order the processes actually ran in.
//
// Prints "  PASS:" / "  FAIL:" lines so tests/run.sh counts them like any bash
// test, and always exits 0 — run.sh treats a non-zero exit as a crash.
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, readFileSync, existsSync, chmodSync } from "node:fs"
import { join } from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"

// node:test's mock timers drive the adapter's interval, so "a second passed
// and nothing else happened" is a step a case can take. A node without them
// skips the whole file the way tests/test-opencode2-plugin.sh skips without
// node at all: one SKIP line, exit 0.
const { mock } = await import("node:test").catch(() => ({}))
if (typeof mock?.timers?.enable !== "function") {
  console.log("  SKIP: node too old for mock timers")
  process.exit(0)
}

const HERE = fileURLToPath(new URL(".", import.meta.url))
const ADAPTER = join(HERE, "..", "adapters", "opencode", "v2", "tui.js")
const FIXTURES = join(HERE, "fixtures", "opencode2")
// Short path: the ~104-char unix socket limit bites elsewhere in this suite,
// and /tmp/amx.* is the prefix its cleanup tooling knows about.
const dir = mkdtempSync("/tmp/amx.")
const log = join(dir, "calls")
const shim = join(dir, "roost")
// The recording shim is tests/opencode-plugin-harness.mjs's, unchanged, and
// its notes come with it:
//
// Record the subcommand ($1), its argument ($2) and whether ROOST_AGENT_NAME
// arrived, tab-separated, so calls() (states only), replies() (reply text
// only) and envNames() (ROOST_AGENT_NAME only) can each read their own column
// without disturbing the other's assertions.
//
// $1 is recorded as well as $2 now that roost is invoked two ways — `roost
// state <state>` and `roost reply <text>`. Without it a reply whose text
// happened to be "done" would be indistinguishable from a state report, and
// the ordering assertions below are entirely about which of the two came
// first.
//
// The argument is newline-escaped before it is written. A reply is genuinely
// multi-line — that is most of the point of recording one instead of scraping
// a screen — and a raw newline here would split one call across two log rows,
// so `roost reply "A\nB"` would read back as a reply of "A" followed by a
// mystery row "B". Both failures look like adapter bugs and are not.
// \x1e (ASCII record separator) stands in: it cannot occur in these fixtures,
// and replies() below maps it back before any assertion sees it.
// A fourth column records the TRANSPORT — argv or stdin — because that is the
// whole of what #86 changed and an assertion on the reply TEXT alone cannot see
// it. `roost reply -` means "the reply is on stdin", so the shim reads it from
// there; every other call is argv exactly as before. Without this the adapters'
// switch to stdin would have recorded every reply as the literal "-", which is
// what the red run showed.
//
// A fifth column, added for #141: every argument, joined by `|`. Only
// `roost identify` needs it — its meaning is in its flags, not in $2 — and no
// fixture's session id or the harness's own directory holds a `|`.
const RECORD =
  `if [ "$1" = reply ] && [ "$2" = - ]; then via=stdin; arg=\`cat\`; else via=argv; arg="$2"; fi\n` +
  `esc=\`printf '%s' "$arg" | tr '\\n' '\\036'\`\n` +
  `all=""; for a in "$@"; do all="$all|$a"; done\n` +
  `printf '%s\\t%s\\t%s\\t%s\\t%s\\n' "$1" "$esc" "\${ROOST_AGENT_NAME:-}" "$via" "\${all#|}" >> "${log}"\n`
const plainShim = () => {
  writeFileSync(shim, `#!/bin/sh\n` + RECORD)
  chmodSync(shim, 0o755)
}
plainShim()
// The slow variant, for the cases about a write still in flight: the verbs
// named (a `case` pattern, "reply" or "state|reply") sleep 400 ms before the
// row is recorded, and every call first appends its verb to `starts` — so a
// call that was STARTED can be counted while it is still running, which the
// log, written as the shim exits, cannot show.
const starts = join(dir, "starts")
const slowShim = (verbs) => {
  writeFileSync(starts, "")
  writeFileSync(
    shim,
    `#!/bin/sh\n` + `printf '%s\\n' "$1" >> "${starts}"\n` + `case "$1" in ${verbs}) sleep 0.4 ;; esac\n` + RECORD
  )
  chmodSync(shim, 0o755)
}
const started = () => readFileSync(starts, "utf8").split("\n").filter(Boolean).length
const REAL_PATH = process.env.PATH
process.env.PATH = `${dir}:${REAL_PATH}`

// Only setInterval is mocked. setTimeout stays real, because the adapter's
// 2-second limit on permission.sync is a real setTimeout and the "never
// settles" case below measures it in real time, and because this harness's
// own waits (quiet(), settle()) are real-time waits on child processes.
//
// Having mock.timers is not enough: node 18 has it, but there enable() takes
// the timers as a bare array, and the { apis: [...] } object form came later.
// node 18.19.1 (Ubuntu 24.04's own nodejs) throws ERR_INVALID_ARG_TYPE, a
// TypeError, on the object form (#150), and that crash left this file with
// no PASS/FAIL/SKIP line and a non-zero exit. So the object form first, the
// array form on a TypeError, and if neither is taken, one SKIP line naming the
// node version and exit 0 -- the same as a node with no mock timers at all.
const enableIntervalMock = () => {
  try {
    mock.timers.enable({ apis: ["setInterval"] })
    return true
  } catch (e) {
    if (!(e instanceof TypeError)) return false
  }
  try {
    mock.timers.enable(["setInterval"])
    return true
  } catch {
    return false
  }
}
if (!enableIntervalMock()) {
  console.log(`  SKIP: node ${process.version}'s mock.timers.enable takes neither { apis: [...] } nor [...] — opencode 2 plugin tests skipped`)
  rmSync(dir, { recursive: true, force: true })
  process.exit(0)
}

// A node that has the timers may still be unable to load the adapter at all.
// tui.js is ES-module syntax in a `.js` file with no package.json saying
// "type": "module" -- node 24 detects that and loads it, node 18.19.1 throws
// "Cannot use import statement outside a module" (#150). Every case would
// then FAIL at "the adapter loads and sets up", which says nothing about the
// adapter: opencode 2 loads it in its own runtime, not the user's node. So it
// is imported once here, before any case, and a node that cannot is one SKIP
// line and exit 0, like the two skips above. Importing it runs nothing:
// the module only defines setup. `?probe` keeps it out of the cases' own
// `?case=N` imports.
//
// Only node's own failure is a SKIP. A real syntax error in tui.js is a
// SyntaxError too, and so is node 18's, so the type alone cannot tell them
// apart: the message does. Anything else -- a broken adapter, on any node --
// is one FAIL line and exit 0, so run.sh counts it. A catch that skipped on
// every error let a `tui.js` with a syntax error, or a top-level
// ReferenceError, pass the suite on node 24 with nothing tested (#150 review).
try {
  await import(`${pathToFileURL(ADAPTER).href}?probe`)
} catch (e) {
  if (e instanceof SyntaxError && /outside a module/.test(e.message)) {
    console.log(`  SKIP: node ${process.version} cannot load the adapter (${e.message}) — opencode 2 plugin tests skipped`)
  } else {
    console.log(`  FAIL: the adapter does not load (${e?.message ?? e})`)
  }
  rmSync(dir, { recursive: true, force: true })
  process.exit(0)
}

let pass = 0
let fail = 0
// While `muted` holds a counter, check() counts there instead of printing: the
// mutation run below needs to know whether a case failed without its FAIL
// lines counting against this file. `loaded` counts the instances start()
// set up while muted, so that run can tell a copy that failed for the right
// reason from one that never loaded.
let muted = null
const check = (got, want, what) => {
  if (muted) {
    if (got !== want) muted.failed++
    return
  }
  if (got === want) {
    pass++
    console.log(`  PASS: ${what}`)
  } else {
    fail++
    console.log(`  FAIL: ${what}\n       want [${want}] got [${got}]`)
  }
}

// Anything the adapter lets escape lands here instead of killing the harness,
// and the last check of the file asserts nothing did.
const escaped = []
process.on("uncaughtException", (e) => escaped.push(`uncaught ${e?.code ?? e}`))
process.on("unhandledRejection", (e) => escaped.push(`unhandled ${e?.code ?? e}`))

const rows = () => (existsSync(log) ? readFileSync(log, "utf8").split("\n").filter(Boolean) : [])
// `roost identify` rows (#141) are kept out of cols(), so every check below
// that was written before the adapter identified anything — the order of
// replies and states, the states, the replies — keeps meaning exactly what it
// meant. allCols() has them, and the identity cases read it.
const allCols = () => rows().map((r) => r.split("\t"))
const cols = () => allCols().filter((c) => c[0] !== "identify")
const identifies = () => allCols().filter((c) => c[0] === "identify").map((c) => c[4])
// The four readers of tests/opencode-plugin-harness.mjs, and envNames().
const calls = () => cols().filter((c) => c[0] === "state").map((c) => c[1]).join(",")
const replies = () => cols().filter((c) => c[0] === "reply").map((c) => c[1].replace(/\x1e/g, "\n"))
const verbs = () => cols().map((c) => c[0]).join(",")
const envNames = () => cols().map((c) => c[2])
const replyVias = () => cols().filter((c) => c[0] === "reply").map((c) => c[3]).join(",")

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
// A `roost` child the adapter has started and that has not exited yet. The
// shim writes its row only as it exits, so a log that has not grown says
// nothing about a child still running; this does.
const children = () => process.getActiveResourcesInfo().filter((r) => r === "ProcessWrap").length

// Every call the adapter makes on the fake context bumps this, so a pass that
// is still asking opencode counts as activity even before it writes.
let activity = 0

// Between two events: wait until the adapter has gone still — no child
// running, the log not growing, no call on the fake context — for `ms`. This
// paces the replay so that each event's pass has finished before the next
// event arrives, the way 50 ms to 30 s of real time separates them in the
// recordings. It is not what assertions are made on; settle() is.
const quiet = async (ms = 25) => {
  let last = `${rows().length}|${activity}`
  let since = Date.now()
  while (Date.now() - since < ms) {
    await sleep(5)
    const now = `${rows().length}|${activity}`
    if (now !== last || children() > 0) {
      last = now
      since = Date.now()
    }
  }
}

// Every assertion is made on a settled log: one that has not grown for 300 ms
// of real time, with no `roost` child still running.
const settle = async () => {
  let n = rows().length
  let since = Date.now()
  while (Date.now() - since < 300) {
    await sleep(10)
    const now = rows().length
    if (now !== n || children() > 0) {
      n = now
      since = Date.now()
    }
  }
  return cols()
}

// --- The recordings ---
//
// tests/fixtures/opencode2/README.md says how they were made and clipped. Each
// row with `what: "ev"` is one event the spy heard. Its payload — what the
// listener receives at `details.data` — is held as a JSON string, in a field
// the files name `data`. A payload longer than the
// spy's limit was cut and ends in "…", so it is not valid JSON; such an event
// is rebuilt from the row's `type` plus the fields an adapter can read off a
// clipped payload whole: `sessionID` and `parentID` (both come first) and, for
// a text event, the `text` up to the cut.
const CLIP = "…"
const field = (raw, key) => {
  const m = raw.match(new RegExp(`"${key}":"((?:[^"\\\\]|\\\\.)*)"`))
  return m ? JSON.parse(`"${m[1]}"`) : undefined
}
// The text runs to the cut, which can fall inside an escape sequence; drop up
// to six trailing characters until what is left parses.
const prefix = (body) => {
  for (let cut = body.length; cut >= Math.max(0, body.length - 6); cut--) {
    try {
      return JSON.parse(`"${body.slice(0, cut)}"`)
    } catch {}
  }
  return ""
}
const payloadOf = (row) => {
  const raw = row.data
  if (typeof raw !== "string") return undefined
  if (!raw.endsWith(CLIP)) return JSON.parse(raw)
  const data = {}
  for (const key of ["sessionID", "parentID"]) {
    const value = field(raw, key)
    if (value !== undefined) data[key] = value
  }
  const text = raw.match(/"text":"((?:[^"\\]|\\.)*)/)
  if (text) data.text = prefix(text[1].slice(0, -CLIP.length))
  return data
}
const load = (file) =>
  readFileSync(join(FIXTURES, file), "utf8")
    .split("\n")
    .filter(Boolean)
    .map((l, i) => ({ ...JSON.parse(l), file, line: i + 1 }))
const FRESH = load("fresh.jsonl")
const TABS = load("tabs.jsonl")
const DEAD = load("dead-provider.jsonl")

// `sid` and `route` hold the last six characters of a session id; the payloads
// hold the whole one.
const IDS = new Map()
for (const r of [...FRESH, ...TABS, ...DEAD]) {
  if (r.what !== "ev") continue
  const id = payloadOf(r)?.sessionID
  if (id) IDS.set(id.slice(-6), id)
}
const full = (six) => IDS.get(six)
// The sessions the cases talk about, by the names the README gives them.
const PARENT = full("tJ94hW") // fresh.jsonl's one chat
const CHILD = full("1G3Yor") // fresh.jsonl's `general` subagent
const OTHER = full("scthnL") // tabs.jsonl's second chat
const DEADCHAT = full("0IEH7b") // dead-provider.jsonl's chat

// One replay step: the events in `evs` are delivered back to back with no wait
// between them, then the harness waits for quiet(). `pre` runs before the
// first, `post` after the wait. `src` names the recording.
const ev = (row, data = payloadOf(row)) => ({ event: { name: row.type, details: { data } }, row })
const step = (row, data) => ({ evs: [ev(row, data)], src: `${row.file}:${row.line}` })
const range = (rows, from, to, keep = () => true) =>
  rows.filter((r) => r.what === "ev" && r.line >= from && r.line <= to && keep(r)).map((r) => step(r))
const at = (rows, line) => rows.find((r) => r.line === line)
// A recorded event moved onto another session: its payload whole, with only
// `sessionID` (and an `id` to tell two requests apart) replaced.
const moved = (rows, line, sessionID, extra = {}) => {
  const row = at(rows, line)
  return step({ ...row, route: `session:${sessionID.slice(-6)}` }, { ...payloadOf(row), sessionID, ...extra })
}
// "A second passed and nothing else happened": one tick of the adapter's
// 1-second interval on node:test's mock clock. In a step's `evs` it is
// delivered in order with the events around it.
const TICK = { tick: true }
const tick = () => ({ evs: [TICK], src: "tick" })

// A second, unrelated chat, shuffled in: tabs.jsonl lines 17–31, its whole
// turn. A seeded generator, so a failure replays the same order.
const SECOND = () => range(TABS, 17, 31)
const shuffle = (a, b, seed) => {
  let s = seed >>> 0
  const rand = () => (s = (s * 1103515245 + 12345) >>> 0) / 2 ** 32
  const out = []
  let i = 0
  let j = 0
  while (i < a.length || j < b.length) {
    if (j >= b.length || (i < a.length && rand() < (a.length - i) / (a.length - i + b.length - j))) out.push(a[i++])
    else out.push(b[j++])
  }
  return out
}

// --- The fake context ---
//
// What a case scripts, per session id, and can change between steps:
// `front` is what ui.router.current() returns; `status`, `family` and
// `pending` back data.session.status(), .family() and .permission.list();
// `syncPlan` is consumed one entry per permission.sync() call — "reject" or
// "hang" — and an empty plan resolves.
const newContext = () => {
  const t = {
    front: { type: "home" },
    status: {},
    family: {},
    pending: {},
    syncPlan: [],
    counts: {},
    listener: null,
    threw: [],
  }
  const count = (what) => {
    t.counts[what] = (t.counts[what] ?? 0) + 1
    activity++
  }
  t.context = {
    data: {
      listen(fn) {
        count("listen")
        t.listener = fn
        return () => {
          count("stop")
          if (t.listener === fn) t.listener = null
        }
      },
      session: {
        status(id) {
          count("status")
          return t.status[id] ?? "idle"
        },
        family(id) {
          count("family")
          return t.family[id] ?? [id]
        },
        permission: {
          async sync(id) {
            count("sync")
            const plan = t.syncPlan.shift()
            if (plan === "reject") throw new Error(`sync ${id} failed`)
            if (plan === "hang") return new Promise(() => {})
          },
          list(id) {
            count("list")
            return t.pending[id] ?? []
          },
        },
      },
    },
    ui: {
      router: {
        current() {
          count("current")
          return t.front
        },
      },
    },
  }
  t.on = (id) => (t.front = id ? { type: "session", sessionID: id } : { type: "home" })
  // Deliver one event the way opencode would: its own state first — the
  // status the spy recorded for the chat in the row's route, a request added
  // on permission.asked and taken away on permission.replied — then the event.
  t.deliver = ({ event, row, tick }) => {
    if (tick) {
      try {
        mock.timers.tick(1000)
      } catch (e) {
        t.threw.push(String(e))
      }
      return
    }
    if (row?.route?.startsWith("session:") && typeof row.status === "string") {
      t.status[full(row.route.slice(8))] = JSON.parse(row.status)
    }
    const d = event?.details?.data
    if (event?.name === "permission.asked" && d?.sessionID) (t.pending[d.sessionID] ??= []).push(d)
    if (event?.name === "permission.replied" && d?.sessionID) {
      t.pending[d.sessionID] = (t.pending[d.sessionID] ?? []).filter((p) => p.id !== d.requestID)
    }
    try {
      t.listener?.(event)
    } catch (e) {
      t.threw.push(String(e))
    }
  }
  // Rows the spy logged in one millisecond were delivered together, so they
  // are replayed back to back: the next one lands inside the pass the last one
  // started, which is the overlap the one serial writer exists for. Any other
  // step waits for quiet() first. A step with a `pre` or a `post` is never
  // run together with its neighbour, so a checkpoint still sees its own step.
  const together = (a, b) => {
    const x = a?.evs.at(-1)?.row
    const y = b?.evs[0]?.row
    return !!x && !!y && !a.post && !b.pre && x.file === y.file && x.ms === y.ms
  }
  t.replay = async (items) => {
    for (const [i, it] of items.entries()) {
      await it.pre?.(t)
      for (const e of it.evs) t.deliver(e)
      if (!together(it, items[i + 1])) await quiet()
      await it.post?.(t)
    }
  }
  return t
}

// A fresh instance per case: a fresh module (`?case=N` defeats the module
// cache, so no state is shared through module scope), a fresh context and an
// empty log. Returns the context, or null with a FAIL line when the adapter
// cannot be loaded — the harness fails its cases rather than crashing.
let caseNo = 0
const start = async (label, prepare = () => {}, adapter = ADAPTER) => {
  caseNo++
  if (existsSync(log)) rmSync(log)
  const t = newContext()
  prepare(t)
  try {
    const mod = await import(`${pathToFileURL(adapter).href}?case=${caseNo}`)
    t.cleanup = mod.default.setup(t.context)
    if (muted) muted.loaded++
  } catch (e) {
    check(`${e?.code ?? e}`, "loaded", `${label}: the adapter loads and sets up`)
    return null
  }
  return t
}
const finish = async (t) => {
  try {
    if (typeof t.cleanup === "function") t.cleanup()
  } catch (e) {
    t.threw.push(String(e))
  }
}

// The expected shim log, written as the states and replies in order:
// "working" is `roost state working`, R("x") is `roost reply -` with "x" on
// stdin.
const R = (text) => ({ reply: text })
const expect = async (label, t, want) => {
  await settle()
  check(verbs(), want.map((w) => (typeof w === "string" ? "state" : "reply")).join(","), `${label}: the calls, in order`)
  check(calls(), want.filter((w) => typeof w === "string").join(","), `${label}: the states`)
  check(
    JSON.stringify(replies()),
    JSON.stringify(want.filter((w) => typeof w !== "string").map((w) => w.reply)),
    `${label}: the replies`
  )
  check(
    `${replyVias()}|${envNames().every((n) => n === "opencode")}|${t.threw.length}`,
    `${want.filter((w) => typeof w !== "string").map(() => "stdin").join(",")}|true|0`,
    `${label}: every reply on stdin, ROOST_AGENT_NAME=opencode on every call, nothing thrown`
  )
}

// A checkpoint inside a replay: the states written so far.
const statesSoFar = (label, want) => async () => {
  await settle()
  check(calls(), want, label)
}

// --- The event cases ---
//
// Each is a replay of recorded rows with the front set once, on the case's
// chat, and never moved. Each runs twice: as recorded, and with the second
// chat's turn (tabs.jsonl lines 17–31) shuffled in, which must change nothing.
//
// Every list starts with R(""): setup's first pass writes the pane in full,
// and that begins with taking back whatever reply was stored on it.
//
// A replay starts at a turn's session.execution.started, not at the
// session.created or session.inbox.enqueued before it. Those rows carry the
// status opencode reported before the turn began, "idle", and an instance that
// has not heard a turn start reads the chat in front off status() — so
// replaying them adds an `idle` the expected lists below are not about.
const CASES = [
  {
    // fresh.jsonl lines 4–16: the first prompt, answered "first-turn" with no
    // tool.
    name: "a turn with no tool",
    front: PARENT,
    items: () => range(FRESH, 4, 16),
    want: [R(""), "working", R("first-turn"), "done"],
  },
  {
    // fresh.jsonl lines 41–105, the subagent run, with the child's events left
    // out and its first dialog (lines 63 and 64) moved onto the parent: a tool
    // of the chat's own behind a dialog, allowed once. No recording holds an
    // allowed dialog in the parent itself; the Reject one (line 116) is not
    // allowed.
    name: "a tool behind a dialog, allowed",
    front: PARENT,
    items: () => [
      ...range(FRESH, 41, 62, (r) => r.sid !== "1G3Yor"),
      moved(FRESH, 63, PARENT),
      moved(FRESH, 64, PARENT),
      ...range(FRESH, 65, 105, (r) => r.sid !== "1G3Yor"),
    ],
    want: [R(""), "working", "blocked", "working", R("sub-done"), "done"],
  },
  {
    // fresh.jsonl lines 41–105 whole: the `general` subagent, two dialogs of
    // its own (63/64 and 80/81), its execution.succeeded (94) before the
    // parent's (104). The child's dialogs are found through family(front);
    // the child's text (61, 78, 90) is never a reply and its succeeded writes
    // nothing.
    name: "a subagent with its own dialog",
    front: PARENT,
    family: { [PARENT]: [PARENT, CHILD] },
    items: () => range(FRESH, 41, 105),
    want: [R(""), "working", "blocked", "working", "blocked", "working", R("sub-done"), "done"],
  },
  {
    // fresh.jsonl lines 61–105: the same run with every event before the
    // child's first session.text.ended (61) withheld — the parent's
    // execution.started and the child's session.created among them, as after
    // a reload mid-subagent. Nothing may depend on having heard them.
    name: "a subagent's dialog, with everything before the child's first text withheld",
    front: PARENT,
    family: { [PARENT]: [PARENT, CHILD] },
    items: () => range(FRESH, 61, 105),
    want: [R(""), "working", "blocked", "working", "blocked", "working", R("sub-done"), "done"],
  },
  {
    // fresh.jsonl lines 41–64, the subagent run to its first dialog's answer,
    // with a second request opened for the parent while the child's is open
    // (line 63's payload, moved to the parent), and the parent's answered
    // last (line 64's, moved).
    name: "two dialogs open in one family; the first answered",
    front: PARENT,
    family: { [PARENT]: [PARENT, CHILD] },
    items: () => [
      ...range(FRESH, 41, 63),
      moved(FRESH, 63, PARENT, { id: "per_second_request" }),
      { ...step(at(FRESH, 64)), post: statesSoFar("two dialogs, one answered: still blocked", "working,blocked") },
      moved(FRESH, 64, PARENT, { requestID: "per_second_request" }),
    ],
    want: [R(""), "working", "blocked", "working"],
  },
  {
    // The dialog case above, with permission.sync rejecting on the pass that
    // permission.asked (line 63, moved to the parent) starts, and working on
    // the next.
    //
    // The adapter's first tick is taken first, on a settled pane, because it
    // re-asserts the state (a reload's guard): left for later, it would write
    // `blocked` twice whenever the shuffled-in chat's event ran the next pass
    // before the tick did.
    name: "permission.sync rejects on the first ask and works on the next",
    front: PARENT,
    items: () => [
      { ...tick(), pre: () => settle(), post: statesSoFar("the first tick writes the state once more", "working,working") },
      ...range(FRESH, 41, 62, (r) => r.sid !== "1G3Yor"),
      {
        ...moved(FRESH, 63, PARENT),
        pre: (t) => (t.syncPlan = ["reject"]),
        post: statesSoFar("a rejected sync writes nothing on its pass", "working,working"),
      },
      { ...tick(), post: statesSoFar("the next pass asks again and writes blocked", "working,working,blocked") },
      // And once more as the dialog closes (line 64, moved). On the first
      // ask, `working` was already on the pane, so writing nothing and writing
      // the phase look the same; here they do not. An answer that did not
      // come must leave `blocked` up, not guess `working` over a dialog that
      // may still be open.
      {
        ...moved(FRESH, 64, PARENT),
        pre: (t) => (t.syncPlan = ["reject"]),
        post: statesSoFar("a rejected sync as the dialog closes leaves blocked up", "working,working,blocked"),
      },
      {
        ...tick(),
        post: statesSoFar("the next pass asks again and writes working", "working,working,blocked,working"),
      },
      ...range(FRESH, 65, 105, (r) => r.sid !== "1G3Yor"),
    ],
    want: [R(""), "working", "working", "blocked", "working", R("sub-done"), "done"],
  },
  {
    // The same, with a permission.sync that never settles on that pass. A
    // tick right behind it starts the next pass; it waits for the stuck one,
    // which must give up at its 2-second limit.
    name: "permission.sync never settles",
    front: PARENT,
    items: () => [
      ...range(FRESH, 41, 62, (r) => r.sid !== "1G3Yor"),
      (() => {
        const asked = moved(FRESH, 63, PARENT)
        let began = 0
        return {
          evs: [...asked.evs, TICK],
          src: asked.src,
          pre: (t) => {
            t.syncPlan = ["hang"]
            began = Date.now()
          },
          post: async () => {
            while (!calls().includes("blocked") && Date.now() - began < 5000) await sleep(10)
            const took = Date.now() - began
            check(
              took >= 1900 && took < 3000,
              true,
              `a sync that never settles: the pass gives up at its limit and the next one writes blocked (took ${took} ms)`
            )
          },
        }
      })(),
      moved(FRESH, 64, PARENT),
      ...range(FRESH, 65, 105, (r) => r.sid !== "1G3Yor"),
    ],
    want: [R(""), "working", "blocked", "working", R("sub-done"), "done"],
  },
  {
    // fresh.jsonl lines 4–16, then 30–39: the first turn answered, then a long
    // turn ended with Esc Esc (session.execution.interrupted, reason "user",
    // line 38). The first answer must not be left standing for the second.
    name: "answered turn, then Esc Esc",
    front: PARENT,
    items: () => [...range(FRESH, 4, 16), ...range(FRESH, 30, 39)],
    want: [R(""), "working", R("first-turn"), "done", "working", R(""), "done"],
  },
  {
    // fresh.jsonl lines 4–16, then 106–121: the first turn answered, then a
    // dialog answered Reject (line 117), which opencode ends as interrupted,
    // reason "shutdown" (line 121).
    name: "answered turn, then Reject",
    front: PARENT,
    items: () => [...range(FRESH, 4, 16), ...range(FRESH, 106, 121)],
    want: [R(""), "working", R("first-turn"), "done", "working", "blocked", "working", R(""), "done"],
  },
  {
    // fresh.jsonl lines 4–16, then the same lines again without line 9, its
    // session.text.ended: a turn that succeeds with no prose.
    name: "answered turn, then a success with no prose",
    front: PARENT,
    items: () => [...range(FRESH, 4, 16), ...range(FRESH, 4, 16, (r) => r.line !== 9)],
    want: [R(""), "working", R("first-turn"), "done", "working", R(""), "done"],
  },
  {
    // dead-provider.jsonl lines 4–30: retry.scheduled attempts 2 (line 8) to
    // 11 (line 26), then execution.failed (line 29).
    name: "a dead provider",
    front: DEADCHAT,
    items: () =>
      range(DEAD, 4, 30).map((s) =>
        s.src.endsWith(":8")
          ? { ...s, post: statesSoFar("a dead provider: attempt 2 stays working", "working") }
          : s.src.endsWith(":10")
            ? { ...s, post: statesSoFar("a dead provider: error at attempt 3", "working,error") }
            : s.src.endsWith(":26")
              ? { ...s, post: statesSoFar("a dead provider: nothing more through attempt 11", "working,error") }
              : s
      ),
    want: [R(""), "working", "error", R("")],
  },
  {
    // dead-provider.jsonl lines 4–10, to `error` at attempt 3, then a dialog
    // opened and answered in that chat: fresh.jsonl lines 63 and 64, moved.
    name: "error at attempt 3, then a dialog answered",
    front: DEADCHAT,
    items: () => [...range(DEAD, 4, 10), moved(FRESH, 63, DEADCHAT), moved(FRESH, 64, DEADCHAT)],
    want: [R(""), "working", "error", "blocked", "working"],
  },
  {
    // fresh.jsonl lines 4–16 as A, in front, and tabs.jsonl's second chat
    // (lines 17–31) as B, its rows shuffled into A's. Only A is written.
    name: "two chats interleaved, front is A",
    front: PARENT,
    items: () => shuffle(range(FRESH, 4, 16), SECOND(), 7),
    want: [R(""), "working", R("first-turn"), "done"],
    once: true,
  },
  {
    // fresh.jsonl lines 4–12, then line 13 (execution.succeeded) and line 18
    // (the next turn's execution.started) delivered back to back: a queued
    // prompt starts the next turn before the pass that publishes has written.
    // That pass is already asking opencode when line 18 arrives, so it writes
    // the reply it owes and then finds the chat working again — the badge,
    // already `working`, is not written a second time.
    name: "A succeeds; a queued prompt starts A's next turn before the pass that publishes",
    front: PARENT,
    items: () => [
      ...range(FRESH, 4, 12),
      { evs: [...step(at(FRESH, 13)).evs, ...step(at(FRESH, 18)).evs], src: "fresh.jsonl:13+18" },
    ],
    want: [R(""), "working", R("first-turn")],
  },
]

// The status the spy recorded for the chat in front on the first of its rows
// the replay delivers.
const firstStatus = (items, front) => {
  const row = items.flatMap((i) => i.evs).find((e) => e.row?.status && full(e.row.route?.slice(8)) === front)?.row
  return row ? JSON.parse(row.status) : "idle"
}

for (const c of CASES) {
  for (const mixed of c.once ? [false] : [false, true]) {
    const label = mixed ? `${c.name} (a second chat shuffled in)` : c.name
    const own = c.items()
    const items = mixed ? shuffle(own, SECOND(), caseNo + 1) : own
    const t = await start(label, (t) => {
      t.on(c.front)
      Object.assign(t.family, c.family ?? {})
      // The chat in front as it stood when the replay's first row was taken.
      t.status[c.front] = firstStatus(own, c.front)
    })
    if (!t) continue
    await t.replay(items)
    await expect(label, t, c.want)
    await finish(t)
  }
}

// --- 201 chats ---
//
// Synthetic ids: there is no recording of 201 chats. Each runs a turn while
// the home screen is in front, so the map grows to 201 and the oldest finished
// entry is evicted. Brought to the front, the evicted chat is unknown and reads
// off status(): an empty reply (the front changed), then `idle`. The second
// oldest, still held, is the control: it reads `done`.
{
  const label = "201 chats, the oldest evicted"
  const t = await start(label)
  if (t) {
    const ids = Array.from({ length: 201 }, (_, i) => `ses_synthetic${String(i).padStart(4, "0")}`)
    const of = (name, sessionID) => ({ event: { name, details: { data: { sessionID } } } })
    for (const id of ids) {
      t.deliver(of("session.execution.started", id))
      t.deliver(of("session.execution.succeeded", id))
    }
    await settle()
    check(calls(), "idle", `${label}: the home screen reads idle, and the 201st chat does not throw`)
    t.status[ids[0]] = "idle"
    t.on(ids[0])
    t.deliver(TICK)
    await settle()
    check(verbs(), "reply,state,reply,state", `${label}: brought to the front, it clears the reply and then writes a state`)
    check(calls(), "idle,idle", `${label}: the evicted chat reads idle`)
    t.on(ids[1])
    t.deliver(TICK)
    await expect(label, t, [R(""), "idle", R(""), "idle", R(""), "done"])
    await finish(t)
  }
}

// --- Front changes, the timer, setup, and a reload ---
//
// No event says the chat in front changed (switching tabs emits nothing), so
// in these cases the front is moved by hand and only the adapter's 1-second
// interval can notice: deliver(TICK) is mock.timers.tick(1000).

// The timer-only case, a function of the adapter file so that the mutation
// run below can replay it against a copy with the interval removed.
// tabs.jsonl lines 4–16 (chat A's turn, answered "chat-A") with A in front,
// then lines 19–31 (chat B's turn) while A is still in front, so both chats
// have finished. Then A → B → A → B with no event at all, one tick after each.
// The record cannot grow: no switch may write a non-empty reply.
const CHAT_A = full("klEg7i") // tabs.jsonl's first chat
const timerOnly = async (label, adapter = ADAPTER) => {
  const items = [...range(TABS, 4, 16), ...range(TABS, 19, 31)]
  const t = await start(
    label,
    (t) => {
      t.on(CHAT_A)
      t.status[CHAT_A] = firstStatus(items, CHAT_A)
    },
    adapter
  )
  if (!t) return
  await t.replay(items)
  await settle()
  for (const [n, id] of [OTHER, CHAT_A, OTHER].entries()) {
    const before = cols().length
    t.on(id)
    t.deliver(TICK)
    await settle()
    check(
      cols().slice(before).map((c) => `${c[0]} ${c[1]}`).join(","),
      `reply ,state done`,
      `${label}: switch ${n + 1} writes an empty reply, then the state`
    )
  }
  await expect(label, t, [R(""), "working", R("chat-A"), "done", R(""), "done", R(""), "done", R(""), "done"])
  await finish(t)
}
await timerOnly("front A → B → A → B, all finished, no events, ticks only")

{
  // The home screen at setup; then the front moves to a chat with a request
  // pending that this instance never heard asked — fresh.jsonl line 116's
  // request, in its own chat.
  const label = "front → a chat with an open dialog this instance never heard"
  const t = await start(label)
  if (t) {
    await settle()
    t.status[PARENT] = "running"
    t.pending[PARENT] = [payloadOf(at(FRESH, 116))]
    t.on(PARENT)
    t.deliver(TICK)
    await expect(label, t, [R(""), "idle", R(""), "blocked"])
    await finish(t)
  }
}

{
  // fresh.jsonl lines 4–16, the first turn answered; then the home screen.
  const label = "front → home"
  const items = range(FRESH, 4, 16)
  const t = await start(label, (t) => {
    t.on(PARENT)
    t.status[PARENT] = firstStatus(items, PARENT)
  })
  if (t) {
    await t.replay(items)
    await settle()
    t.on(null)
    t.deliver(TICK)
    await expect(label, t, [R(""), "working", R("first-turn"), "done", R(""), "idle"])
    await finish(t)
  }
}

{
  // A new opencode started in a pane that still shows another chat's `done`
  // and answer: the log is seeded with those two rows before setup. setup
  // takes the answer back and writes what it finds; the first tick asserts the
  // state once more and does not clear the reply a second time.
  const label = "setup on an idle chat, in a pane holding another chat's done and reply"
  const t = await start(label, (t) => {
    t.on(PARENT)
    t.status[PARENT] = "idle"
    writeFileSync(log, `state\tdone\topencode\targv\nreply\tanother chat's answer\topencode\tstdin\n`)
  })
  if (t) {
    await settle()
    t.deliver(TICK)
    await expect(label, t, ["done", R("another chat's answer"), R(""), "idle", "idle"])
    await finish(t)
  }
}

for (const [what, pending, want] of [
  ["running", false, "working"],
  ["running, with a request pending", true, "blocked"],
]) {
  // fresh.jsonl line 116's request, when there is one.
  const label = `setup on a chat that is ${what}`
  const t = await start(label, (t) => {
    t.on(PARENT)
    t.status[PARENT] = "running"
    if (pending) t.pending[PARENT] = [payloadOf(at(FRESH, 116))]
  })
  if (t) {
    await expect(label, t, [R(""), want])
    await finish(t)
  }
}

{
  // setup mid-turn — the turn's execution.started never heard — then
  // fresh.jsonl lines 7–16, the rest of the first turn, before the first tick.
  // The tick writes `done` again and does not clear the reply just published.
  const label = "setup mid-turn; the turn succeeds with text before the first tick"
  const t = await start(label, (t) => {
    t.on(PARENT)
    t.status[PARENT] = "running"
  })
  if (t) {
    await t.replay(range(FRESH, 7, 16))
    await settle()
    t.deliver(TICK)
    await expect(label, t, [R(""), "working", R("first-turn"), "done", "done"])
    await finish(t)
  }
}

{
  // With every `roost reply` slowed to 400 ms: fresh.jsonl lines 4–12, then
  // line 13 (execution.succeeded) starts the publish of "first-turn", and
  // while it is in flight the front moves to another chat, running. The pass
  // that resumes must not finish A's turn on a pane now about B.
  const label = "a slow reply: the front moves while A's publish is in flight"
  slowShim("reply")
  const t = await start(label, (t) => {
    t.on(PARENT)
    t.status[PARENT] = "running"
  })
  if (t) {
    await t.replay(range(FRESH, 4, 12))
    t.deliver(step(at(FRESH, 13)).evs[0])
    await sleep(100)
    check(started() > rows().length, true, `${label}: A's publish is in flight when the front moves`)
    t.status[OTHER] = "running"
    t.on(OTHER)
    t.deliver(TICK)
    await settle()
    const states = calls().split(",")
    const said = replies()
    check(`${states.at(-1)}|${JSON.stringify(said.at(-1))}`, `working|""`, `${label}: the last state is B's, the last reply the empty one`)
    await expect(label, t, [R(""), "working", R("first-turn"), R(""), "working"])
    await finish(t)
  }
  plainShim()
}

{
  // With every `roost reply` slowed: setup's own clear holds the first pass
  // while fresh.jsonl lines 4–16 — A's whole first turn, answered — arrive,
  // and the front moves to B before that pass ends. A owed a reply, but it
  // left the front first. Then A runs a turn while hidden (lines 30–39, ended
  // with Esc Esc) and is brought back.
  const label = "A's owed reply dies when A leaves the front"
  slowShim("reply")
  const t = await start(label, (t) => {
    t.on(PARENT)
    t.status[PARENT] = "running"
  })
  if (t) {
    for (const s of range(FRESH, 4, 16)) for (const e of s.evs) t.deliver(e)
    t.status[OTHER] = "idle"
    t.on(OTHER)
    await settle()
    await t.replay(range(FRESH, 30, 39))
    t.on(PARENT)
    t.deliver(TICK)
    await settle()
    check(
      JSON.stringify(replies().filter((r) => r !== "")),
      "[]",
      `${label}: no non-empty reply is ever written`
    )
    await expect(label, t, [R(""), R(""), "idle", R(""), "done"])
    await finish(t)
  }
  plainShim()
}

{
  // fresh.jsonl lines 41–63: the subagent run to the child's first
  // permission.asked, with the fake family(front) not yet listing the child —
  // as at its creation, measured 250 ms behind (family-timing.jsonl). On that
  // pass the request is not found; once the family lists the child, the next
  // tick finds it.
  const label = "a child's dialog, asked one pass before family() lists it"
  const items = [
    ...range(FRESH, 41, 62),
    { ...step(at(FRESH, 63)), post: statesSoFar(`${label}: working on that pass`, "working") },
  ]
  const t = await start(label, (t) => {
    t.on(PARENT)
    t.family[PARENT] = [PARENT]
    t.status[PARENT] = firstStatus(items, PARENT)
  })
  if (t) {
    await t.replay(items)
    t.family[PARENT] = [PARENT, CHILD]
    t.deliver(TICK)
    await expect(label, t, [R(""), "working", "blocked"])
    await finish(t)
  }
}

{
  // dead-provider.jsonl lines 4–7, a dialog opened in that chat (fresh.jsonl
  // line 63, moved), line 28, then line 29 — execution.failed — with no
  // permission.replied and the request gone from permission.list, as a turn's
  // end takes its dialog with it.
  const label = "a dialog open, then the turn fails with no permission.replied"
  const items = [
    ...range(DEAD, 4, 7),
    moved(FRESH, 63, DEADCHAT),
    step(at(DEAD, 28)),
    { ...step(at(DEAD, 29)), pre: (t) => (t.pending[DEADCHAT] = []) },
  ]
  const t = await start(label, (t) => {
    t.on(DEADCHAT)
    t.status[DEADCHAT] = firstStatus(items, DEADCHAT)
  })
  if (t) {
    await t.replay(items)
    await expect(label, t, [R(""), "working", "blocked", R(""), "error"])
    await finish(t)
  }
}

{
  // A reload: the old instance's cleanup runs while its setup pass is inside
  // a slow `roost reply`, with fresh.jsonl lines 4–16 already heard — so it
  // has a reply and a `done` it would write next. After cleanup it must start
  // no new call; the one in flight is left to finish. Then a new instance is
  // set up: it writes the pane in full, and its first tick writes the state
  // again.
  const label = "a reload"
  slowShim("state|reply")
  const old = await start(label, (t) => {
    t.on(PARENT)
    t.status[PARENT] = "running"
  })
  if (old) {
    for (const s of range(FRESH, 4, 16)) for (const e of s.evs) old.deliver(e)
    // The shim records its start a moment after the spawn; wait for it, so
    // the count taken at cleanup includes the call in flight.
    //
    // Waited on the way settle() waits: on what the adapter is doing, not on
    // a fixed timer. A `roost` child running, or a call on the fake context,
    // means the call is still on its way and the clock starts again; only 2 s
    // with neither gives up. A bare 200 × 10 ms gave up on a loaded machine
    // (three suites at once, 3 of 13 runs) while the shim's `sh` was still
    // starting, and the case then read the call the adapter had already
    // issued as one started after cleanup: `want [1|1|1] got [0|1|1]`.
    // 30 s is the ceiling either way, so a pass that never calls cannot hang
    // the file.
    const waitedFor = await (async () => {
      const t0 = Date.now()
      let last = activity
      let since = t0
      while (started() < 1) {
        if (Date.now() - since > 2000) return "2 s with no child running and no call on the context"
        if (Date.now() - t0 > 30000) return "the 30 s ceiling"
        await sleep(10)
        if (children() > 0 || activity !== last) {
          last = activity
          since = Date.now()
        }
      }
      return ""
    })()
    // Move the front before cleanup. With the front still on the chat it
    // wrote, a pass after dispose finds nothing to clear and goes straight to
    // ask(), whose own `disposed` check ends it — so the loop's `!disposed`
    // guard in reconcile() would go untested. With the front moved, that
    // extra pass would enter step 1 and run `roost reply -` after dispose:
    // the guard is then the only thing standing between cleanup and a second
    // call.
    old.on(OTHER)
    await finish(old)
    const atCleanup = started()
    old.deliver(TICK)
    await settle()
    // A bound that tripped is reported as itself. Read as a count, it would
    // blame the adapter for a call the harness never saw start.
    check(
      waitedFor ? `the wait for the shim's start line gave up after ${waitedFor}` : `${atCleanup}|${started()}|${rows().length}`,
      `1|1|1`,
      `${label}: after cleanup the old instance starts no new call, and its call in flight finishes`
    )
    plainShim()
    const t = await start(label, (t) => {
      t.on(PARENT)
      t.status[PARENT] = "idle"
    })
    if (t) {
      await settle()
      t.deliver(TICK)
      await expect(`${label}: the new instance`, t, [R(""), "idle", "idle"])
      await finish(t)
    }
  }
  plainShim()
}

{
  // The mutation: the same timer-only case against a copy of tui.js with its
  // `setInterval(` line deleted. If that copy passes, the case is not testing
  // the timer. The copy is .mjs so it loads as a module wherever it sits.
  let lines = []
  try {
    lines = readFileSync(ADAPTER, "utf8").split("\n")
  } catch {}
  const hits = lines.filter((l) => l.includes("setInterval(")).length
  const copy = join(dir, "tui-no-timer.mjs")
  writeFileSync(copy, lines.filter((l) => !l.includes("setInterval(")).join("\n"))
  // A copy that fails to import fails start()'s own check, which would count
  // as a failure here too: the run must also show the copy loaded, or a
  // deletion that broke the file would pass for one that removed the timer.
  muted = { failed: 0, loaded: 0 }
  await timerOnly("the timer-only case without the timer", copy)
  const { failed, loaded } = muted
  muted = null
  check(`${hits}|${loaded}|${failed > 0}`, "1|1|true", "the timer-only case fails without the timer")
}

// --- Who the agent is (#141) ---
//
// reconcile() identifies the pane when the chat in front is not the one it
// last identified: `roost identify --session <front> --cwd <process.cwd()>
// --harness opencode`, before that pass's state, and never for the home
// screen. No --transcript: opencode 2 keeps its conversations in its own
// storage. The directory is the TUI process's own, so each case runs from a
// directory of its own making, and the expected --cwd is read back from
// process.cwd() there.
const idOf = (id, cwd) => `identify|--session|${id}|--cwd|${cwd}|--harness|opencode`
const inOwnDir = async (name, fn) => {
  const home = process.cwd()
  const own = join(dir, name)
  mkdirSync(own)
  process.chdir(own)
  try {
    await fn(process.cwd())
  } finally {
    process.chdir(home)
  }
}
await inOwnDir("cwd-fresh", async (cwd) => {
  const label = "identity: a fresh chat, then a second turn in it"
  const t = await start(label, (t) => {
    t.on(PARENT)
    t.status[PARENT] = firstStatus(range(FRESH, 4, 16), PARENT)
  })
  if (!t) return
  await t.replay(range(FRESH, 4, 16))
  await settle()
  check(identifies().join(","), idOf(PARENT, cwd), `${label}: the chat in front is identified once, with process.cwd() as --cwd`)
  const order = allCols().map((c) => c[0])
  check(order.indexOf("identify") >= 0 && order.indexOf("identify") < order.indexOf("state"), true,
    `${label}: before its first state`)
  check(allCols().filter((c) => c[0] === "identify").map((c) => c[2]).join(","), "opencode",
    `${label}: with ROOST_AGENT_NAME=opencode`)
  await t.replay(range(FRESH, 41, 105, (r) => r.sid !== "1G3Yor"))
  t.deliver(TICK)
  await settle()
  check(identifies().length, 1, `${label}: a second turn and a tick in the same chat identify nothing more`)
  await finish(t)
})
await inOwnDir("cwd-tabs", async (cwd) => {
  const label = "identity: tabs.jsonl, then the front changes"
  const items = [...range(TABS, 4, 16), ...range(TABS, 19, 31)]
  const t = await start(label, (t) => {
    t.on(CHAT_A)
    t.status[CHAT_A] = firstStatus(items, CHAT_A)
  })
  if (!t) return
  await t.replay(items)
  await settle()
  check(identifies().join(","), idOf(CHAT_A, cwd), `${label}: B's turn while A is in front identifies only A`)
  // One switch at a time: only the rows that switch's own pass wrote are
  // looked at, so a later switch's state cannot stand in for this one's.
  for (const [n, id] of [OTHER, CHAT_A].entries()) {
    const before = allCols().length
    t.on(id)
    t.deliver(TICK)
    await settle()
    const order = allCols().slice(before).map((c) => c[0])
    check(order.indexOf("identify") >= 0 && order.indexOf("identify") < order.indexOf("state"), true,
      `${label}: switch ${n + 1} identifies before its state`)
  }
  check(identifies().join(","), [CHAT_A, OTHER, CHAT_A].map((id) => idOf(id, cwd)).join(","),
    `${label}: each change of the chat in front identifies it again`)
  await finish(t)
})
{
  const label = "identity: the home screen"
  const t = await start(label)
  if (t) {
    await t.replay(range(FRESH, 4, 16))
    t.deliver(TICK)
    await settle()
    check(identifies().length, 0, `${label}: with no chat in front, nothing is identified`)
    t.on(PARENT)
    t.deliver(TICK)
    await settle()
    t.on(null)
    t.deliver(TICK)
    await settle()
    check(identifies().length, 1, `${label}: going back to it identifies nothing and clears nothing`)
    await finish(t)
  }
}

// --- Nothing throws ---
//
// No `roost` on PATH, an event with no session id, an event of a type nobody
// knows, a null payload, a null event — and a context with the listener or
// the router missing, which leaves the pane unbadged rather than broken.
{
  const label = "no roost on PATH, and malformed events"
  const empty = join(dir, "empty")
  mkdirSync(empty)
  process.env.PATH = empty
  const t = await start(label)
  if (t) {
    t.on(PARENT)
    for (const event of [
      { name: "session.execution.started", details: { data: {} } },
      { name: "session.text.ended", details: { data: { text: "no id" } } },
      { name: "no.such.event", details: { data: { sessionID: PARENT } } },
      { name: "session.execution.succeeded", details: { data: null } },
      { name: "session.execution.succeeded", details: null },
      { name: "session.execution.started", details: { data: { sessionID: PARENT } } },
      { name: "session.execution.succeeded", details: { data: { sessionID: PARENT } } },
      {},
      null,
      undefined,
    ]) {
      t.deliver({ event })
      await quiet()
    }
    await settle()
    process.env.PATH = `${dir}:${REAL_PATH}`
    check(`${rows().length}|${t.threw.length}`, "0|0", `${label}: nothing written, nothing thrown`)
    await finish(t)
  }
  process.env.PATH = `${dir}:${REAL_PATH}`
}
{
  const label = "a context with no listener or no router"
  let threw = 0
  let loaded = true
  for (const context of [undefined, null, {}, { data: {} }, { data: { listen: () => () => {} } }, { ui: { router: {} } }]) {
    caseNo++
    if (existsSync(log)) rmSync(log)
    try {
      const mod = await import(`${pathToFileURL(ADAPTER).href}?case=${caseNo}`)
      try {
        const cleanup = mod.default.setup(context)
        if (typeof cleanup === "function") cleanup()
      } catch {
        threw++
      }
    } catch {
      loaded = false
    }
  }
  await settle()
  check(`${loaded}|${threw}|${rows().length}`, "true|0|0", `${label}: setup does not throw and writes nothing`)
}

check(escaped.join("; "), "", "nothing escaped the adapter: no uncaught exception, no unhandled rejection")

mock.timers.reset()
rmSync(dir, { recursive: true, force: true })
console.log(`  (${pass} passed, ${fail} failed in the opencode 2 plugin harness)`)
process.exit(0)
