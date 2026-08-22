import { defineConfig, devices } from '@playwright/test';

// Deliberately not 3000 — that port is commonly taken by other apps.
const PORT = Number(process.env.LITRO_E2E_PORT ?? 4321);

export default defineConfig({
  testDir: './e2e',
  fullyParallel: false,
  retries: process.env.CI ? 2 : 0,
  workers: 1,
  reporter: 'html',
  use: {
    baseURL: `http://localhost:${PORT}`,
    trace: 'on-first-retry',
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
  webServer: {
    command: `pnpm dev --port ${PORT}`,
    url: `http://localhost:${PORT}`,
    // Never reuse: on the default port a completely unrelated app (Docker,
    // Obsidian, another dev server) can be listening, and Playwright would
    // happily run the whole suite against it and report 404s.
    reuseExistingServer: false,
    timeout: 60000,
  },
});
