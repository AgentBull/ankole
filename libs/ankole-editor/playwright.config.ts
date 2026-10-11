import { defineConfig, devices } from '@playwright/test'

const consumer = process.env.E2E_CONSUMER_ROOT
// Separate ports and output folders let several test runs share the machine.
const port = Number(process.env.E2E_PORT ?? 3146)
const output = `${consumer ? 'output/playwright-package' : 'output/playwright'}${process.env.E2E_PORT ? `-${port}` : ''}`

export default defineConfig({
  testDir: './e2e',
  fullyParallel: true,
  workers: 3,
  forbidOnly: !!process.env.CI,
  retries: 0,
  timeout: 30_000,
  outputDir: `${output}/results`,
  reporter: [['list'], ['html', { outputFolder: `${output}/report`, open: 'never' }]],
  use: {
    baseURL: `http://127.0.0.1:${port}`,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure'
  },
  projects: [
    { name: 'chromium', use: devices['Desktop Chrome'] },
    { name: 'firefox', use: devices['Desktop Firefox'] },
    { name: 'webkit', use: devices['Desktop Safari'] }
  ],
  webServer: {
    cwd: consumer,
    command: process.env.E2E_PREVIEW === '1' ? `bun run preview --port ${port}` : `bun run dev --port ${port}`,
    url: consumer ? `http://127.0.0.1:${port}/playground/embedded.html` : `http://127.0.0.1:${port}`,
    reuseExistingServer: false
  }
})
