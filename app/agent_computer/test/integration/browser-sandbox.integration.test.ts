import { afterAll, beforeAll, describe, expect, test } from 'bun:test'
import { spawnSync } from 'node:child_process'
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { sendBrowserCommand } from '@ankole/browser'
import { BrowserRuntime, browserSandboxRuntime, type MaterializedBrowserRuntime } from '../../src/browser-runtime'
import { bubblewrapArgv } from '../../src/tools/computer/bubblewrap'

const enabled = process.env.ANKOLE_BROWSER_BWRAP_INTEGRATION === '1'

describe.skipIf(!enabled)('browser runtime across the real bubblewrap boundary', () => {
  let root: string
  let workspaceRoot: string
  let browserRuntime: BrowserRuntime
  let materialized: MaterializedBrowserRuntime
  let hostTmpMarker: string

  beforeAll(async () => {
    root = await mkdtemp('/agents/ankole-browser-bwrap-')
    workspaceRoot = join(root, 'jobs', 'job-1')
    await mkdir(workspaceRoot, { recursive: true })
    await writeFile(
      join(workspaceRoot, 'browser-run.mjs'),
      `export default async ({ page }) => ({ url: page.url(), connected: true })\n`
    )
    browserRuntime = new BrowserRuntime({
      runtimeRoot: join('/tmp', `ankole-browser-bwrap-${process.pid}`),
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
    hostTmpMarker = `/tmp/ankole-browser-bwrap-host-${process.pid}`
    await writeFile(hostTmpMarker, 'must not be visible inside bwrap')
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
    if (hostTmpMarker) await rm(hostTmpMarker, { force: true })
    if (root) await rm(root, { recursive: true, force: true })
  }, 20_000)

  test('CLI reaches the outside daemon through explicit read-only binds', () => {
    const sandbox = browserSandboxRuntime(materialized)
    const argv = bubblewrapArgv(
      {
        workspaceRoot,
        cwd: workspaceRoot,
        env: {
          PATH: '/usr/local/bin:/usr/bin:/bin',
          HOME: root,
          LANG: 'C.UTF-8',
          ...sandbox.env
        },
        extraBinds: sandbox.binds,
        commandArgv: [
          '/bin/sh',
          '-lc',
          `test ! -e ${hostTmpMarker} && test -z "\${BROWSER_BACKEND_JSON:-}" && ankole-browser --json open`
        ]
      },
      'strong'
    )
    const result = spawnSync(argv[0]!, argv.slice(1), {
      cwd: workspaceRoot,
      encoding: 'utf8',
      timeout: 20_000
    })
    expect(result.status, `${result.stderr}\n${result.stdout}`).toBe(0)
    const line = result.stdout.trim().split(/\r?\n/).at(-1)
    expect(line).toBeTruthy()
    expect(JSON.parse(line!)).toMatchObject({ ok: true, route: materialized.route, session: 'default' })
  }, 20_000)

  test('bwrap command exit does not kill the worker daemon or physical browser', async () => {
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

  test('code runner reaches the same browser through the real bubblewrap boundary', () => {
    const sandbox = browserSandboxRuntime(materialized)
    const argv = bubblewrapArgv(
      {
        workspaceRoot,
        cwd: workspaceRoot,
        env: {
          PATH: '/usr/local/bin:/usr/bin:/bin',
          HOME: root,
          LANG: 'C.UTF-8',
          ...sandbox.env
        },
        extraBinds: sandbox.binds,
        commandArgv: [
          'ankole-browser',
          '--json',
          '--timeout',
          '15000',
          'run',
          join(workspaceRoot, 'browser-run.mjs'),
          '--run-dir',
          'browser/runs/bwrap-contract'
        ]
      },
      'strong'
    )
    const result = spawnSync(argv[0]!, argv.slice(1), {
      cwd: workspaceRoot,
      encoding: 'utf8',
      timeout: 20_000
    })
    expect(result.status, `${result.stderr}\n${result.stdout}`).toBe(0)
    const line = result.stdout.trim().split(/\r?\n/).at(-1)
    expect(line).toBeTruthy()
    expect(JSON.parse(line!)).toMatchObject({
      ok: true,
      data: { status: 'ok', value: { connected: true } }
    })
  }, 20_000)
})

function requiredEnv(name: string): string {
  const value = process.env[name]
  if (!value) throw new Error(`${name} is required for browser bwrap integration`)
  return value
}
