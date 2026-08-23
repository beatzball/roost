/**
 * Per-page <head> metadata: description, canonical, Open Graph and Twitter.
 *
 * A page returns the result as `seoHead` from its pageData fetcher and Litro
 * injects it into <head> (see createPageHandler). `seoHead` is deliberately
 * stripped before the data is serialized into __litro_data__ — it contains a
 * literal </script>, which would end the JSON block early.
 *
 * og:image points at /__og/<path>.png, which the OG handler in
 * server/routes/__og/ renders at build time. Nothing here has to know how the
 * card is drawn.
 */

/**
 * Absolute origin for canonical and og:* URLs. Crawlers and messaging apps
 * will not follow a relative og:image, so this cannot be a path.
 *
 * `globalThis.process?.` rather than a bare `process`: this module is imported
 * by page components, which are also bundled for the browser, where `process`
 * is not defined.
 */
const SITE_URL = (globalThis.process?.env?.SITE_URL ?? 'https://roosting.dev').replace(/\/$/, '');

const SITE_NAME = 'roost';

export interface SeoOptions {
  /** Page title, without the site-name suffix. */
  title: string;
  description: string;
  /** Route path, e.g. `/docs/setup`. Leading slash, no trailing slash. */
  path: string;
  type?: 'website' | 'article';
  /** Absolute URL of a share image, when the generated card is not wanted. */
  image?: string;
}

export function buildSeoHead(options: SeoOptions): string {
  const { title, description, path, type = 'website', image } = options;
  const url = `${SITE_URL}${path}`;
  // '/' would give '/__og/.png'; the handler names the home card 'index'.
  const ogImageUrl = image ?? `${SITE_URL}/__og${path === '/' ? '/index' : path}.png`;

  return [
    `<meta name="description" content="${escapeAttr(description)}" />`,
    `<link rel="canonical" href="${url}" />`,
    `<meta property="og:title" content="${escapeAttr(title)}" />`,
    `<meta property="og:description" content="${escapeAttr(description)}" />`,
    `<meta property="og:type" content="${type}" />`,
    `<meta property="og:url" content="${url}" />`,
    `<meta property="og:image" content="${ogImageUrl}" />`,
    `<meta property="og:image:width" content="1200" />`,
    `<meta property="og:image:height" content="630" />`,
    `<meta property="og:site_name" content="${SITE_NAME}" />`,
    // summary_large_image is what turns the card from a thumbnail into the
    // wide banner Slack, iMessage and X all render.
    `<meta name="twitter:card" content="summary_large_image" />`,
    `<meta name="twitter:title" content="${escapeAttr(title)}" />`,
    `<meta name="twitter:description" content="${escapeAttr(description)}" />`,
    `<meta name="twitter:image" content="${ogImageUrl}" />`,
  ].join('\n');
}

/** Title as it appears in the tab and in search results. */
export function buildSeoTitle(title: string): string {
  return title === SITE_NAME ? title : `${title} — ${SITE_NAME}`;
}

function escapeAttr(str: string): string {
  return str
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}
