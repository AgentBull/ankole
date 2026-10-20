import { state } from './integration/pod-browser/fixtures'
import { defineConfig } from '@playwright/test'

export default defineConfig({
  testDir: './integration/pod-browser',
  testMatch: '*.spec.ts',
  workers: 1,
  retries: 0,
  timeout: 120000,
  outputDir: '../../output/playwright/pod-results',
  use: { baseURL: state.base_url, trace: 'retain-on-failure', screenshot: 'only-on-failure' }
})
