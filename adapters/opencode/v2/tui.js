// tui.js — report an opencode 2 agent's state onto its tmux pane.
//
// opencode 2 changed what a plugin is, so this is a second adapter beside the
// 1.x one (adapters/opencode/roost.js), not a change to it. The measurements
// behind every choice here are on #150 and in tests/fixtures/opencode2/ — its
// README says what each recording holds — and the design that reads them is
// docs/airig/specs/2026-10-02-opencode-2-adapter-design.md.
//
// It is a TERMINAL-SIDE plugin, not a server one, because of where each runs.
// On 2.0.20 a server plugin (`<config>/opencode/plugins/x.js`) runs in
// `opencode serve --service`, a process whose parent is pid 1, and it sees the
// TMUX_PANE of whoever started the service — not the pane it would be badging.
// A terminal-side plugin (`<config>/opencode/plugins/<name>/tui.js`) runs in the
// TUI, the child of the pane's own shell, so `roost state` finds the right pane
// from $TMUX_PANE with nothing to pass around, as on 1.x. A plain default export
// `{ id, setup(context) }` loads; no import of opencode's plugin package is
// needed, so this stays one dependency-free file.
//
// Two things the TUI does are why this file is shaped the way it is:
//
// - Every terminal hears every chat. `context.data.listen` delivers the
//   server's events, and a turn typed in pane %1 was delivered whole to the
//   plugin in pane %0. What tells two terminals apart is
//   `context.ui.router.current()`: the chat this terminal is showing.
// - Switching the chat in front emits no event at all.
//
// So events here only update a model of what is known, and one serial
// `reconcile()` makes the pane match the model for the chat in front. It is the
// only code that runs `roost`. The 1.x adapter turns each event straight into a
// `roost` call; that shape does not survive a front that changes silently and
// two callers that each await a child process, because two awaits can finish
// in either order and the last writer wins.

// node:child_process, not opencode's Bun `$` shell. It behaves identically
// under Bun (which runs the plugin) and under plain Node (which runs the
// offline test), so the test exercises the real invocation path instead of a
// mock. execFile also takes an argv array, so no shell quoting is involved.
import { execFile } from "node:child_process"

// Never throws. A missing roost, a dead tmux server, or a pane that went away
// must leave the pane unbadged, never break the agent being badged — the same
// discipline as the `|| true` on every tmux call in scripts/roost-agent-state.
const run = (args, input) =>
  new Promise((resolve) => {
    try {
      // ROOST_AGENT_NAME tells roost-agent-state's sink what to label an
      // unnamed pane, instead of falling back to @roost-name-default's
      // Claude-flavoured "claude" — every opencode pane would otherwise
      // read "claude" on its border and in the switcher.
      const child = execFile(
        "roost",
        args,
        { env: { ...process.env, ROOST_AGENT_NAME: "opencode" }, timeout: 5000 },
        () => resolve()
      )
      // The reply text goes on the child's STDIN. Two things have to be true
      // for that to be as safe as the argv call it replaces:
      //
      // `roost reply` is a deliberate silent no-op when this process is not a
      // pane on roost's own server — that is what makes an adapter safe to
      // leave installed when its agent runs somewhere else. roost then exits 0
      // WITHOUT reading, and the write lands on a closed pipe. The EPIPE that
      // follows arrives as an `error` event on the stream, and an unhandled
      // one on a child's stdin takes the whole agent down — the exact outcome
      // this helper exists to prevent. So it is swallowed, like everything
      // else here.
      child.stdin?.on("error", () => {})
      // And stdin is ALWAYS ended, including for the calls that send nothing.
      // execFile hands the child a pipe that is otherwise never closed, so a
      // roost subcommand that reads stdin would wait on it until the timeout.
      child.stdin?.end(input ?? "")
    } catch {
      resolve()
    }
  })

const report = (state) => run(["state", state])

