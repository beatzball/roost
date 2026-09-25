import { defineEventHandler, setResponseHeader, setResponseStatus, getRequestURL } from 'h3';
import { createPageHandler } from '@beatzball/litro/runtime/create-page-handler.js';
import { DEFAULT_SKIP_LINKS } from '@beatzball/litro';
import type { LitroRoute } from '@beatzball/litro';
import { routes, pageModules } from '#litro/page-manifest';

// Canonicalise before matching, rather than teaching each matcher about slashes
// (#130). Every route below is written without a trailing slash, and the static
// check is an exact `===` while the dynamic pattern ends in `[^/]+$`, so
// /docs/getting-started/ matched nothing that /docs/getting-started matched and
// fell through to the not-found branch. Doubled slashes collapse for the same
// reason. `/` itself is left alone: stripping it would leave an empty path.
//
// This is the dev/server half. Production already redirects the trailing-slash
// form in nginx.conf, and app.ts canonicalises on the client (#129); both stay.
// Upstream is tracking the same fix as beatzball/litro#203.
function canonicalPath(pathname: string): string {
  const collapsed = pathname.replace(/\/{2,}/g, '/');
  return collapsed.length > 1 && collapsed.endsWith('/') ? collapsed.slice(0, -1) : collapsed;
}

function matchRoute(
  pathname: string,
): { route: LitroRoute; params: Record<string, string> } | undefined {
  for (const route of routes) {
    if (route.isCatchAll) return { route, params: {} };

    if (!route.isDynamic) {
      if (pathname === route.path) return { route, params: {} };
      continue;
    }

    const regexStr =
      '^' +
      route.path
        .replace(/:([^/]+)\(\.\*\)\*/g, '(?<$1>.+)')
        .replace(/:([^/?]+)\?/g, '(?<$1>[^/]*)?')
        .replace(/:([^/]+)/g, '(?<$1>[^/]+)') +
      '$';

    try {
      const match = pathname.match(new RegExp(regexStr));
      if (match) return { route, params: (match.groups ?? {}) as Record<string, string> };
    } catch {
      // malformed pattern — skip
    }
  }
  return undefined;
}

export default defineEventHandler(async (event) => {
  const pathname = getRequestURL(event).pathname;
  const result = matchRoute(canonicalPath(pathname));

  if (!result) {
    // Without this a page that was not found went out as 200 (#130), which
    // hides a dead link from anything that checks the status.
    setResponseStatus(event, 404);
    setResponseHeader(event, 'content-type', 'text/html; charset=utf-8');
    return `<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8" /><title>404</title></head>
<body><h1>404 — Not Found</h1><p>No page matched <code>${pathname}</code>.</p></body>
</html>`;
  }

  const { route: matched, params } = result;
  event.context.params = { ...event.context.params, ...params };

  const mod = pageModules[matched.filePath];
  const handler = createPageHandler({
    route: matched,
    routeMeta: (mod?.routeMeta as { title?: string; head?: string } | undefined),
    pageModule: mod,
    skipLinks: [
      ...DEFAULT_SKIP_LINKS,
      { label: 'Skip to navigation', href: '#_litro_nav' },
    ],
  });
  return handler(event);
});
