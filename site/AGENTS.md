# roost docs site — agent instructions

This directory is the source for **https://roosting.dev**. It is a Litro
`starlight` site in SSG mode: Markdown in, static HTML out.

Read this before changing anything in `site/`.

## Where things live

| Path | What it is |
|------|-----------|
| `content/docs/*.md` | Every documentation page. One file = one page. |
| `server/starlight.config.js` | Site title, top nav, and the sidebar tree. |
| `_data/metadata.js` | Site title, canonical URL, description (used for SEO and OG images). |
| `pages/index.ts` | The landing page (a Lit component, not Markdown). Dark only, and drawn in roost's own vocabulary: a status line using the `ascii` glyph set, the `roost` theme colours. Its header comment says where each comes from. |
| `pages/docs/[slug].ts` | The doc page template. Do not edit to add a page. |
| `src/components/` | Shared UI. Rarely needs touching. |
| `Dockerfile`, `nginx.conf` | Deploy. Coolify builds these on push to `main`. |

## Add a documentation page

1. Create `content/docs/<slug>.md`. The filename becomes the URL:
   `content/docs/foo.md` → `/docs/foo`.

2. Give it frontmatter. `title` and `description` are required:

   ```markdown
   ---
   title: Your Page Title
   description: One sentence. It is used for SEO and the OG image.
   sidebar:
     order: 8
   ---

   ## First heading

   Body starts here.
   ```

3. Add it to the sidebar in `server/starlight.config.js`. A page not listed
   there is still reachable by URL but invisible in the nav:

   ```js
   { label: 'Your Page Title', slug: 'your-page-slug' },
   ```

4. Build to verify (see below).

## Two pages are generated, not written

| Generated file | Source | Regenerate with |
|---|---|---|
| `content/docs/changelog.md` | `CHANGELOG.md` at the repository root | `node scripts/sync-changelog.mjs` |
| `public/llms.txt` | `server/starlight.config.js` + doc frontmatter | `node scripts/build-llms-txt.mjs` |

Both together: `pnpm sync`. To check without writing: `pnpm sync:check` —
which is what CI runs, so a drifted file fails the build rather than shipping.

They are **committed**, not built. Coolify builds the image with `site/` as the
Docker context, so `../CHANGELOG.md` does not exist during `pnpm build`;
generating them there would work locally and serve an empty changelog in
production.

So: after editing `CHANGELOG.md`, or after adding a page to the sidebar, run
`pnpm sync` and commit what it writes.

## The one webfont

`public/fonts/fira-mono-latin-{400,700}.woff2` — 21KB for the pair, latin
subset, self-hosted, with the OFL licence beside them because that licence
requires it. They are the exact files Google serves Chrome.

It is used for **headings, code, and the chrome** (site title, nav, sidebar and
table-of-contents labels) and deliberately NOT for running prose: paragraphs in
a monospace face are slower to read, and these docs are long.

Fira Mono rather than any other: the hero is a terminal recorded in Fira Code,
and Fira Code is Fira Mono with ligatures. One typeface across the page and the
picture, instead of two that nearly match.

### Getting it into shadow DOM

Every component renders into a shadow root. The font gets in fine; a **rule**
does not. Precisely:

| crosses into a shadow root? | |
|---|---|
| `@font-face` | **yes** — declared once in `starlight.css`, usable everywhere. Never repeat it |
| an inherited value, like `font-family` on `html` | **yes** |
| a custom property, like `--sl-font-mono` | **yes** |
| a selector, like `h1 { font-family: ... }` | **no** — matches nothing inside any shadow root |

That is shadow DOM as specified, not a Litro or Lit bug.

So typography lives in one shared sheet, `src/styles/typography.ts`, and every
component with a shadow root puts it **first**:

```ts
import { typography } from '../styles/typography.js';

static override styles = [typography, css`  ...own rules...  `];
```

It sets the mono face on headings, `code`, `kbd`, `samp` and `pre`. For anything
else that should be mono — a label, a wordmark — add `class="mono"` in the
template. Do not add `font-family` to a component's own rules.

Two checks hold this in place:

- `pnpm check:typography` fails if any component with a shadow root does not
  adopt the sheet. **CI runs this one.** It is the only guard CI has, because
  CI does not run the Playwright suite.
- The e2e test `headings, code and chrome are Fira Mono; prose is not` checks
  what actually renders, including that prose is still sans. Local only.

`pnpm build` rewrites the files a running `pnpm dev` in the same checkout is
watching. The dev server does not reliably exit when that happens: it can hang
halfway through a reload, still running and no longer answering on its port, so
a restart-on-exit loop never fires. After a build, stop the dev server and start
it again. `pnpm test:e2e` has the same effect on `dist/static`, which it empties
— build again before serving the static output.

If you ever add a second webfont, measure it first — the latin-subset woff2 a
browser actually downloads, not the TTF. JetBrains Mono looks like the obvious
pick and is 63KB for the same two weights, because Google serves it as a
variable font.

