#!/usr/bin/env node
// Fail if any component with a shadow root does not adopt the shared
// typography sheet.
//
// Why a static check and not only the e2e test: CI does not run the site's
// Playwright suite, and the failure this guards against is SILENT. A new
// component that forgets `typography` renders its headings in the sans stack,
// builds, deploys, and nothing anywhere goes red. The e2e test proves the
// mechanism works on the pages that exist today; this proves every component,
// including the one written tomorrow, is wired to it.
//
// Needs no install and no browser, so it runs in the same CI step as the
// generated-docs check.

import { readFileSync, readdirSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, relative } from 'node:path';

const site = join(dirname(fileURLToPath(import.meta.url)), '..');

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) walk(path, out);
    else if (path.endsWith('.ts')) out.push(path);
  }
  return out;
}

const files = [...walk(join(site, 'src', 'components')), ...walk(join(site, 'pages'))];

const missing = [];
for (const file of files) {
  const src = readFileSync(file, 'utf8');
  // A shadow root is what makes this necessary; a file without one inherits
  // the global stylesheet and needs nothing.
  const hasShadowStyles = /static\s+(?:override\s+)?styles\s*=/.test(src);
  const createsLightDom = /createRenderRoot\s*\(\s*\)\s*\{\s*return\s+this/.test(src);
  if (!hasShadowStyles || createsLightDom) continue;
  // Adopted, not merely imported: the name has to appear inside the array.
  if (!/styles\s*=\s*\[\s*typography\b/.test(src)) missing.push(relative(site, file));
}

if (missing.length) {
  console.error(
    'These components have a shadow root but do not put `typography` first in\n' +
      'their styles, so their headings and code will render in the wrong font:\n\n' +
      missing.map((f) => `  ${f}`).join('\n') +
      '\n\nFix each with:\n' +
      "  import { typography } from '<relative path>/styles/typography.js';\n" +
      '  static override styles = [typography, css`...`];\n\n' +
      'src/styles/typography.ts explains why a shadow root needs this.',
  );
  process.exit(1);
}

console.log(`typography: all ${files.length} component files checked, every shadow root adopts it.`);