// The reply goes over STDIN, not argv (#86). Linux caps a SINGLE argv entry at
// 131072 bytes (MAX_ARG_STRLEN), separately from the far larger ARG_MAX total,
// so a long reply failed inside execFile before roost ran at all: the pane kept
// no record, and a sibling's `roost read` fell back to scraping the screen.
// Measured in ubuntu:24.04, kernel 6.11.11 aarch64, getconf ARG_MAX 2097152 — a
// 131071-byte argument exits 0 and a 131072-byte one exits 126 with "Argument
// list too long". macOS has no per-argument cap at all: measured on Darwin
// 25.3.0 arm64, only the 1048576-byte TOTAL applies, which is why this broke
// only in CI and on users' machines and never on the one it was written on.
//
// The largest reply seen over 30 days on the design machine was 24675 bytes, so
// this is rare rather than theoretical — and a reply built from a file is not
// rare at all.
//
// `-` is roost's documented "the reply is on stdin" argument, and stdin has no
// size limit. roost still truncates the PANE OPTION to its own byte budget and
// keeps the turn whole on disk, so nothing is capped here — one place decides
// that.
//
// An EMPTY reply is how this adapter takes a reply back: `roost reply -` with
// nothing on stdin records no turn and sets @roost-reply empty, which
// `roost read` treats as no reply (tests/test-reply-channel.sh pins it). A
// plain `roost state done` does not touch the stored reply, and on `done`
// `roost read` serves what is stored without a warning — so a turn that ends
// with no answer has to clear the last one, or the previous turn's answer is
// read as this one's.
const publish = (text) => run(["reply", "-"], text)

// The map holds one entry per session this instance has heard a turn of. Only
// finished entries are evicted, least recently touched first, so a long-lived
// terminal that has seen many chats stays bounded; an evicted chat is simply
// unknown, which reconcile() already handles for a chat never seen.
const CAP = 200
const FINISHED = new Set(["done", "error", "idle"])

// opencode's own retry counter starts at 2 for the first retry. `error` at
// attempt 3 is the 1.x rule — error at the second retry, because a single
// retry may be a blip that heals itself and `error` fires a desktop
// notification — read off opencode's counter instead of one kept here.
const ERROR_ATTEMPT = 3

// How long one permission.sync may hold the one writer. It is a call to
// opencode, measured at 7 ms for a child and under 1 ms for its parent, and it
// sits inside the only code that writes the pane: an answer that never comes
// must not stop the badge from ever moving again.
const SYNC_LIMIT_MS = 2000
const TIMED_OUT = Symbol("timed out")

// Before the first pass, `written.front` is this — not null, which means the
// home screen — so the first pass always sees a change of front.
const NEVER = Symbol("never written")

