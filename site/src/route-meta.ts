/**
 * HTML injected into every page's <head> via routeMeta.head.
 *
 * Order matters:
 *   1. Icons — cheap, and a browser that sees them early stops requesting
 *      /favicon.ico speculatively.
 *   2. Stylesheet link — loaded asynchronously by the browser; must come before
 *      the FOUC-prevention script so --sl-* tokens are available immediately.
 *   3. Inline script — synchronous, runs before first paint to set data-theme
 *      from localStorage, preventing a flash of the wrong theme on reload.
 *
 * Per-page metadata (description, canonical, Open Graph) is NOT here — it
 * differs per route, so each page returns it as `seoHead` from pageData.
 * See src/seo.ts.
 */
export const starlightHead = [
  // .ico carries 16/32/48 for the tab; the 32px PNG is what modern browsers
  // prefer; apple-touch-icon is opaque because iOS composites onto black.
  '<link rel="icon" href="/favicon.ico" sizes="any" />',
  '<link rel="icon" type="image/png" sizes="32x32" href="/favicon-32.png" />',
  '<link rel="apple-touch-icon" href="/apple-touch-icon.png" />',
  '<link rel="stylesheet" href="/shoelace/themes/light.css" />',
  '<link rel="stylesheet" href="/styles/starlight.css" />',
  '<link rel="stylesheet" href="/styles/highlight.css" />',
  '<script>(function(){',
  // Dark is the default: roost is a terminal tool and the site should look
  // like one on first visit. A stored choice always wins, so a reader who
  // picks light keeps light. Deliberately NOT prefers-color-scheme -- that
  // would give most visitors a white page on arrival.
  'var s=null;try{s=localStorage.getItem("sl-theme")}catch(e){}',
  'var t=(s==="light"||s==="dark")?s:"dark";',
  'document.documentElement.setAttribute("data-theme",t);',
  '})();</script>',
].join('');
