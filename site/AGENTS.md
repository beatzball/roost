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

## The landing-page hero is recorded, not screenshotted

`public/roost-hero.png` comes out of [vhs](https://github.com/charmbracelet/vhs),
from two files at the repository root:

```sh
./demo/seed-fleet.sh          # a throwaway roost server with a real fleet on it
vhs demo/roost-hero.tape      # writes demo/roost-hero.{png,gif} and roost-agent.png
cp demo/roost-hero.png site/public/roost-hero.png
```

Both files carry the reasons for what look like odd choices in them — the socket
path that has to end in `/roost`, the Nerd Font, the blanked Claude status line,
the three turns. Read them before changing either.

Re-record rather than edit the PNG. The point of the tape is that the hero can
be rebuilt when the status line or the switcher changes, and a hand-touched
image quietly ends that.

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
