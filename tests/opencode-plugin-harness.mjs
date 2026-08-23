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
writeFileSync(
  shim,
  `#!/bin/sh\nesc=\`printf '%s' "$2" | tr '\\n' '\\036'\`\nprintf '%s\\t%s\\t%s\\n' "$1" "$esc" "\${ROOST_AGENT_NAME:-}" >> "${log}"\n`
)
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
const cols = () => rows().map((r) => r.split("\t"))
// Only `state` rows, so every pre-existing assertion below keeps meaning what
// it meant before `reply` rows could appear in the same log.
const calls = () => cols().filter((c) => c[0] === "state").map((c) => c[1]).join(",")
const replies = () => cols().filter((c) => c[0] === "reply").map((c) => c[1].replace(/\x1e/g, "\n"))
// The verbs in order, which is what the reply-before-done assertions are about.
const verbs = () => cols().map((c) => c[0]).join(",")
const envNames = () => cols().map((c) => c[2])

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
// The reply-carrying events, shaped exactly as a live opencode 1.18.20 turn
// emits them (verified against a real model call, not against the type
// definitions — which declare a session.next.text.ended event that never
// fires). message.updated announces the assistant message id BEFORE any of its
// parts arrive; each part then arrives on message.part.updated carrying the
// WHOLE text so far, not a delta.
const assistant = (id) => ({ type: "message.updated", properties: { info: { role: "assistant", id } } })
const user = (id) => ({ type: "message.updated", properties: { info: { role: "user", id } } })
const part = (messageID, type, text, extra = {}) => ({
  type: "message.part.updated",
  properties: { part: { messageID, type, text, ...extra } },
})

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

// --- a turn that died on the provider must not end `done` ---
//
// The interleave below is the recorded one: tests/live/opencode-smoke.sh case 2
// against http://127.0.0.1:1/v1 on opencode 1.18.20, five retries with
// exponential backoff, each preceded by its own busy, then session.error and a
// session.idle in the same millisecond. That trailing idle is the whole bug —
// it used to append `done` to a turn that never reached the model.
const DEAD_PROVIDER = [
  status("busy"), status("retry"),   // attempt 1
  status("busy"), status("retry"),   // attempt 2 — the pane badges error here
  status("busy"), status("retry"),   // attempt 3
  status("busy"), status("retry"),   // attempt 4
  status("busy"), status("retry"),   // attempt 5, the last one
  errored("APIError"),
  plain("session.idle"),
]

fire = await fresh()
await fire(...DEAD_PROVIDER)
check(calls(), "working,error", "a turn that died on the provider ends error — its trailing session.idle does not overwrite that with done")

// The other half of the fix, and the more important one to keep green: a badge
// that sticks on error forever is a worse bug than the one above.
fire = await fresh()
await fire(...DEAD_PROVIDER, status("busy"), plain("session.idle"))
check(calls(), "working,error,working,done", "the very next healthy turn still reaches done — the suppression is released by the turn that follows, not held for the session")

fire = await fresh()
await fire(...DEAD_PROVIDER, ...DEAD_PROVIDER)
check(calls(), "working,error,working,error", "a second dead turn badges working at its start and error again at its end, rather than sitting silently on the first turn's error")

// The recovery case the suppression must NOT catch. Two retries badge error,
// then the provider answers and the turn genuinely completes. There is no
// session.error, so this idle is a real end-of-turn and still means done.
// Keying the suppression on the badge instead of on session.error would leave
// this turn reading error after it succeeded.
fire = await fresh()
await fire(status("busy"), status("retry"), status("retry"), status("busy"), plain("session.idle"))
check(calls(), "working,error,done", "a turn that retried twice and then SUCCEEDED still reports done — retries alone do not suppress it, only session.error does")

// No retries at all: a provider that fails outright still ends error.
fire = await fresh()
await fire(status("busy"), errored("APICallError"), plain("session.idle"))
check(calls(), "working,error", "a session.error with no retries before it also swallows the following idle")

// Esc during a retry loop. session.error carries MessageAbortedError, which
// does not mark the turn dead, so the turn ends done as it did before — the
// person who ended it is sitting at the pane.
fire = await fresh()
await fire(status("busy"), status("retry"), status("retry"), errored("MessageAbortedError"), plain("session.idle"))
check(calls(), "working,error,done", "pressing Esc out of a retry loop still ends done, not error")

