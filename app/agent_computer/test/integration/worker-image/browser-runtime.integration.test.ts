import { afterAll, beforeAll, describe, expect, test } from 'bun:test'
import { spawnSync } from 'node:child_process'
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { readFileSync } from 'node:fs'
import { mkdirAgent } from '../../../src/common/agent-user'
import { sendBrowserCommand } from '@ankole/browser'
import { BrowserRuntime, browserRuntimeEnv, type MaterializedBrowserRuntime } from '../../../src/browser-runtime'

describe('browser runtime reached by Agent commands', () => {
  let root: string
  let workspaceRoot: string
  let browserRuntime: BrowserRuntime
  let materialized: MaterializedBrowserRuntime

  beforeAll(async () => {
    root = await mkdtemp('/agents/ankole-browser-runtime-')
    await mkdirAgent(root, 0o700)
    workspaceRoot = join(root, 'jobs', 'job-1')
    await mkdir(workspaceRoot, { recursive: true })
    await writeFile(
      join(workspaceRoot, 'browser-run.mjs'),
      `export default async ({ page }) => ({ url: page.url(), connected: true })\n`
    )
    browserRuntime = new BrowserRuntime({
      runtimeRoot: join('/tmp', `ankole-browser-runtime-${process.pid}`),
      socketPath: join(root, 'socket', 'browser.sock'),
      daemonEntry: requiredEnv('ANKOLE_BROWSER_DAEMON_ENTRY'),
      runnerPath: requiredEnv('ANKOLE_BROWSER_RUNNER'),
      localChromiumExecutable: requiredEnv('ANKOLE_BROWSER_CHROMIUM_EXECUTABLE')
    })
    await browserRuntime.start()
    materialized = await browserRuntime.materializePersistent({
      scopeRoot: workspaceRoot,
      artifactRoot: join(workspaceRoot, 'browser'),
      settings: { ssrfFilter: true }
    })
  }, 20_000)

  afterAll(async () => {
    if (materialized) {
      await sendBrowserCommand(
        {
          socketPath: materialized.socketPath,
          route: materialized.route,
          session: materialized.session,
          material: materialized.material,
          artifactRoot: materialized.artifactRoot,
          timeoutMs: 10_000
        },
        { name: 'lifecycle', args: { verb: 'purge' } },
        { timeoutMs: 10_000 }
      ).catch(() => undefined)
      await materialized.cleanup().catch(() => undefined)
    }
    await browserRuntime?.stop().catch(() => undefined)
    if (root) await rm(root, { recursive: true, force: true })
  }, 20_000)

  test('OfficeCLI discovers Chromium and produces a real document screenshot', () => {
    const document = join(workspaceRoot, 'office-preview.docx')
    const output = join(workspaceRoot, 'office-preview.png')
    for (const args of [
      ['create', document],
      ['add', document, '/body', '--type', 'paragraph', '--prop', 'text=Screenshot regression'],
      ['view', document, 'screenshot', '--grid', 'auto', '-o', output]
    ]) {
      // OfficeCLI gives Chromium 20 seconds to render; allow its launch and file output too.
      const result = runCommand(['env', 'OFFICECLI_NO_AUTO_RESIDENT=1', 'officecli', ...args], 30_000)
      expect(result.status, `${result.stderr}\n${result.stdout}`).toBe(0)
    }
    const png = readFileSync(output)
    expect(png.subarray(0, 8)).toEqual(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))
    expect(png.readUInt32BE(16)).toBeGreaterThan(0)
    expect(png.readUInt32BE(20)).toBeGreaterThan(0)
  }, 40_000)

  test('the CLI reaches the Worker browser daemon from a command environment', () => {
    const result = runCommand(['/bin/sh', '-lc', 'test -z "${BROWSER_BACKEND_JSON:-}" && ankole-browser --json open'])
    expect(result.status, `${result.stderr}\n${result.stdout}`).toBe(0)
    const line = result.stdout.trim().split(/\r?\n/).at(-1)
    expect(line).toBeTruthy()
    expect(JSON.parse(line!)).toMatchObject({ ok: true, route: materialized.route, session: 'default' })
  }, 20_000)

  test('a command exit does not stop the Worker daemon or the physical browser', async () => {
    const status = await sendBrowserCommand(
      {
        socketPath: materialized.socketPath,
        route: materialized.route,
        session: materialized.session,
        material: materialized.material,
        artifactRoot: materialized.artifactRoot,
        timeoutMs: 10_000
      },
      { name: 'status', args: {} },
      { timeoutMs: 10_000 }
    )
    expect(status).toMatchObject({ ok: true, data: { state: 'ready' } })
  })

  test('the code runner reaches the same browser', () => {
    const result = runCommand([
      'ankole-browser',
      '--json',
      '--timeout',
      '15000',
      'run',
      join(workspaceRoot, 'browser-run.mjs'),
      '--run-dir',
      'browser/runs/runtime-contract'
    ])
    expect(result.status, `${result.stderr}\n${result.stdout}`).toBe(0)
    const line = result.stdout.trim().split(/\r?\n/).at(-1)
    expect(line).toBeTruthy()
    expect(JSON.parse(line!)).toMatchObject({
      ok: true,
      data: { status: 'ok', value: { connected: true } }
    })
  }, 20_000)

  test('rendered fetch reaches the daemon without a material file', async () => {
    const server = Bun.serve({
      hostname: '127.0.0.1',
      port: 0,
      fetch: () =>
        new Response('<html><body><main>Rendered Worker page</main></body></html>', {
          headers: { 'content-type': 'text/html' }
        })
    })
    try {
      const result = await browserRuntime.fetchRendered([`${server.url}page`], { ssrfFilter: false })
      expect(JSON.stringify(result)).toContain('Rendered Worker page')
    } finally {
      server.stop(true)
    }
  }, 20_000)

  test('rendered fetch cancellation ends before a delayed page responds', async () => {
    let notifyRequested!: () => void
    const requested = new Promise<void>(resolve => {
      notifyRequested = resolve
    })
    const server = Bun.serve({
      hostname: '127.0.0.1',
      port: 0,
      fetch: async () => {
        notifyRequested()
        await Bun.sleep(10_000)
        return new Response('<html><body>Delayed page</body></html>')
      }
    })
    const controller = new AbortController()
    const reason = new DOMException('Workspace closed', 'AbortError')
    const fetch = browserRuntime.fetchRendered([`${server.url}delayed`], { ssrfFilter: false }, controller.signal)
    try {
      await requested
      const cancelledAt = performance.now()
      controller.abort(reason)
      await expect(fetch).rejects.toBe(reason)
      expect(performance.now() - cancelledAt).toBeLessThan(1000)
    } finally {
      server.stop(true)
    }
  }, 20_000)

  function runCommand(argv: string[], timeout = 20_000) {
    return spawnSync(argv[0]!, argv.slice(1), {
      cwd: workspaceRoot,
      env: {
        PATH: '/usr/local/bin:/usr/bin:/bin',
        HOME: root,
        LANG: 'C.UTF-8',
        ...browserRuntimeEnv(materialized)
      },
      encoding: 'utf8',
      timeout
    })
  }
})

function requiredEnv(name: string): string {
  const value = process.env[name]
  if (!value) throw new Error(`${name} is required for the browser runtime integration test`)
  return value
}
