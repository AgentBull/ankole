import { defineConfig } from '@playwright/test'

/**
 * The Garfish check builds its applet bundles first, then serves the production Vite 8 host
 * configuration with the check page. It uses its own port so that it can run beside the other
 * browser suites.
 */
export default defineConfig({
  testDir: './integration',
  testMatch: ['garfish.spec.ts', 'sdk-contracts.spec.ts', 'applet-publication.spec.ts'],
  workers: 1,
  retries: 0,
  timeout: 60_000,
  outputDir: 'output/playwright-garfish/results',
  reporter: [['list'], ['html', { outputFolder: 'output/playwright-garfish/report', open: 'never' }]],
  use: { baseURL: 'http://127.0.0.1:3199', trace: 'retain-on-failure' },
  projects: [{ name: 'chromium', use: { browserName: 'chromium' } }],
  webServer: {
    command: 'bun --bun vite --config integration/vite.garfish.config.ts --port 3199',
    url: 'http://127.0.0.1:3199/integration/garfish/index.html',
    reuseExistingServer: false
  }
})
