import { afterAll, describe, expect, it } from 'bun:test'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const workspaceRoot = mkdtempSync(join(tmpdir(), 'ankole-browser-'))
const cli = new URL('../src/browser_cli.ts', import.meta.url).pathname

afterAll(() => {
  rmSync(workspaceRoot, { force: true, recursive: true })
})

describe('@ankole/agent-computer browser CLI', () => {
  it('supports doctor, open, extract, and run commands', () => {
    const doctor = runBrowser(['doctor'])
    expect(doctor.ok).toBe(true)
    expect(doctor.capture_dir).toBe('/workspace/temp/browser')

    const html = '<html><body><main><h1>Ankole Browser Smoke</h1></main></body></html>'
    const opened = runBrowser(['open', '--url', `data:text/html,${encodeURIComponent(html)}`])
    expect(opened.ok).toBe(true)
    expect(String(opened.text)).toContain('Ankole Browser Smoke')

    const latestText = readFileSync(join(workspaceRoot, 'temp/browser/latest.txt'), 'utf8')
    expect(latestText).toContain('Ankole Browser Smoke')

    const extracted = runBrowser(['extract', '--pattern', 'Smoke'])
    expect(String(extracted.text)).toContain('Ankole Browser Smoke')

    const script = "print('browser-run-ok')"
    const ran = runBrowser(['run', '--script', script])
    expect(ran.exit_code).toBe(0)
    expect(String(ran.stdout)).toContain('browser-run-ok')
  })
})

function runBrowser(args: string[]): Record<string, unknown> {
  const result = Bun.spawnSync(['bun', cli, '--json', ...args], {
    env: {
      ...process.env,
      ANKOLE_BROWSER_BACKEND: 'fetch',
      ANKOLE_WORKSPACE_ROOT: workspaceRoot
    },
    stdout: 'pipe',
    stderr: 'pipe'
  })
  const stdout = Buffer.from(result.stdout).toString('utf8')
  const stderr = Buffer.from(result.stderr).toString('utf8')
  expect(result.exitCode, stderr).toBe(0)
  return JSON.parse(stdout)
}
