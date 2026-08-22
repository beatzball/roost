/**
 * HTML injected into every page's <head> via routeMeta.head.
 *
 * Order matters:
 *   1. Stylesheet link — loaded asynchronously by the browser; must come before
 *      the FOUC-prevention script so --sl-* tokens are available immediately.
 *   2. Inline script — synchronous, runs before first paint to set data-theme
 *      from localStorage, preventing a flash of the wrong theme on reload.
 */
export const starlightHead = [
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