// The second clear: a permission dialog is proof the turn reached the model,
// so it releases the badge even though no busy was seen first.
fire = await fresh()
await fire(status("busy"), errored("APIError"), plain("session.idle"), plain("permission.asked"), plain("permission.replied"), plain("session.idle"))
check(calls(), "working,error,blocked,working,done", "a permission dialog after a dead turn also releases the error, and that turn can reach done")

// Repeated idles after a dead turn must stay suppressed. opencode emits one,
// but a badge that could be un-suppressed by a duplicate would be a bug that
// only ever appeared in the field.
fire = await fresh()
await fire(...DEAD_PROVIDER, plain("session.idle"), plain("session.idle"))
check(calls(), "working,error", "a repeated session.idle after a dead turn does not leak a done through")

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

// This one carries a second job since the dead-turn suppression landed: a
// child's session.error must not mark the PARENT's turn dead either, or one
// failing subagent would swallow the `done` of a parent turn that finished
// fine. The child filter runs before the mapping, so it never reaches `died` —
// this case is what keeps that true.
fire = await fresh()
await fire(
  born(PARENT, undefined),
  from(PARENT, status("busy")),
  born(CHILD, PARENT),
  from(CHILD, errored("APICallError")),
  from(PARENT, plain("session.idle"))
)
check(calls(), "working,done", "a subagent's session.error does not badge the pane error, and does not suppress the parent's done")

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
// --- the reply channel ------------------------------------------------------

// The full shape of a real turn, in the order a live run produced it.
fire = await fresh()
await fire(
  status("busy"),
  assistant("msg_a"),
  part("msg_a", "reasoning", "the user wants two lines, let me…"),
  part("msg_a", "text", ""),
  part("msg_a", "text", "PLUM-ONE\nPLUM-TWO"),
  plain("session.idle")
)
check(replies().join("|"), "PLUM-ONE\nPLUM-TWO", "the assistant's text part is published as the reply")
check(verbs(), "state,reply,state", "the reply is published BEFORE done is reported")
check(calls(), "working,done", "publishing a reply does not disturb the state machine")

// Reasoning arrives on the SAME event with a different part type. Publishing it
// would post the model's private thinking as its answer to another agent.
fire = await fresh()
await fire(status("busy"), assistant("msg_a"), part("msg_a", "reasoning", "thinking out loud"), plain("session.idle"))
check(replies().join("|"), "", "a reasoning part is never published as the reply")

// The USER's own prompt arrives on the same event with the same part type
// "text" — only the message id tells them apart.
fire = await fresh()
await fire(status("busy"), user("msg_u"), part("msg_u", "text", "the human's prompt"), plain("session.idle"))
check(replies().join("|"), "", "a text part belonging to the user's message is not the reply")

// The same part id is re-sent as it grows, so the last one is the whole text.
fire = await fresh()
await fire(
  status("busy"), assistant("msg_a"),
  part("msg_a", "text", "PLU"), part("msg_a", "text", "PLUM-O"), part("msg_a", "text", "PLUM-ONE"),
  plain("session.idle")
)
check(replies().join("|"), "PLUM-ONE", "a growing text part is replaced, not appended")

// Several text parts split by a tool call: keep the LAST, which is what Claude
// Code's last_assistant_message returns for the same shape.
fire = await fresh()
await fire(
  status("busy"), assistant("msg_a"),
  part("msg_a", "text", "let me check that"),
  part("msg_a", "tool", ""),
  part("msg_a", "text", "the answer is 42"),
  plain("session.idle")
)
check(replies().join("|"), "the answer is 42", "with several text parts, the last one is the reply")

// synthetic parts are opencode's own injected text, not something the agent said
fire = await fresh()
await fire(status("busy"), assistant("msg_a"), part("msg_a", "text", "injected", { synthetic: true }), plain("session.idle"))
check(replies().join("|"), "", "a synthetic text part is not published as the reply")

// A turn that errors has no answer, and holding the half-built one would let it
// attach to the NEXT turn — a stale reply served as if it were fresh.
fire = await fresh()
await fire(status("busy"), assistant("msg_a"), part("msg_a", "text", "half an ans"), errored("APICallError"))
check(replies().join("|"), "", "a turn that errors publishes no reply")

