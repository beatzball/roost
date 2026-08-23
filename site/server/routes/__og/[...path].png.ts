/**
 * /__og/**.png — the share card behind every og:image on this site.
 *
 * Litro renders these with Satori (HTML/CSS -> SVG) and resvg (SVG -> PNG).
 * In SSG the whole set is prerendered: ogPrerenderHook() in nitro.config.ts
 * adds one /__og/<route>.png entry per page, so the built site ships static
 * PNGs and nothing is generated at request time.
 */
import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { createOgHandler } from '@beatzball/litro/runtime/og-handler.js';
import { routes, pageModules } from '#litro/page-manifest';

/**
 * The logo has to be inlined as a data URI — Satori cannot fetch a URL.
 *
 * The working directory is not the same in every mode (dev runs from site/,
 * the prerender pass can run from the repo root), so each candidate is tried
 * rather than assumed. A missing logo is not fatal: the card just loses its
 * mark.
 */
function loadLogoDataUri(): string | undefined {
  const candidates = [
    resolve('public/logo.png'),
    resolve('site/public/logo.png'),
    resolve('dist/server/public/logo.png'),
  ];
  for (const p of candidates) {
    if (existsSync(p)) {
      return `data:image/png;base64,${readFileSync(p).toString('base64')}`;
    }
  }
  return undefined;
}

export default createOgHandler({
  siteName: 'roost',
  // Matches --sl-color-accent in the site's dark theme.
  accentColor: '#a78bfa',
  logoDataUri: loadLogoDataUri(),
  routes,
  pageModules,
});
