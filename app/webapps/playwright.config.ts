import { defineConfig } from '@playwright/test'

export default defineConfig({
  testDir: './integration',
  testMatch: /\/integration\/[^/]+\.spec\.ts$/,
  workers: 1,
  retries: 0,
  timeout: 30_000,
  outputDir: 'output/playwright/results',
  use: { baseURL: 'http://127.0.0.1:3198', trace: 'retain-on-failure' },
  webServer: {
    command: 'bun --bun vite --config integration/vite.config.ts',
    url: 'http://127.0.0.1:3198/integration/index.html',
    reuseExistingServer: false
  }
})