const setup = (context) => {
  // A missing API (some later 2.x without `data.listen`, or without the
  // router) leaves the pane unbadged rather than broken.
  const listen = context?.data?.listen
  const router = context?.ui?.router
  if (typeof listen !== "function" || typeof router?.current !== "function") return () => {}
  const session = context.data.session ?? {}

  // --- The model ---
  //
  // Session id -> { phase, text, due }, keyed by the id the event itself
  // carries. There is no map of children to parents and no resolving of ids:
  // a subagent's events carry the child's own id, so they land in the child's
  // entry and never touch the parent's. The child's execution.succeeded cannot
  // end the pane's turn and the child's text cannot become the pane's reply,
  // because the pane only ever reads the entry of the chat in front. Two
  // earlier versions of the design mapped children to their roots, and both
  // reviews found a way for the mapping to be wrong — a session.created never
  // heard, a root() not yet right. Not mapping at all removes the question.
  //
  // - phase: working, done, error or idle. Never blocked: that is asked of
  //   opencode on every pass that cannot trust the last answer (below).
  // - text: what the turn in progress has said so far.
  // - due: a reply owed to the pane for the turn that just ended and not yet
  //   written — { publish: TEXT } or { clear: true } — or null.
  //
  // A Map keeps insertion order, and touch() re-inserts, so the first entry is
  // always the least recently touched.
  const model = new Map()
  const touch = (id) => {
    const entry = model.get(id) ?? { phase: null, text: null, due: null }
    model.delete(id)
    model.set(id, entry)
    if (model.size > CAP) {
      const front = readFront()
      for (const [key, e] of model) {
        if (model.size <= CAP) break
        // Never the chat in front, and never an entry still owed a write: the
        // pane is about the first, and the second is an answer not yet given.
        if (key === id || key === front || e.due || !FINISHED.has(e.phase)) continue
        model.delete(key)
      }
    }
    return entry
  }

  // The chat this terminal is showing, read fresh every time it is asked. The
  // session id, or null on the home screen.
  const readFront = () => {
    try {
      const route = router.current()
      return route?.type === "session" && route.sessionID ? route.sessionID : null
    } catch {
      return null
    }
  }

  // What this instance last wrote: which chat the pane was about, and which
  // state it was given.
  const written = { front: NEVER, state: null }

  // The chat this instance last identified the pane as (#141), or null for
  // none yet. Kept apart from written.front on purpose: that one also tracks
  // the home screen, which is never identified.
  let identified = null

  // The last answer to "is a dialog open in the front's family?" — true,
  // false, or null for not known — and a generation number that every event
  // able to change the answer bumps. A pass trusts the answer only if nothing
  // bumped it while that answer was being fetched.
  const dialog = { pending: null, asked: -1 }
  let staleness = 0
  const stale = () => staleness++

  // The last family(front) a pass got, for an event to check membership
  // against when family() does not answer synchronously.
  let lastFamily = []
  const familyOf = (front) => {
    try {
      const members = session.family?.(front)
      if (Array.isArray(members)) {
        lastFamily = members.map((m) => (typeof m === "string" ? m : m?.id)).filter(Boolean)
        return lastFamily
      }
    } catch {}
    return lastFamily
  }

  let disposed = false

  // --- Events update the model, and write nothing ---
  //
  // "In front now" is a fresh router.current() read when the event is
  // handled, not what the last pass saw.
  const onEvent = (event) => {
    const type = event?.name
    const data = event?.details?.data
    const id = typeof data?.sessionID === "string" && data.sessionID ? data.sessionID : null
    switch (type) {
      case "session.execution.started": {
        if (!id) break
        const e = touch(id)
        e.phase = "working"
        e.text = null
        // `due` is NOT dropped here. A turn that finished in front owes its
        // reply even if a queued prompt starts the next turn before the pass
        // that writes it; dropping it lost a real answer and mis-numbered the
        // pane's turn record (the design's third review round).
        break
      }
      case "session.text.ended": {
        if (!id || typeof data.text !== "string") break
        // The last one wins, as on 1.x: a turn's earlier text is narration
        // before a tool call, and the reply is what it said last. Reasoning
        // arrives separately, as session.reasoning.*, so this is prose only.
        touch(id).text = data.text
        break
      }
      case "session.retry.scheduled": {
        if (!id) break
        touch(id).phase = Number(data.attempt) >= ERROR_ATTEMPT ? "error" : "working"
        break
      }
      case "session.execution.succeeded":
      case "session.execution.failed":
      case "session.execution.interrupted": {
        // A turn's end, for ANY session, can take a dialog with it — with no
        // permission.replied — so the answer must be asked for again or the
        // pane keeps reading `blocked` over a dialog that is gone.
        stale()
        if (!id) break
        const e = touch(id)
        // interrupted -> done is the 1.x judgement for Esc: the person who
        // ended the turn is sitting there, and badging their own keystroke as
        // a crash would ping their desktop about it. opencode 2 reports a
        // dialog answered Reject the same way, reason "shutdown".
        e.phase = type === "session.execution.failed" ? "error" : "done"
        // A turn that finished while its chat is hidden owes the pane nothing,
        // and its text is not kept: a reply is published once, when a turn of
        // the chat in front ends, and never re-published on a tab switch —
        // every non-empty `roost reply` is a new numbered turn, so a
        // re-publish fills the pane's record with duplicates.
        //
        // A turn that ends with no answer — Esc, Reject, a failure, a success
        // with no prose — clears the stored reply, or `roost read` serves the
        // previous turn's answer for this one.
        if (id === readFront()) {
          e.due = type === "session.execution.succeeded" && e.text ? { publish: e.text } : { clear: true }
        }
        e.text = null
        break
      }
      case "permission.asked":
        // Nothing in the model: blocked is asked for, not tracked. Tracking it
        // would need each request attributed to the right chat and a count when
        // two are open at once; asking needs neither. The event is still the
        // signal to ask again.
        stale()
        break
      case "permission.replied": {
        stale()
        const front = readFront()
        if (!id || !front || (id !== front && !familyOf(front).includes(id))) break
        // A dialog means the model answered, so the retry loop an `error` came
        // from is over (the 1.x rule). Only the front's entry: that is the one
        // the pane shows.
        const e = model.get(front)
        if (e?.phase === "error") e.phase = "working"
        break
      }
    }
  }

  // --- Asking whether a dialog is open ---
  //
  // Any pending request in any member of family(front). A chat with no memory
  // of the event can still find it: permission.list(id) is empty until
  // permission.sync(id) has run, and then holds the request — measured for a
  // dialog of the chat itself and of its subagent. Returns true, false, or
  // null when an answer did not come: a sync that failed or ran past its limit.
  const ask = async (front) => {
    let members = []
    try {
      members = await session.family?.(front)
    } catch {}
    members = Array.isArray(members) ? members.map((m) => (typeof m === "string" ? m : m?.id)).filter(Boolean) : []
    if (!members.includes(front)) members.unshift(front)
    lastFamily = members
    let unknown = false
    for (const id of members) {
      // A front that left mid-ask is another pass's question; the rest of
      // this family's syncs, up to 2 s each, would be spent on a chat the pane
      // is no longer about.
      if (disposed || readFront() !== front) return null
      let timer
      try {
        const synced = await Promise.race([
          Promise.resolve(session.permission?.sync?.(id)),
          new Promise((resolve) => {
            timer = setTimeout(() => resolve(TIMED_OUT), SYNC_LIMIT_MS)
          }),
        ])
        if (synced === TIMED_OUT) {
          unknown = true
          continue
        }
      } catch {
        unknown = true
        continue
      } finally {
        clearTimeout(timer)
      }
      try {
        const requests = session.permission?.list?.(id)
        if (Array.isArray(requests) && requests.length > 0) return true
      } catch {
        unknown = true
      }
    }
    return unknown ? null : false
  }

  // The phase the pane shows for the chat in front, when no dialog is open:
  // the entry's, or, for a chat with no entry (never seen, evicted, or lost to
  // a reload), `working` if opencode says it is running and `idle` if not.
  // What cannot be recovered for an unknown chat is the difference between
  // done, error and idle for a turn this instance did not see end; it reads
  // idle.
  const phaseOf = (front) => {
    if (front === null) return "idle"
    const phase = model.get(front)?.phase
    if (phase) return phase
    try {
      return session.status?.(front) === "running" ? "working" : "idle"
    } catch {
      return "idle"
    }
  }

  // --- The one writer ---
  //
  // Serial: a call while a pass is in flight sets `again` and returns, and the
  // running call loops until a pass ends with nothing new to do. After every
  // await the front and `disposed` are read again; a front that moved, or an
  // event that arrived, ends the pass early and the loop runs another, so a
  // write that became wrong while it was in flight is followed by the right
  // one before the loop ends.
  let running = false
  let again = false
  const reconcile = async () => {
    if (disposed) return
    if (running) {
      again = true
      return
    }
    running = true
    try {
      do {
        again = false
        await pass()
      } while (again && !disposed)
    } catch {
      // Never throws: a broken pass leaves the pane as it was, and the next
      // event or tick starts a new one.
    } finally {
      running = false
    }
  }

  // True when the pass must stop: this instance was disposed, or the chat in
  // front is no longer the one the pass started on. A moved front is another
  // pass's job, so it asks for one.
  const moved = (front) => {
    if (disposed) return true
    if (readFront() !== front) {
      again = true
      return true
    }
    return false
  }

  const pass = async () => {
    const front = readFront()

    // 1. The front changed: the pane is now about a different chat, so the
    // reply stored on it is not this chat's. Drop the owed reply of the chat
    // that left — an answer owed and then written much later, after a tab
    // switch and back, would read as the newest one — take the stored reply
    // back with an empty one, forget the state written, and ask about dialogs
    // afresh.
    //
    // The first pass is setup's, and it clears the reply too: setup writes
    // the pane in full. An instance cannot know whose badge and whose reply
    // are on the pane — a new opencode started in a pane still showing
    // another chat's `done` and answer, a busy badge left by the previous
    // instance for a turn that ended during the reload — so it does not
    // guess. An earlier version of the design tried "never downgrade at
    // setup", to keep a finished chat's `done` and reply across a reload, and
    // its review found three ways for that to be wrong. The cost: after a
    // reload a finished chat reads `idle` with no stored reply until its next
    // turn.
    if (front !== written.front) {
      const left = written.front
      written.front = front
      written.state = null
      stale()
      if (left !== NEVER && left !== null) {
        const e = model.get(left)
        if (e) e.due = null
      }
      await publish("")
      if (moved(front)) return
    }

    // 1b. Who the agent is (#141), for `roost status --json`: the chat in
    // front, when it is not the one last identified. Here, in the one writer,
    // and BEFORE the state below, so a reader that sees this pass's badge
    // finds the identity that goes with it. Keyed on the front, never on an
    // event: every terminal hears every chat (the header), so the session id
    // an event carries is not this pane's. A tab switch is a front change and
    // identifies the new chat; switching back identifies the old one again,
    // which costs one tmux read and writes nothing if it is what the pane
    // already holds.
    //
    // The home screen (null) identifies nothing and clears nothing: the pane
    // keeps the last chat it was about. The directory is the TUI's own, where
    // opencode was started. No --transcript: opencode 2 keeps its
    // conversations in its own storage, not one file per chat. Through run(),
    // so a missing roost or a refused value never throws; `identified` is set
    // first, so a call that failed is not retried on every pass. Measured on
    // opencode 2.0.29 in a roost pane: the chat in front was identified, and a
    // tab switch identified the new chat. Not measured: a deleted chat in
    // front, and two terminals on one opencode server.
    if (front !== null && front !== identified) {
      identified = front
      let cwd = null
      try {
        cwd = process.cwd()
      } catch {}
      if (typeof cwd === "string" && cwd) {
        await run(["identify", "--session", front, "--cwd", cwd, "--harness", "opencode"])
        if (moved(front)) return
      }
    }

    // 2. Ask whether a dialog is open, unless the last answer may be trusted.
    // It is cached only while nothing can change it unnoticed: the front's
    // phase is finished AND the last answer was "nothing pending" AND no event
    // that could change it has arrived since. In every other case — the front
    // working, the last answer "pending" or not known, a front change, a
    // permission.* event, a turn's end — it is asked again on every pass. A
    // child that asks before its parent's family lists it, and a dialog taken
    // away by the end of its turn, are both seen at the next pass that way.
    let pending = false
    if (front !== null) {
      const trusted = dialog.asked === staleness && dialog.pending === false && FINISHED.has(phaseOf(front))
      if (trusted) {
        pending = dialog.pending
      } else {
        const generation = staleness
        pending = await ask(front)
        if (moved(front)) return
        dialog.pending = pending
        dialog.asked = pending === null ? -1 : generation
      }
    }

    // 3. A reply is due for the chat in front: write it, then drop it. Taken
    // off the entry before the write, so a reply that becomes due while this
    // one is in flight is a new one and is not lost.
    //
    // Reply before state, always: `roost wait-done` returns the moment the
    // badge stops being busy, and the documented idiom is wait-done then read.
    // Writing `done` first opens a window where the reader lands between the
    // two calls and finds the previous answer.
    const entry = front === null ? undefined : model.get(front)
    if (entry?.due) {
      const due = entry.due
      entry.due = null
      await publish(due.publish ?? "")
      if (moved(front)) return
    }

    // 4. The state differs from what was written: write it. If the dialog
    // question went unanswered, the pane keeps what it shows and the question
    // is asked again next pass — a guess here could write `working` over an
    // open dialog, and `roost send` refuses only a `blocked` target, so the
    // next prompt would be typed into the dialog.
    if (pending === null) return
    const state = pending ? "blocked" : phaseOf(front)
    if (state !== written.state) {
      written.state = state
      await report(state)
      if (moved(front)) return
    }
  }

  // Every event ends in a pass. The listener itself never throws and never
  // awaits: opencode's delivery is not held up by a `roost` child.
  let stop = null
  try {
    stop = listen((event) => {
      try {
        if (disposed) return
        onEvent(event)
        reconcile()
      } catch {}
    })
  } catch {}

  // The timer's only job is a pass a second, because switching the chat in
  // front emits no event: without it a tab switch is seen at the next event,
  // which may be minutes away. A badge that lags a switch by a second is
  // invisible; the cost is one cheap pass a second per open opencode terminal
  // when nothing has changed (not measured).
  //
  // Its FIRST tick also forgets the state written, so the state is asserted
  // once more. That is for a reload: the old instance is not killed, so a
  // write it had already started can land after this instance's setup pass.
  // The reply is not cleared again — by then it may be one this instance
  // published itself. What stays open is an old write that `tmux` takes more
  // than a second to act on; that is recorded, not designed around.
  let ticked = false
  const onTick = () => {
    try {
      if (disposed) return
      if (!ticked) {
        ticked = true
        written.state = null
      }
      reconcile()
    } catch {}
  }
  let timer = null
  try {
    timer = setInterval(onTick, 1000)
  } catch {}
  // An interval holds the event loop open. If opencode ever exits by letting
  // its loop drain rather than calling process.exit, a live interval would
  // keep the process running. Exit was not measured (§2.6 measured a reload
  // only), so unref the timer: a pass still runs every second while opencode
  // runs, and the timer alone never keeps it alive. In a `try`, and only if
  // the host's timer has unref, for the same reason setInterval is.
  try {
    timer?.unref?.()
  } catch {}

  // setup writes the pane in full: the first pass clears the stored reply and
  // writes the state it finds (step 1 above says why).
  reconcile()

  // The cleanup opencode runs on a reload or exit. A reload was measured on
  // 2.0.20 (§2.6): the old instance's cleanup runs, a new instance is set up
  // in the same process, and the old interval stops. Exit was not measured.
  // Stop listening, clear the timer, and start no new `roost` call: every
  // step of a pass checks `disposed` after each await. A call already in
  // flight is left to finish — killing `roost reply` between its record
  // append and its pane write would leave a turn file with no @roost-reply,
  // and killing `roost` does not reach the `tmux` it has already started, so
  // a kill buys nothing and can do harm.
  return () => {
    disposed = true
    try {
      if (typeof stop === "function") stop()
    } catch {}
    try {
      clearInterval(timer)
    } catch {}
  }
}

export default { id: "roost", setup }
