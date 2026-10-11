import { defineConfig, devices } from '@playwright/test'
import { resolve } from 'node:path'
import base from './playwright.config'

const platform = process.platform === 'darwin' ? `mac-${process.arch === 'arm64' ? 'arm64' : 'x64'}` : 'linux64'
export default defineConfig({
  ...base,
  outputDir: 'output/playwright-126/results',
  reporter: [['list'], ['html', { outputFolder: 'output/playwright-126/report', open: 'never' }]],
  projects: [
    {
      name: 'chromium126',
      use: {
        ...devices['Desktop Chrome'],
        launchOptions: {
          executablePath:
            process.env.CHROMIUM_126_BINARY ??
            resolve(`output/browsers/chrome-headless-shell-${platform}/chrome-headless-shell`)
        }
      }
    }
  ]
})
