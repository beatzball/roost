import { test, expect } from '@playwright/test';

const PRERENDERED_ROUTES = [
  '/',
  '/docs/getting-started',
  '/docs/setup',
  '/docs/state-badges',
  '/docs/using-roost',
  '/docs/driving-a-fleet',
  '/docs/extensions',
  '/docs/writing-an-extension',
  '/docs/how-it-works',
  '/docs/troubleshooting',
  '/docs/changelog',
];

test('home renders page-home component', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('page-home');
  await expect(page.locator('page-home')).toBeVisible();
});

test('/docs/getting-started renders', async ({ page }) => {
  await page.goto('/docs/getting-started');
  await page.waitForSelector('page-docs-slug');
  await expect(page.locator('page-docs-slug')).toBeVisible();
});

// roost is a tool for driving agents, so an agent that lands here should find
// the docs in one fetch. A 404 would be silent otherwise: nothing on the site
// links to it.
test('/llms.txt is served as plain text and lists every doc', async ({ request }) => {
  const response = await request.get('/llms.txt');
  expect(response.status()).toBe(200);
  const body = await response.text();
  for (const route of PRERENDERED_ROUTES.filter(r => r !== '/')) {
    expect(body, `Expected llms.txt to link ${route}`).toContain(route);
  }
});

test('all prerendered routes return 200', async ({ request }) => {
  for (const route of PRERENDERED_ROUTES) {
    const response = await request.get(route);
    expect(response.status(), `Expected 200 for ${route}`).toBe(200);
  }
});

// The typography contract, checked where it can actually fail: inside shadow
// roots. A global `h1 { font-family }` matches nothing in a shadow root, so
// every component adopts src/styles/typography.ts instead. This proves the
// result renders -- mono for headings, code and chrome, sans for prose -- and
// the prose rows are the control: a sheet that set mono on EVERYTHING would
// pass every other row.
//
// scripts/check-typography.mjs is the one CI runs; it catches a component that
// forgets the sheet. This one catches the sheet itself being wrong.
test('headings, code and chrome are Fira Mono; prose is not', async ({ page }) => {
  // A Playwright CSS locator pierces open shadow roots on its own, so no
  // hand-rolled walk is needed to reach an element inside a component.
  // The dev server compiles on first request, so the whole test can take tens
  // of seconds cold. Against a warm server or the production build it is fast.
  test.setTimeout(120_000);

  // A short timeout on each read, so a read that is waiting on an element
  // that is mid-reload gives up and lets the poll below try again, instead of
  // spending the whole budget on one attempt.
  const fontOf = (sel: string) =>
    page
      .locator(sel)
      .first()
      .evaluate((el) => getComputedStyle(el).fontFamily.split(',')[0].replace(/"/g, '').trim(), undefined, {
        timeout: 2_000,
      });

  // expect.poll, not a single read. Under `pnpm dev` two things make one read
  // wrong without the site being wrong:
  //  - components fill their shadow roots after `load`, so an early read finds
  //    no element at all;
  //  - the first visit to a route with imports Vite has not seen makes it
  //    re-optimise dependencies and RELOAD the page, and a read that lands
  //    mid-reload gets an empty font-family. Seen as `Received: ""` on
  //    /docs/getting-started, and never against the production build.
  // Polling re-queries a fresh locator each time, so both simply retry.
  const expectFont = (sel: string, want: string, label: string) =>
    expect.poll(() => fontOf(sel).catch(() => 'NOT FOUND'), { message: label, timeout: 30_000 }).toBe(want);

  await page.goto('/');
  // The status line is .site-title plus nav; h3 is a fix heading; .lede is the
  // hero paragraph, the prose control on this page.
  for (const sel of ['.site-title', 'nav a', 'h1', 'h2', 'h3', 'kbd', 'code']) {
    await expectFont(sel, 'Fira Mono', `home ${sel}`);
  }
  await expectFont('.lede', 'ui-sans-serif', 'home prose');

  await page.goto('/docs/getting-started');
  for (const sel of ['.page-title', 'h2[id]', '.group-label', 'code']) {
    await expectFont(sel, 'Fira Mono', `docs ${sel}`);
  }
  await expectFont('p', 'ui-sans-serif', 'docs prose');
});
