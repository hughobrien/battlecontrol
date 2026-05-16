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
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
    // Headed mode required: headless Xvfb with OffscreenCanvas GL context needed
    headless: false,
  },

  projects: [
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
        launchOptions: {
          env: { DISPLAY: ':99' },
          args: [
            '--enable-features=SharedArrayBuffer',
            '--disable-web-security',
            '--autoplay-policy=no-user-gesture-required',
            '--enable-webgl',
            '--enable-unsafe-swiftshader',
            '--ignore-gpu-blocklist',
            '--disable-gpu-sandbox',
          ],
        },
      },
    },
    {
      name: 'firefox',
      use: {
        ...devices['Desktop Firefox'],
        launchOptions: {
          env: { DISPLAY: ':99' },
          firefoxUserPrefs: {
            'media.autoplay.default': 0,
            'media.autoplay.enabled': true,
            'media.volume_scale': '1.0',
            'webgl.force-enabled': true,
          },
        },
      },
    },
  ],
});