## The landing-page hero is a recording of live agents

`public/demo/flock-hero.{webm,mp4}` and its poster are fifteen seconds cut from
a [vhs](https://github.com/charmbracelet/vhs) recording of a real review flock:
Claude Code leads, and Claude on Sonnet, Codex and opencode review its plan in
parallel roost windows. Rebuild it from the repository root:

```sh
./demo/record.sh flock        # ~7 minutes of live agents -> demo/flock.mp4
./demo/cut-hero.sh --sheet    # one frame per second, to find the four moments
./demo/cut-hero.sh            # -> site/public/demo/flock-hero.* and the poster
```

Live agents never take the same time twice, so after a new take, pick the four
cuts again from the contact sheet and update `SEGMENTS` in `demo/cut-hero.sh`.
Never hand-edit the video or the poster: the point of the scripts is that the
hero can be rebuilt when roost's status line or switcher changes.

### The whole take is on the page too, click to play

The same recording, uncut, is `public/demo/flock-full.{webm,mp4}` and its
poster. Two blocks use it — the homepage below the fold, and Getting Started —
and both point at the same three files, so shipping both costs one download and
only after a reader clicks. Nothing is fetched before that: `preload="none"`,
no autoplay, poster only.

```sh
./demo/encode-full.sh         # -> site/public/demo/flock-full.* and the poster
```

No segments to pick, so there is nothing to update after a new take — run it
and commit. It uses the hero's own 1440-wide, 15 fps, crf 40 / crf 28 recipe,
deliberately: two videos on one page encoded differently would show.

Re-running it leaves the MP4 and the poster byte for byte identical and the
**WebM changed** — same 867392 bytes, different bytes inside, because
`libvpx-vp9 -row-mt` is not deterministic across runs. A dirty WebM after a
re-run on an unchanged take is expected; `git checkout -- site/public/demo/`
is the right answer, not an investigation.

**Always record through `demo/record.sh`, never `vhs` directly.** It is where
the privacy and isolation rules live, and each exists because the thing it
prevents happened while building this:

- It re-runs itself under `env -i`. A recording started from inside roost or
  inside an agent otherwise hands its session variables to the demo agents.
- Everything runs under `/tmp` on a throwaway roost server, with its own
  `XDG_CONFIG_HOME` (or roost writes wiring into your real config) and its own
  zsh config (or your shell history is suggested on camera).
- Wrappers on `PATH` give every agent the demo flags, so no flag or home path is
  ever typed where a frame can see it.
- It refuses to finish if any pane's history shows the home path, the username
  or an email address.

`demo/lib.sh` explains each in place. `demo/first-run.tape` (a shorter,
single-agent recording) and `demo/roost-hero.tape` (a still of a staged fleet)
use the same machinery and are not on the site today.

## Rules

- **Start the body at `##`, not `#`.** The `title` from frontmatter is already
  rendered as the page's `<h1>`. A `#` in the body makes a second one.
- **Slugs must be unique across the whole `content/` directory.** The build
  throws on a collision rather than silently dropping a page.
- **Internal links are absolute paths**: `/docs/setup`, not `setup.md`.
- **Do not hand-edit `content/docs/changelog.md` or `public/llms.txt`.** Both
  carry a generated-file banner and are overwritten by `pnpm sync`. Edit the
  source instead — see the table above.
- **Do not edit `routes.generated.ts` or `server/stubs/page-manifest.ts`.**
  Both are regenerated on every build and are gitignored.
- **This site serves two audiences; the repo `README.md` serves the third.**
  Install and usage instructions belong here, and so does anything an
  *extension author* needs — a manifest schema or an environment contract is
  API documentation for someone who never opens the repository. Build, test and
  layout notes for people hacking on roost belong in the README. Do not
  duplicate one into the other — link instead. `AGENTS.md` §11 is the rule
  this bullet points at.
- **Keep `docs/known-gaps.md` out of this site.** It is a maintainer-facing
  record of shipped risks, not user documentation.

## Verify your change

```sh
cd site
pnpm install        # first time only
pnpm build          # must exit 0; prints every prerendered route
pnpm preview        # serve the build locally
```

`pnpm build` is the real check. It fails on a duplicate slug, a missing
`title`, or a broken component, and it prints the full route list so you can
confirm your page is there.

For a live-reload loop while writing:

```sh
pnpm dev            # http://localhost:3000
```

End-to-end checks:

```sh
pnpm test:e2e
```

If you added or removed a page, update `PRERENDERED_ROUTES` in
`e2e/index.spec.ts` to match.

## Deploy

Push to `main`. Coolify rebuilds from `site/Dockerfile` and serves
`dist/static` behind nginx. There is nothing to run by hand.

To check the deploy locally exactly as production runs it:

```sh
cd site
docker build -t roost-docs .
docker run --rm -p 8099:80 roost-docs
# then open http://localhost:8099
```