// A new assistant message drops whatever the previous one left pending, so one
// turn's text can never be published as the next turn's reply.
fire = await fresh()
await fire(
  status("busy"), assistant("msg_a"), part("msg_a", "text", "first turn"), plain("session.idle"),
  status("busy"), assistant("msg_b"), plain("session.idle")
)
check(replies().join("|"), "first turn", "a second turn with no text of its own publishes nothing")

// An idle with nothing pending must not fire a `roost reply` at all: an empty
// reply would be stored, read as present, and returned as the agent's answer.
fire = await fresh()
await fire(status("busy"), plain("session.idle"))
check(verbs(), "state,state", "an idle with no text produces no reply call")

// --- the reply channel meets subagents --------------------------------------
//
// Neither the subagent filter nor the reply channel is wrong on its own; the
// interaction is. A child session's message events are on the same bus, and
// they carry a DIFFERENT assistant message id. Left unfiltered they take over
// `assistantID`, which does two bad things at once: the child's text becomes
// the pane's reply, and the parent's own later text is then rejected for not
// matching the id — so the wrong answer also crowds out the right one.
//
// The interleave replayed here is the real one: the parent starts, answers a
// bit, calls the task tool, the child runs and answers, then the parent
// finishes.

fire = await fresh()
await fire(
  born(PARENT, undefined),
  from(PARENT, status("busy")),
  from(PARENT, assistant("msg_p")),
  born(CHILD, PARENT),
  from(CHILD, status("busy")),
  from(CHILD, assistant("msg_c")),
  from(CHILD, part("msg_c", "text", "SUBAGENT OUTPUT")),
  from(CHILD, plain("session.idle")),
  from(PARENT, status("busy")),
  from(PARENT, part("msg_p", "text", "THE PARENT ANSWER")),
  from(PARENT, plain("session.idle"))
)
check(replies().join("|"), "THE PARENT ANSWER", "a subagent's text is not published as the pane's reply")
check(calls(), "working,done", "...and the subagent's idle still does not badge the pane done")

// The compounding half, asserted on its own: the parent's answer must survive a
// subagent running in the middle of its message. Before the fix `assistantID`
// pointed at the child's message by this point, so the parent's own text part
// was dropped and the pane published the child's text instead.
fire = await fresh()
await fire(
  born(PARENT, undefined),
  from(PARENT, status("busy")),
  from(PARENT, assistant("msg_p")),
  from(PARENT, part("msg_p", "text", "let me delegate that")),
  born(CHILD, PARENT),
  from(CHILD, assistant("msg_c")),
  from(CHILD, part("msg_c", "text", "SUBAGENT OUTPUT")),
  from(CHILD, plain("session.idle")),
  from(PARENT, part("msg_p", "text", "done: the answer is 42")),
  from(PARENT, plain("session.idle"))
)
check(replies().join("|"), "done: the answer is 42", "a subagent does not hijack the parent's assistant message id")

// A turn where only the subagent spoke publishes NOTHING rather than the
// child's text. That leaves `roost read` falling back to the screen with its
// notice, which is the honest outcome: the pane's own agent did not answer.
// Publishing the child's output instead would be a confident wrong answer,
// which is the failure this whole mechanism exists to remove.
fire = await fresh()
await fire(
  born(PARENT, undefined),
  from(PARENT, status("busy")),
  born(CHILD, PARENT),
  from(CHILD, assistant("msg_c")),
  from(CHILD, part("msg_c", "text", "SUBAGENT OUTPUT")),
  from(CHILD, plain("session.idle")),
  from(PARENT, plain("session.idle"))
)
check(replies().join("|"), "", "a turn where only the subagent spoke publishes no reply")
check(verbs(), "state,state", "...and fires no reply call at all")

// The mute must be scoped to child sessions, not to the event type: the
// parent's own message events have to keep working after a subagent has run,
// or the pane would never publish a reply again for the rest of its life.
fire = await fresh()
await fire(
  born(PARENT, undefined),
  born(CHILD, PARENT),
  from(CHILD, assistant("msg_c")),
  from(CHILD, part("msg_c", "text", "SUBAGENT OUTPUT")),
  from(CHILD, plain("session.idle")),
  from(PARENT, status("busy")),
  from(PARENT, assistant("msg_p")),
  from(PARENT, part("msg_p", "text", "a later, unrelated turn")),
  from(PARENT, plain("session.idle"))
)
check(replies().join("|"), "a later, unrelated turn", "the parent can still publish a reply after a subagent has run")

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
