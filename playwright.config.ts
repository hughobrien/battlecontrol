import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './e2e',
  timeout: 300_000,    // 5 min — WASM + asset load can be slow
  expect: { timeout: 60_000 },
  reporter: [['list'], ['html', { outputFolder: 'e2e/report', open: 'never' }]],
  outputDir: 'e2e/test-results',

  use: {
    // Must be http:// for COOP+COEP to work (file:// won't satisfy SharedArrayBuffer)
    baseURL: 'http://localhost:8080',
    // Capture console output for frame-count detection
    // Don't capture video by default to keep test fast
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
    // Chromium flags for SharedArrayBuffer (already satisfied by COOP+COEP headers,
    // but --enable-features ensures it in older builds)
    launchOptions: {
      args: [
        '--enable-features=SharedArrayBuffer',
        '--disable-web-security',  // allow localhost cross-port CORS in some edge cases
        '--autoplay-policy=no-user-gesture-required',
      ],
    },
  },

  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
});
