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
| `pages/index.ts` | The landing page (a Lit component, not Markdown). |
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

## Rules

- **Start the body at `##`, not `#`.** The `title` from frontmatter is already
  rendered as the page's `<h1>`. A `#` in the body makes a second one.
- **Slugs must be unique across the whole `content/` directory.** The build
  throws on a collision rather than silently dropping a page.
- **Internal links are absolute paths**: `/docs/setup`, not `setup.md`.
- **Do not edit `routes.generated.ts` or `server/stubs/page-manifest.ts`.**
  Both are regenerated on every build and are gitignored.
- **This site is for users. The repo `README.md` is for contributors.**
  Install and usage instructions belong here; build, test and layout notes for
  people hacking on roost belong in the README. Do not duplicate one into
  the other — link instead.
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
