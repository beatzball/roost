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
