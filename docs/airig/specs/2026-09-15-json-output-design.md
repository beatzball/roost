# Design — machine-readable output (`--json`), issue #41

Status: **agreed 2026-09-15.** The three open decisions were settled by the
human; each is recorded where it applies, marked **[chosen]**.
Every claim marked *measured* was run on a
throwaway `-S` socket or in a throwaway container. Anything not measured says so.

## Scope of the first cut

| command | first cut | why |
|---|---|---|
| `status` | yes | the fleet listing every integration scrapes today |
| `read` | yes | the reply channel — the main thing agents call |
| `whoami` | yes | trivial, and every agent calls it first |
| `state` | yes, echo after write **[chosen]** | the issue names it; today it prints nothing |
| `screen` | **yes** | same fields as `read`'s fallback, same encoder, ~15 lines |
| `wait-done` | **no** | two other tasks (#47/#66, #65) are changing its argument parsing and exit codes now. See "Adding `wait-done` later" |

Out of scope, as the issue says: a socket, an endpoint, a daemon, anything
long-running. This is a flag on existing commands.

## What callers get today (captured, tmux 3.6, bash 3.2)

Captured before designing, so the JSON keeps everything a caller can read from
the human output. Scenario: sessions `main` (windows `api`, `web` split in two)
and `side` (window `ops`); `%0` done, `%1` working, `%2` named `helper` with no
state, `%3` error with reason `rate_limit`.

| invocation | exit | stdout | stderr |
|---|---|---|---|
| `status`, no server | 0 | `roost: not running` | — |
| `status` | 0 | `roost: running (socket=/tmp/amx.TYgH/roost)`, one `  session main — 2 windows` line per session (`[attached]` suffix when attached), one `    %0  main:0.0 api/bash  [done]` line per pane (`[-]` when no state; `/LABEL` suppressed when it equals the window name) | — |
| `status --json` | 0 | **the human output** — extra words are ignored today | — |
| `whoami` in a pane | 0 | `%1` | — |
| `whoami --json` | 0 | `%1` — extra words ignored | — |
| `whoami` outside, or `TMUX_PANE=%99` | 1 | — | `roost whoami: not inside a roost session` |
| `read %0` (reply stored) | 0 | the reply + `\n` | — |
| `read %1` (reply stored, pane working) | 0 | the reply + `\n` | `roost read: '%1' is working — this reply is from its previous turn.` |
| `read %2` (no reply) | 0 | last N non-blank screen lines | two lines: `no recorded reply …` and `(that pane has no roost adapter …)` |
| `read %3` (no reply, error) | 0 | screen lines | `no recorded reply …` and `('%3' is in error state: rate_limit; …)` |
| `read %99` / `read nosuch` | 1 | — | the two notices, then tmux's `can't find pane: %99` |
| `read` on a **blank** pane | **1** | — | the two notices. `grep -v` selects nothing and `pipefail` makes it exit 1 |
| `read --json %0` | 1 | — | `roost read: unknown flag '--json'.` + usage |
| `screen %0 3` | 0 | 3 lines | — |
| `screen %99` | 1 | — | `can't find pane: %99` |
| `screen` on a **blank** pane | **1** | — | — |
| `screen --json %0` | 1 | — | `'--json' is not a target — roost screen takes no flags.` + usage |
| `state working` in a pane | 0 | — | — (badge set) |
| `state --json` in a pane | 0 | — | — (**the badge is set to `idle`**: `--json` is an unknown state, and unknown means idle) |
| `state done` outside roost | 0 | — | — (silent no-op) |

Two of these shape the design: `state --json` already *does* something (sets
`idle`), and a blank screen already exits 1.

## Common rules for every JSON document

- **One document, one line.** Compact JSON (no insignificant whitespace),
  followed by exactly one `\n`. Nothing else on stdout.
- **Built in full, printed once.** The command collects every value, encodes
  them, assembles the document, and prints it with a single `printf '%s\n'`.
  A failure half-way can never leave half a document on stdout.
- **The first two keys** are `"schema"` and `"command"`. Key order is
  deterministic (the order in this spec) so tests can compare bytes, but it is
  **not** part of the contract — consumers must not depend on it.
- **Every documented field is always present.** Unknown or unset is `null`,
  never an absent key. An empty list is `[]`.
- **Machine values, not human ones.** Epoch seconds, not "3m ago". State names,
  not glyphs. Pane ids, not labels.
- **stderr is unchanged by `--json`.** Every notice the human mode prints on
  stderr is printed, byte for byte, in JSON mode too. The issue says diagnostics
  stay on stderr; keeping them identical also makes the tests simple.
- **Strings are UTF-8.** Invalid UTF-8 is replaced with U+FFFD (see "Escaping").
  Documents that carry agent-authored text say whether that happened
  (`"lossy"`).
- **Flag placement follows each command's existing grammar**, below.

### Versioning

- `"schema": 1` in every document. One integer for **all** commands, held in
  one constant in `bin/roost` beside `ROOST_CONTRACT`:
  `ROOST_JSON_SCHEMA=1`.
- It is a third version number, deliberately separate from the other two.
  `ROOST_VERSION` moves every release. `ROOST_CONTRACT` moves when extension
  wiring changes. `ROOST_JSON_SCHEMA` moves only when a document changes in a
  way that breaks a consumer.
- **Breaking (bump the integer):** removing or renaming a field; changing a
  field's type (including string ↔ null-able ↔ number); changing a field's
  meaning or units; changing what `text` contains (for example, adding the
  trailing newline); changing when a document is printed at all; changing
  which exit code comes with which document.
- **Not breaking (no bump):** adding a field; adding a command that supports
  `--json`; adding a new *value* to an enum field. Consumers are told, in the
  docs, to treat an unknown enum value as unknown, never as an error. Key order
  and whitespace are never part of the contract.
- A consumer checks `schema == 1`. The docs page states this.

### Exit codes and failures

Exit codes are **identical** with and without `--json`, with one exception: a
blank screen. **[chosen]** On a runtime failure stdout is **empty**; the exit
code and stderr, both unchanged, say what failed. No error-code vocabulary is
frozen into the contract, and tmux's own messages stay free text on stderr.

| case | exit | stdout | stderr |
|---|---|---|---|
| usage error (bad flag, missing target, `--json` with `--render`) | as today (1 or 2) | empty | as today; new messages for the new combinations |
| runtime failure (target not found, not in a roost pane) | as today (1) | empty | as today |
| success, including an empty result | as today (0) | the document | as today |
| blank screen (`screen`, `read` fallback) | **0** (human mode: 1) | the document, `"text": ""` | as today |
| the encoder itself fails (awk missing or crashed) | 1 | empty | `roost <cmd>: could not encode JSON output` |

The last row is new and can only happen with `--json`, so it changes no
existing exit code.

**Blank screen [chosen]:** the issue requires both "exit codes must not change"
and "an empty result is a valid empty document, not an error", and today a
blank pane exits 1 (`grep -v` selects nothing under `pipefail`). No `--json`
caller exists yet, so the JSON mode exits 0 with `"text":""`. The human mode's
exit 1 is left as it is and filed as its own bug, so that both modes agree once
that is fixed. Rejected: keeping exit 1 and printing the document, which makes
`out=$(roost screen --json %N) || fail` treat an idle pane as an error.

## The documents

### `roost status --json`

Grammar: `roost status [--json]`. `--json` is recognised only as the second
word. Anything else there keeps today's behaviour (ignored), so nothing that
works today changes.

```json
{"schema":1,"command":"status","running":true,"socket":"/tmp/amx.TYgH/roost","socket_kind":"path",
 "sessions":[{"name":"main","windows":2,"attached_clients":0},{"name":"side","windows":1,"attached_clients":0}],
 "panes":[
  {"id":"%0","session":"main","window_id":"@0","window_index":0,"window_name":"api","pane_index":0,"name":null,"command":"bash","state":"done","since":1789000000},
  {"id":"%1","session":"main","window_id":"@1","window_index":1,"window_name":"web","pane_index":0,"name":null,"command":"bash","state":"working","since":1789000100},
  {"id":"%2","session":"main","window_id":"@1","window_index":1,"window_name":"web","pane_index":1,"name":"helper","command":"bash","state":null,"since":null},
  {"id":"%3","session":"side","window_id":"@2","window_index":0,"window_name":"ops","pane_index":0,"name":null,"command":"bash","state":"error","since":1789000200}]}
```

(Wrapped here for reading; the real output is one line. This example is the
captured scenario above written out by hand — no code emits it yet.)

| field | type | meaning |
|---|---|---|
| `running` | bool | a server answered `list-sessions`. The same test the human header uses |
| `socket` | string | the socket name or path roost addressed (the human header's `socket=`) |
| `socket_kind` | `"name"` \| `"path"` | whether tmux needs `-L` or `-S` for it — the same distinction as `ROOST_SOCKET_FLAG` |
| `sessions[].name` | string | `#{session_name}` as tmux reports it |
| `sessions[].windows` | integer | `#{session_windows}` |
| `sessions[].attached_clients` | integer | `#{session_attached}`. The human `[attached]` means this is > 0 |
| `panes[].id` | string | `%N`, the stable target |
| `panes[].session` | string | session name |
| `panes[].window_id` | string | `@N`, the stable window target (new; the human line has only the index) |
| `panes[].window_index` / `pane_index` | integer | the `S:W.P` numbers in the human line |
| `panes[].window_name` | string | `#{window_name}` |
| `panes[].name` | string \| null | `@roost-name`, raw. `null` when unset **or empty** — the human line treats both the same |
| `panes[].command` | string | `#{pane_current_command}` |
| `panes[].state` | string \| null | `@agent_state`. One of `working`, `blocked`, `done`, `error`, `idle`; `null` when unset (the human `[-]`). Something other than roost can write another string; consumers treat any other value as unknown |
| `panes[].since` | integer \| null | `@agent_since`, epoch seconds, when the badge was last stamped. `null` when unset or not all digits |

The human `LABEL` is not a field: it is `name ?? command`, and the suffix rule
is presentation.

**Empty:** no server →
`{"schema":1,"command":"status","running":false,"socket":"roost","socket_kind":"name","sessions":[],"panes":[]}`,
exit 0 (today: `roost: not running`, exit 0).

#### Reading pane fields safely

*Measured* (tmux 3.6): `#{window_name}` and `#{session_name}` come back
vis-escaped (a tab is the two bytes `\t`, `\377` for a bad byte), but
**`@roost-name` comes back raw**, and a newline in it splits a `list-panes`
record: 4 lines for 3 panes. `roost spawn`/`split` refuse such names, but any
`tmux set -p` can write one.

So `status --json` does not trust a delimiter. It reads:

1. `list-panes -a -F '#{pane_id}'` — ids, which never contain a tab or newline
2. `list-panes -a -F` with the ten fields joined by tabs
3. step 1 again

It accepts step 2 only if steps 1 and 3 are identical, step 2 has exactly that
many lines, every line has **exactly nine tabs**, and line *i* starts with id
*i*. Any tab or newline inside any field breaks one of those checks, and pane
ids are never reused within a server's life, so equal before/after lists mean
no pane came or went between them. The forging case (a crafted name plus a
concurrent pane death) is closed by the before/after check.

If any check fails, it falls back to one `display-message` or
`show-options -p -qv` per field per pane. *Measured:* about 4 ms per call
(30 calls: 122 ms), against 4 ms for a whole `list-panes`. The fallback costs
more only on a server that holds a hostile or broken name.

Sessions use the same check on `list-sessions` (`#{session_id}` for the id
list).

Numbers (`window_index`, `pane_index`, `windows`, `attached_clients`) are
checked as all-digits under `LC_ALL=C`. A non-number takes the fallback path.

A known, existing limit that JSON inherits: `$(…)` strips trailing newlines, so
an option value that ends in a newline loses it. Human mode has the same loss.

### `roost whoami --json`

Grammar: `roost whoami [--json]`, second word only, as for `status`.

`{"schema":1,"command":"whoami","pane":"%1"}`

| field | type | meaning |
|---|---|---|
| `pane` | string | the caller's `%N` |

Not in a roost pane: exit 1, stderr `roost whoami: not inside a roost session`,
stdout empty. (Session and window ids are easy later additions and are
left out of the first cut on purpose.)

### `roost read --json`

Grammar: `roost read [-r|--render|--json] TGT [LINES]`. The flag slots stay
where they are today: before the target. Each flag may appear once, in either
order. `--json` with `--render` (or `-r`) is a usage error, exit 1:
`roost read: --json and --render cannot be combined — JSON is for programs, --render is for people.`
A repeated flag keeps today's refusal. The after-the-target sweep is unchanged.

```json
{"schema":1,"command":"read","target":"%1","pane":"%1","source":"reply","state":"working","stale":true,"error_reason":null,"text":"old reply from web","lossy":false}
```

| field | type | meaning |
|---|---|---|
| `target` | string | the target exactly as the caller typed it |
| `pane` | string \| null | the `%N` it resolved to (`display-message -p '#{pane_id}'`); `null` only if the pane vanished between the read and this lookup |
| `source` | `"reply"` \| `"screen"` | what `text` is: the recorded reply, or the screen fallback |
| `state` | string \| null | `@agent_state`, read the same moment the human path reads it (after the #38 unblock check) |
| `stale` | bool | `source` is `reply` and `state` is `working`, `blocked` or `error` — exactly when the human mode prints "this reply is from its previous turn". Always `false` for `screen` |
| `error_reason` | string \| null | `@roost-error-reason` when `state` is `error`, else `null` |
| `text` | string | the reply whole, or the last `LINES` non-blank screen lines joined by `\n`. **No trailing newline** (the human mode adds one) |
| `lossy` | bool | `text` may not be the bytes the agent wrote: invalid UTF-8 was replaced with U+FFFD, or the server is tmux 3.4/3.5a and `text` holds an escape sequence that tmux writes (see "tmux that rewrites what it stores"). The reply channel itself stores raw bytes on tmux 3.6+ (*measured*: a reply with `\xff`, a lone `\xc3`, an overlong `\xc0\xaf`, a surrogate `\xed\xa0\x80` round-trips byte-identical through `roost reply` and `roost read`) |

`LINES` still applies only to the screen. A blank screen gives `"text": ""`
with exit 0. Target not found: exit 1, stdout empty,
stderr unchanged (the two notices and tmux's line).

The order of tmux reads is the human path's order, unchanged. The JSON branch
takes the values that path already reads; it does not re-read them.

### `roost screen --json`

Grammar: `roost screen [--json] TGT [LINES]`. Today the target slot refuses any
dash word. `--json` becomes the one flag it accepts there, once.

```json
{"schema":1,"command":"screen","target":"%0","pane":"%0","lines":3,"text":"screen-line-one\nscreen-line-two\nsh-3.2$","lossy":false}
```

| field | type | meaning |
|---|---|---|
| `target`, `pane` | string | as for `read` |
| `lines` | integer \| null | the `LINES` asked for (default 40). A negative count (`tail -n -3`) is reported as its absolute value and leading zeros are dropped (`007` → 7); any other spelling tail accepts, such as `+3`, is `null` |
| `text`, `lossy` | | as for `read`. *Measured:* `capture-pane` already turns invalid UTF-8 into U+FFFD, so `lossy` is normally `false` here; it stays for symmetry |

### `roost state STATE --json` — echo after write **[chosen]**

Today `state` writes and prints nothing, and it is the command every adapter
calls. The hooks call `scripts/roost-agent-state` directly, so `bin/roost`'s
`state` arm is not on the PostToolUse hot path, but adapters do use it.

Grammar:
`roost state STATE --json` — flag **after** the state, because that invocation
already sets `STATE` correctly today and prints nothing. `roost state --json`
(flag first) keeps today's meaning: set `idle`.

```json
{"schema":1,"command":"state","requested":"bogus","state":"idle","pane":"%2","recorded":true}
```

| field | type | meaning |
|---|---|---|
| `requested` | string | the word the caller passed |
| `state` | string \| null | the state as normalised (`bogus` → `idle`). `null` when nothing was recorded |
| `pane` | string \| null | the caller's pane, or `null` outside roost |
| `recorded` | bool | `@agent_state` on that pane reads back equal to `state` after the write |

Built by running `roost-agent-state` as a child (not `exec`), then one
`display-message` to read back. Without `--json`, the arm still `exec`s exactly
as today — one extra `case` on `$3`, no fork. Outside roost: exit 0, as today,
with `"recorded":false`. This answers the failure recorded in
`scripts/lib/roost-socket.sh`'s header ("badges landed and replies vanished,
exit 0, nothing printed"): an adapter author can now see a badge that did not land.

Rejected: making `roost state --json` read the caller's own state without
writing. That changes what `roost state --json` does today (it sets `idle`),
and repeats what `status --json` already gives.

## Escaping — how bytes become JSON, with no new dependency

### What can reach a field (measured)

| source | what arrives |
|---|---|
| `@roost-reply` | **raw bytes**, including invalid UTF-8, control bytes and a trailing `;` (argv → tmux → `show-options`, byte-identical) |
| `@roost-name`, `@agent_state`, `@roost-error-reason` | raw bytes (any `tmux set -p` can write them) |
| `#{window_name}`, `#{session_name}` | tmux vis-escapes tab, newline, `\` and bad bytes (tmux 3.6; **not measured on 3.4**) |
| `capture-pane` | invalid UTF-8 already replaced with U+FFFD; `"` and `\` raw |
| NUL | **cannot occur.** A bash string cannot hold it: bash 3.2 drops it silently, bash 5 drops it and prints `warning: command substitution: ignored null byte in input`. argv cannot carry it either |

### The rule

- `\` → `\\`, `"` → `\"`
- `\b \t \n \f \r` → those short escapes
- every other byte `0x01`–`0x1F`, and `0x7F` → `\u00XX` (DEL is legal raw JSON;
  it is escaped so a document printed to a terminal cannot drive it)
- well-formed UTF-8 (RFC 3629: no overlongs, no surrogates, nothing above
  U+10FFFF) → copied through unchanged, not `\u`-escaped
- anything else → U+FFFD, one per **maximal subpart** (the Unicode and WHATWG
  rule, which Python's `errors='replace'` also follows — so a test has a
  standard oracle), and the value is marked lossy

JSON has no byte escape (`\u00FF` means U+00FF, not byte 0xFF), so a lossless
byte round trip is impossible in a JSON string. Replacement plus a `lossy` flag
is honest. A lossless `text_b64` field could be added later without a schema
bump.

### Why awk, not pure bash

Pure bash was built and measured first. It is **correct but too slow**:

- `${s//pattern/rep}` is quadratic in the number of matches on bash 3.2. A
  12 KB reply with 2,800 characters needing escapes took **2.0 s** (plain text:
  ~0 s). Backslash 0.35 s, quote 0.69 s, newline 0.35 s, measured separately.
- `[[ $s =~ $re ]]` with raw high bytes in the ERE is **wrong** on macOS bash
  3.2: it rejected valid multi-byte strings, so it cannot be a fast path.
- A byte walker in bash costs ~1.6 s on 12 KB of invalid bytes.

The encoder is therefore **one awk process per command invocation**. awk is
already a dependency (`roost help` runs it), so nothing new is added.

- bash frames every value as `<byte-length>:<bytes>`, computing the length
  under `local LC_ALL=C` (the reply channel's own rule), and appends one
  sentinel byte so trailing newlines survive awk's record reading.
- awk runs under `LC_ALL=C` and walks the bytes once. It prints one encoded
  JSON string per line (an encoded string can never contain a raw newline, so a
  line is a value), then one line of lossy flags.
- bash reads the lines back into an array and assembles the document with
  `printf`. Values are only ever `%s` arguments, never part of a format.
- Output is written piece by piece, not concatenated, so it stays linear.

A length prefix cannot be confused by any byte a value holds, and NUL, the
only byte that could not be framed, cannot exist in a bash string.

### Proof (measured, fuzzed)

Oracle: Python's `json` module and strict UTF-8 decoding — **in the test
harness only, never in the encoder**. Each case asserts: the output decodes as
strict UTF-8, parses as JSON, contains no raw byte below 0x20 and no raw DEL,
equals `raw.decode('utf-8', 'replace')`, and the lossy flag equals "strict
decode failed". Corpus: every single byte 0x01–0xFF, named edge cases (empty,
`\n`, `12:34`, overlongs, surrogates, truncated sequences, U+10FFFF+1,
U+2028/2029, `\u0041` as literal text, trailing `;`), and 3,000 random strings
built from quotes, backslashes, control bytes, lead and continuation bytes and
valid multi-byte characters, grouped 1–6 values per call to exercise framing.

| platform | bash | awk | values | invalid UTF-8 among them | failures |
|---|---|---|---|---|---|
| macOS (arm64) | 3.2.57 | BSD awk 20200816 | 3,277 | 2,800 | **0** |
| Ubuntu 24.04 (container) | 5.2.21 | mawk 1.3.4 | 3,262 | 2,776 | **0** |
| Debian 11 (container) | 5.1.4 | mawk | 3,262 | 2,776 | **0** |
| Alpine 3.24 (container, awk program only) | — | BusyBox 1.37 awk | 3,262 | 2,806 | **0** |

Timing on macOS, one call including the awk fork, `LC_ALL=en_US.UTF-8` caller:
12 KB with 2,800 escapes **18 ms**; 12 KB CJK and emoji **22 ms**; 12 KB of
0xFF (worst case) **32 ms**; 960 short status-sized values **19 ms**; a call
with no values **3 ms**. Method: wall clock around the call, minus the
timestamp helper's own measured cost.

**Not measured:** gawk (the containers had no network to install it; gawk is
byte-oriented under `LC_ALL=C`, which the encoder sets, but that is a reading of
its manual, not a run). tmux 3.4's byte behaviour for names and captures. CI
runs mawk on Linux and BSD awk on macOS, so those two are what the suite will
keep proving.

### tmux that rewrites what it stores (added after CI, measured)

The first CI run failed on Ubuntu's tmux 3.4 and on macOS's tmux 3.7c; the
author's machine runs 3.6. Measured afterwards on throwaway servers, every single
byte written as `a<byte>b` through `tmux set-option`, and read back three ways
(`show-options -v`, `display -p '#{@x}'`, `list-panes -F`), which always agreed:

| tmux | client locale | control bytes, DEL, invalid UTF-8 | tab, newline, valid UTF-8 | backslash |
|---|---|---|---|---|
| 3.4, 3.5a | UTF-8 | stored as `\a \b \v \f \r` or `\ooo` | kept | **not escaped** |
| 3.4, 3.5a | not UTF-8 | as above | stored as `_` | not escaped |
| 3.6 | either | kept | kept | kept |
| 3.7c | UTF-8 | kept | kept | kept |
| 3.7c | not UTF-8 | stored as `_` | stored as `_` | kept |

**Decoding is ambiguous, so it is not attempted.** Because a backslash is not
escaped, an agent that wrote the ESC byte and one that wrote the text `\033` are
stored identically, and the second is common (any shell snippet in a reply).
Decoding would corrupt that case to rescue the rare one. So `read --json` keeps
`text` exactly as tmux holds it, which is also what plain `roost read` prints, and
sets `lossy: true` when `text` contains `\` followed by three octal digits or one of
`a b f r v` **and** the server echoes a raw `\x01` back as the text `\001`. That
probe is a `display-message -p`, which changes nothing, and it runs only when the
text already looks escaped. A `_` from a non-UTF-8 writer is an ordinary
character and cannot be detected; it is recorded in `docs/known-gaps.md`.

**A second defect, in this code, was found by the same CI run.** `status --json`
ran tmux inside `local LC_ALL=C`. When the caller's environment exports
`LC_ALL` (macOS CI does), a local copy is exported too (measured, bash 3.2 and
5.3), the tmux client runs in the C locale, and tmux 3.4, 3.6 and 3.7c print every
tab, newline and non-ASCII byte to such a client as `_`. Names came back as
`t_x__e`. Fixed by keeping every tmux call out of the functions that set that
local; the test now exports `LC_ALL` for the calls that read hostile values.

### Two bash traps found while proving it — rules for the builder

The first Linux fuzz run reported 204 failures and then 9. Both were the test
harness, not the encoder, and both are traps the product code must avoid:

1. **`IFS= read -r -d ''` drops bytes on bash 5.x in a UTF-8 locale.** A value
   with `\x80\x01`-style sequences came back one byte short (19 bytes read as
   18; under `LC_ALL=C` the same read returned 19). *Rule:* never load a value
   with `read`. Take it from `$(…)`.
2. **Pattern expansions rewrite invalid bytes on bash 5.x in a UTF-8 locale.**
   `${t%x}` turned `\xe0` into `\xc3\xa0` (the UTF-8 for à) and moved a
   backslash ahead of `\xc2`. Under `LC_ALL=C` it was byte-exact. *Rule:* every
   `${v%…}`, `${v#…}`, `${v//…}`, `${#v}` and `case` on a raw value runs under
   `local LC_ALL=C`.

bash 3.2 showed neither.

### python3 and jq

- **The encoder may not use either.** Both are optional today
  (`scripts/lib/roost-json.sh` opens by recording that). A `--json` that
  worked only where python3 exists would make python3 a runtime dependency
  through the side door.
- **Tests may use python3 as the oracle**, as ten test files already do. The
  JSON test file fails, rather than skips, when `CI` is set and python3 is
  absent, so a missing oracle can never report green in CI. Off CI it prints a
  visible SKIP line.

### Where it lives

A new sourced library, `scripts/lib/roost-jsonout.sh`, prefix
`roost_jsonout_*`. Not `roost-json.sh`: that file *edits* config with
python3/jq, is allowed to because it is off the hot path, and has a different
purpose. The new file holds the awk program, the framing function, and the
status integrity check.

It is sourced **inside** each `--json` branch, the way `roost-reply.sh` is
sourced inside `reply`, so no command pays a file read unless it asked for
JSON. `roost state` in particular pays nothing.

## Relationship to the extension seam (contract 1)

- **An extension can consume it today, with no change to the seam.** An
  extension that declares `"needs": ["fleet"]` gets `ROOST_SOCKET` and
  `ROOST_SOCKET_FLAG`; `bin/roost` already honours `ROOST_SOCKET`, so
  `"$ROOST_HOME/bin/roost" status --json` addresses the right server. (Note:
  `$ROOST_HOME/scripts` on `PATH` does not contain `roost` itself; an extension
  calls `$ROOST_HOME/bin/roost`.)
- An extension without `fleet` can still run it. `bin/roost` then falls back to
  `$TMUX` or `-L roost`. That is the limit the seam spec already states:
  `needs` is a declaration, not confinement. JSON output does not change it.
- **The contract does not change.** `ROOST_CONTRACT` stays `1`. The seam
  governs how an extension is wired in; this governs what a core command
  prints. The document carries its own `schema`, so no new environment
  variable is needed.
- The conformance fixture (`tests/fixtures/ext-status/`) stays as it is. It
  proves the contract is rich enough to rebuild `status` without calling
  `roost`; rewriting it on top of `status --json` would prove nothing.
- The extension-author page links to the schema on the fleet page rather than
  copying it.

## Adding `wait-done` later

After #47/#66 and #65 land. Grammar per whatever argument parsing they settle.
The document **is** the outcome, so it is printed on every outcome, including
exit 1 and 2 — this is the one command where a non-zero exit is a result, not a
failure, and the docs table for `wait-done` already treats it that way:

```json
{"schema":1,"command":"wait-done","target":"@3","outcome":"error","panes":[{"id":"%7","state":"error","error_reason":"rate_limit"}]}
```

`outcome` is one of `done`, `error`, `timeout`, `died`, `gone`, matching the
existing exit table. A new command is additive: no schema bump.

## Docs

- `site/content/docs/driving-a-fleet.md` — a "Machine-readable output" section:
  every document, every field, `schema` and what counts as breaking, the
  failure rules, and "treat unknown enum values as unknown". This is the page
  the issue names.
- `site/content/docs/writing-an-extension.md` — one paragraph and a link.
- `README.md` — where the encoder lives and the two bash traps, for contributors.
- `docs/known-gaps.md` — gawk and tmux 3.4 not measured; trailing newlines in
  option values not preserved (both modes); `wait-done` not yet covered.
- `skills/roost/SKILL.md` — mention `--json` where agents are told to parse output.

## Test plan

New file `tests/test-json-output.sh`, on a `mktemp -d` `-S` socket from
`tests/lib.sh`. It builds the same scenario as the capture above.

### What the tests assert

1. **Well-formed, alone.** For each command and scenario: stdout is exactly one
   line, strict UTF-8, `json.loads` succeeds on it, nothing follows the `\n`.
2. **Schema.** `schema == 1`, `command` correct, the exact key set per
   document, every type per the tables (including `null` where specified).
3. **Values.** Against tmux itself: every `status` pane field equals what a
   one-field-per-call `display-message` / `show-options -p` reads for that pane.
   `read`'s `stale`, `state`, `error_reason`, `source` for the four capture
   panes. `screen`'s `text` equals the human stdout minus its final newline.
4. **Round trip, pathological values.** Through `roost reply` then
   `read --json`, and through `@roost-name` then `status --json`: quotes,
   backslashes, `\n`, `\t`, `\r`, `\x01`, ESC sequences, DEL, emoji, U+2028,
   `\u0041` as literal text, a trailing `;`, and invalid UTF-8. Each asserts
   `text == raw.decode('utf-8','replace')` and the `lossy` flag.
5. **Status integrity.** A name holding tabs and a newline, and a name crafted to
   look like a second record (`x\n%0\tmain\t…`): the pane count, ids and
   `name` are still exact, and no extra pane appears.
6. **Encoder fuzz.** The corpus from "Proof" with a fixed seed, trimmed to
   about 600 values so the file stays fast, plus all 255 single bytes.
7. **Empty.** No server: `running:false`, `[]`, exit 0. Blank pane: `"text":""`
   with exit 0.
8. **Failures.** `whoami` outside, `read %99`, `screen %99`: exit code and
   stderr equal the human invocation's; stdout empty. Usage errors:
   `--json` twice, `--json` with `-r`, `screen --json --json`.
9. **`state`.** `state bogus --json` gives
   `state:"idle"`, `recorded:true`; outside roost `recorded:false`, exit 0; and
   `state --json` with no state still sets `idle` and prints nothing.

### Byte-identical without the flag

- Golden files captured **from the commit before the change**, for every
  invocation in the capture table: stdout, stderr and exit code, with the
  socket path replaced by a placeholder at compare time. The test runs each
  invocation without `--json` and compares all three.
- Existing pins stay and keep guarding: `tests/test-ext.sh` compares `status`
  byte for byte against an independent rebuild; `tests/test-reply-channel.sh`
  compares `read` against the stored reply.
- The golden files are regenerated only by a deliberate change to human output,
  never to make the JSON work land.

### Mutations that must turn a test red

| # | mutation | caught by |
|---|---|---|
| 1 | drop the `\` escape in awk | 4, 6 |
| 2 | drop the `"` escape | 1, 4, 6 |
| 3 | drop the `\u00XX` control loop | 1 (raw control byte), 6 |
| 4 | stop escaping DEL | 6 (no raw DEL) |
| 5 | accept an overlong (`E0` lower bound 0x80) | 6 (strict UTF-8 decode) |
| 6 | one U+FFFD per byte instead of per maximal subpart | 6 (oracle equality) |
| 7 | drop the sentinel byte | 4, 6 (`x\n` loses its newline) |
| 8 | compute `${#v}` without `LC_ALL=C` | 6 (framing breaks on emoji) |
| 9 | lossy flag hard-wired to 0 | 4, 6 |
| 10 | remove the status integrity check | 5 |
| 11 | print JSON (or anything) differently when the flag is absent | golden files |
| 12 | change an exit code in a JSON failure path | 8 |
| 13 | change `ROOST_JSON_SCHEMA` | 2 |
| 14 | `stale` computed without `error` | 3 |

One mutation **cannot** be caught on CI's awks and is written down, not hidden:
running awk without `LC_ALL=C`. mawk and BSD awk are byte-oriented regardless of
locale, so the suite stays green; gawk would break. The fix is to keep the
`LC_ALL=C` next to the awk call with a comment saying why.

Each mutation is applied, confirmed to have changed the code, run, seen red,
and restored — the repo's standing rule.
