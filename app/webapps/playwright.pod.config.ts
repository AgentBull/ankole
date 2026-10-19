import { readFileSync } from 'node:fs'
import { defineConfig } from '@playwright/test'

const statePath = process.env.POD_BROWSER_STATE_PATH
if (!statePath) throw new Error('Start the dedicated real Pod browser fixture and set POD_BROWSER_STATE_PATH')
const state = JSON.parse(readFileSync(statePath, 'utf8')) as { base_url: string }
export default defineConfig({
  testDir: './integration/pod-browser',
  testMatch: '*.spec.ts',
  workers: 1,
  retries: 0,
  timeout: 120000,
  outputDir: '../../output/playwright/pod-results',
  use: { baseURL: state.base_url, trace: 'retain-on-failure', screenshot: 'only-on-failure' }
})
