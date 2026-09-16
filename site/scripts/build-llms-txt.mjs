#!/usr/bin/env node
// Write public/llms.txt — the llmstxt.org index of this site.
//
// roost is a tool for driving AI agents, so an agent asked "how do I use
// roost" should be able to find the documentation in one fetch rather than
// crawling a JavaScript-rendered site. One link per doc, with that doc's own
// frontmatter description.
//
// Generated from server/starlight.config.js and the frontmatter in
// content/docs, so a page added to the sidebar appears here too. The output is
// COMMITTED for the same reason as changelog.md: public/ is copied into the
// image as-is, and nothing regenerates it at deploy time.
//
// Run `node scripts/build-llms-txt.mjs` after adding a page; CI runs
// `--check`, which fails if it has drifted.

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { siteConfig } from '../server/starlight.config.js';
import metadata from '../_data/metadata.js';

const here = dirname(fileURLToPath(import.meta.url));
const DOCS = join(here, '..', 'content', 'docs');
const TARGET = join(here, '..', 'public', 'llms.txt');

const BASE = String(metadata.url).replace(/\/+$/, '');

/**
 * Pull one scalar out of a doc's frontmatter.
 *
 * A real YAML parser would be a dependency for two keys that are always a
 * single unquoted line in this repo (site/AGENTS.md documents the shape), and
 * a missing one throws here rather than writing a half-empty index.
 */
function frontmatter(slug, key) {
  const path = join(DOCS, `${slug}.md`);
  const raw = readFileSync(path, 'utf8');
  const block = raw.match(/^---\n([\s\S]*?)\n---/);
  if (!block) throw new Error(`${slug}.md has no frontmatter block`);
  const line = block[1].match(new RegExp(`^${key}:[ \\t]*(.+)$`, 'm'));
  if (!line) throw new Error(`${slug}.md has no "${key}" in its frontmatter`);
  return line[1].trim().replace(/^["']|["']$/g, '');
}

function render() {
  const out = [];
  out.push(`# ${siteConfig.title}`);
  out.push('');
  out.push(`> ${siteConfig.description}`);
  out.push('');
  out.push(
    'roost runs a tmux server of its own, so the agents you are wrangling never',
    'touch your everyday tmux. Each agent reports its own state through a hook or',
    'an adapter, so the tabs show what every agent is doing rather than a guess',
    'scraped off its screen. `send`, `read` and `wait-done` make that fleet',
    'scriptable from a shell, from inside roost, or over ssh.',
  );
  out.push('');

  for (const group of siteConfig.sidebar) {
    out.push(`## ${group.label}`);
    out.push('');
    for (const item of group.items) {
      const description = frontmatter(item.slug, 'description');
      out.push(`- [${item.label}](${BASE}/docs/${item.slug}): ${description}`);
    }
    out.push('');
  }

  out.push('## Source');
  out.push('');
  out.push(
    '- [Repository](https://github.com/beatzball/roost): the launcher, the tmux config, the adapters and the tests.',
  );
  out.push('');

  return out.join('\n');
}

const wanted = render();
const check = process.argv.includes('--check');

if (check) {
  const found = existsSync(TARGET) ? readFileSync(TARGET, 'utf8') : '';
  if (found !== wanted) {
    console.error(
      'site/public/llms.txt is out of step with the sidebar and the doc frontmatter.\n' +
        'Fix it with:  cd site && node scripts/build-llms-txt.mjs',
    );
    process.exit(1);
  }
  console.log('llms.txt is in step with the docs.');
} else {
  writeFileSync(TARGET, wanted);
  console.log(`Wrote ${TARGET}`);
}
