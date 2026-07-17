import { afterAll, beforeAll, describe, expect, test } from 'bun:test'
import { spawn, type ChildProcess } from 'node:child_process'
import { execFileSync } from 'node:child_process'
import { mkdtemp, mkdir, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { browserClientContextFromEnv, sendBrowserCommand, type BrowserClientContext } from '../../src/client'
import { runBrowserCode } from '../../src/cli/run-command'
import { BrowserMaterialSchema } from '../../src/protocol'

const enabled = process.env.ANKOLE_BROWSER_INTEGRATION === '1'
const chromiumExecutable =
  process.env.ANKOLE_BROWSER_TEST_CHROMIUM ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
const nodeExecutable =
  process.env.ANKOLE_BROWSER_TEST_NODE ?? execFileSync('node', ['-p', 'process.execPath'], { encoding: 'utf8' }).trim()

describe.skipIf(!enabled)('real daemon, Chromium, dialog, and code lease', () => {
  let root: string
  let socketPath: string
  let daemon: ChildProcess
  let context: BrowserClientContext
  let mainPagePath: string
  let delayedPagePath: string
  let importingScriptPath: string

  beforeAll(async () => {
    root = await mkdtemp('/tmp/ankole-browser-test-')
    socketPath = join(root, 'socket', 'browser.sock')
    const artifactRoot = join(root, 'artifacts')
    mainPagePath = join(root, 'page.html')
    delayedPagePath = join(root, 'delayed.html')
    const scriptRoot = join(root, 'scripts')
    importingScriptPath = join(scriptRoot, 'main.mjs')
    const materialPath = join(root, 'material.json')
    await mkdir(scriptRoot, { recursive: true })
    await writeFile(
      mainPagePath,
      `<!doctype html><title>Browser test</title><button id="confirm" onclick="if(confirm('continue?')) document.querySelector('#value').value='confirmed'">Confirm</button><input id="value" value="initial"><label for="query">Query</label><input id="query" type="search">`
    )
    await writeFile(
      delayedPagePath,
      `<!doctype html><title>Delayed render</title><body>Loading<script>setTimeout(() => { document.body.textContent = 'Rendered value' }, 800)</script></body>`
    )
    await writeFile(join(scriptRoot, 'helper.mjs'), `export const importedValue = 'relative-import-works'\n`)
    await writeFile(
      importingScriptPath,
      `import { importedValue } from './helper.mjs'\nexport default async () => ({ importedValue })\n`
    )
    const material = {
      protocol_version: 1,
      route_id: 'br_1234567890abcdef',
      data_root: join(root, 'data'),
      artifact_root: artifactRoot,
      immutable_fingerprint: 'sha256:integration',
      material_generation: 0,
      profile: { mode: 'persistent_user_data_dir' },
      backend: { kind: 'local_chromium', executable: chromiumExecutable, args: [] },
      navigation: { ssrf_filter: true, allow_file_urls: true },
      idle_ttl_ms: 60_000
    }
    await writeFile(materialPath, `${JSON.stringify(material)}\n`, { mode: 0o600 })
    daemon = await startDaemon(socketPath)
    context = await browserClientContextFromEnv({
      ANKOLE_BROWSER_SOCKET: socketPath,
      ANKOLE_BROWSER_ROUTE: material.route_id,
      ANKOLE_BROWSER_SESSION: 'default',
      ANKOLE_BROWSER_MATERIAL: materialPath,
      ANKOLE_BROWSER_TIMEOUT_MS: '10000'
    })
    const opened = await sendBrowserCommand(context, { name: 'open', args: { url: `file://${mainPagePath}` } })
    expect(opened.ok).toBe(true)
  }, 20_000)

  afterAll(async () => {
    if (context) {
      const purged = await sendBrowserCommand(
        context,
        { name: 'lifecycle', args: { verb: 'purge' } },
        { timeoutMs: 10_000 }
      )
      expect(purged.ok).toBe(true)
    }
    daemon?.kill('SIGTERM')
    if (daemon) await waitForExit(daemon, 5_000)
    await rm(root, { recursive: true, force: true })
  }, 20_000)

  test('confirm fails fast and is explicitly dismissible', async () => {
    const snapshot = await sendBrowserCommand(context, { name: 'snapshot', args: { interactive: true } })
    expect(snapshot.ok).toBe(true)
    const confirmLine = String(snapshot.ok ? snapshot.data : '')
      .split('\n')
      .find(line => line.includes('button') && line.includes('Confirm'))
    const ref = confirmLine?.match(/ref=(e\d+)/)?.[1]
    expect(ref).toBeTruthy()
    const started = Date.now()
    const clicked = await sendBrowserCommand(context, { name: 'click', args: { selector: `@${ref}` } })
    expect(clicked).toMatchObject({ ok: false, error: { code: 'dialog_blocked' } })
    expect(Date.now() - started).toBeLessThan(5_000)

    const screenshot = await sendBrowserCommand(context, {
      name: 'screenshot',
      args: { path: 'pending-dialog.png' }
    })
    expect(screenshot).toMatchObject({ ok: false, error: { code: 'dialog_blocked' } })
    const newTab = await sendBrowserCommand(context, { name: 'tab', args: { action: 'new' } })
    expect(newTab).toMatchObject({ ok: false, error: { code: 'dialog_blocked' } })
    const tabs = await sendBrowserCommand(context, { name: 'tab', args: { action: 'list' } })
    expect(tabs.ok).toBe(true)

    const dismissed = await sendBrowserCommand(context, { name: 'dialog', args: { action: 'dismiss' } })
    expect(dismissed.ok).toBe(true)
    const value = await sendBrowserCommand(context, { name: 'get', args: { property: 'value', selector: '#value' } })
    expect(value.ok && value.data).toBe('initial')
    const annotated = await sendBrowserCommand(context, {
      name: 'screenshot',
      args: { path: 'annotated.png', annotate: true }
    })
    if (!annotated.ok) throw new Error(JSON.stringify(annotated.error))
    expect(annotated.ok).toBe(true)
    expect((await stat(join(root, 'artifacts', 'annotated.png'))).size).toBeGreaterThan(0)
  })

  test('fresh accessibility refs resolve the same search input and missing refs fail cleanly', async () => {
    const snapshot = await sendBrowserCommand(context, { name: 'snapshot', args: { interactive: true } })
    expect(snapshot.ok).toBe(true)
    const searchLine = String(snapshot.ok ? snapshot.data : '')
      .split('\n')
      .find(line => line.includes('searchbox') && line.includes('Query'))
    const ref = searchLine?.match(/ref=(e\d+)/)?.[1]
    expect(ref).toBeTruthy()

    const value = await sendBrowserCommand(context, {
      name: 'get',
      args: { property: 'value', selector: `@${ref}` }
    })
    expect(value).toMatchObject({ ok: true, data: '' })
    const missing = await sendBrowserCommand(context, {
      name: 'get',
      args: { property: 'value', selector: '@e99999' }
    })
    expect(missing).toMatchObject({ ok: false, error: { code: 'stale_ref' } })
  })

  test('rendered fetch waits for late body text instead of returning Loading as success', async () => {
    const fetched = await sendBrowserCommand(context, {
      name: 'fetch',
      args: { urls: [`file://${delayedPagePath}`, `file://${mainPagePath}`] }
    })
    expect(fetched).toMatchObject({
      ok: true,
      data: {
        success: true,
        results: [{ text: 'Rendered value' }, { title: 'Browser test' }]
      }
    })
  }, 10_000)

  test('browser.bind runner sees and changes the same persistent page', async () => {
    const packageRoot = resolve(import.meta.dir, '../..')
    const previousRunner = process.env.ANKOLE_BROWSER_RUNNER
    const previousNode = process.env.ANKOLE_BROWSER_NODE
    process.env.ANKOLE_BROWSER_RUNNER = resolve(packageRoot, 'dist/runner/bootstrap.js')
    process.env.ANKOLE_BROWSER_NODE = nodeExecutable
    try {
      const result = await runBrowserCode({
        context,
        scriptSource: `export default async ({ page }) => { await page.locator('#value').fill('from-code'); await page.evaluate(() => localStorage.setItem('browser-test', 'from-code')); return { value: await page.locator('#value').inputValue() } }`,
        scriptArgs: [],
        timeoutMs: 15_000
      })
      expect(result.status).toBe('ok')
      expect(result.value).toEqual({ value: 'from-code' })
    } finally {
      if (previousRunner === undefined) delete process.env.ANKOLE_BROWSER_RUNNER
      else process.env.ANKOLE_BROWSER_RUNNER = previousRunner
      if (previousNode === undefined) delete process.env.ANKOLE_BROWSER_NODE
      else process.env.ANKOLE_BROWSER_NODE = previousNode
    }

    const value = await sendBrowserCommand(context, { name: 'get', args: { property: 'value', selector: '#value' } })
    expect(value.ok && value.data).toBe('from-code')
    const status = await sendBrowserCommand(context, { name: 'status', args: {} })
    expect(status.ok && (status.data as { state: string }).state).toBe('ready')
  }, 20_000)

  test('browser code executes from its source path so relative imports remain usable', async () => {
    const result = await runCodePath(context, importingScriptPath)
    expect(result).toMatchObject({ status: 'ok', value: { importedValue: 'relative-import-works' } })
  }, 20_000)

  test('browser.bind runner owns default, custom, and empty dialog policies without leaking a lease', async () => {
    const defaultPolicy = await runCode(
      context,
      `export default async ({ page }) => { await page.locator('#value').fill('default-before'); await page.locator('#confirm').click(); return await page.locator('#value').inputValue() }`
    )
    expect(defaultPolicy).toMatchObject({ status: 'ok', value: 'default-before' })

    const customPolicy = await runCode(
      context,
      `export const dialogPolicy = dialog => dialog.accept(); export default async ({ page }) => { await page.locator('#confirm').click(); return await page.locator('#value').inputValue() }`
    )
    expect(customPolicy).toMatchObject({ status: 'ok', value: 'confirmed' })

    const emptyPolicy = await runCode(
      context,
      `export const dialogPolicy = async () => {}; export default async ({ page }) => { await page.locator('#value').fill('empty-before'); await page.locator('#confirm').click(); return await page.locator('#value').inputValue() }`
    )
    expect(emptyPolicy).toMatchObject({ status: 'ok', value: 'empty-before' })
    await expect(runCode(context, `export default async () => await new Promise(() => {})`, 400)).rejects.toMatchObject(
      { code: 'timeout' }
    )
    const status = await sendBrowserCommand(context, { name: 'status', args: {} })
    expect(status.ok && (status.data as { state: string }).state).toBe('ready')
  }, 20_000)

  test('remote CDP disconnect does not close the physical browser', async () => {
    const live = JSON.parse(await readFile(join(root, 'data', 'sessions', 'default', 'live.json'), 'utf8')) as {
      endpoint: string
    }
    const material = BrowserMaterialSchema.parse({
      protocol_version: 1,
      route_id: 'br_remote1234567890',
      data_root: join(root, 'remote-data'),
      artifact_root: join(root, 'remote-artifacts'),
      immutable_fingerprint: 'sha256:remote-integration',
      material_generation: 0,
      profile: { mode: 'persistent_user_data_dir' },
      backend: {
        kind: 'remote_cdp',
        endpoint: live.endpoint,
        headers: {},
        connect_timeout_ms: 10_000,
        session_identity: 'test-remote-session'
      },
      navigation: { ssrf_filter: true, allow_file_urls: true },
      idle_ttl_ms: 60_000
    })
    const remoteContext: BrowserClientContext = {
      socketPath,
      route: material.route_id,
      session: 'default',
      material,
      artifactRoot: material.artifact_root,
      timeoutMs: 10_000
    }
    const attached = await sendBrowserCommand(remoteContext, { name: 'open', args: {} })
    expect(attached.ok).toBe(true)
    const purged = await sendBrowserCommand(remoteContext, { name: 'lifecycle', args: { verb: 'purge' } })
    expect(purged.ok).toBe(true)

    const stillAlive = await sendBrowserCommand(context, { name: 'snapshot', args: { interactive: true } })
    expect(stillAlive).toMatchObject({ ok: true })
  }, 20_000)

  test('daemon crash recovers the same local Chrome and clears an orphan confirm dialog', async () => {
    const before = JSON.parse(await readFile(join(root, 'data', 'sessions', 'default', 'live.json'), 'utf8')) as {
      pid: number
    }
    const clicked = await sendBrowserCommand(context, { name: 'click', args: { selector: '#confirm' } })
    expect(clicked).toMatchObject({ ok: false, error: { code: 'dialog_blocked' } })

    daemon.kill('SIGKILL')
    await waitForExit(daemon, 5_000)
    await rm(socketPath, { force: true })
    daemon = await startDaemon(socketPath)

    const started = Date.now()
    const snapshot = await sendBrowserCommand(
      context,
      { name: 'snapshot', args: { interactive: true } },
      { timeoutMs: 5_000 }
    )
    expect(snapshot.ok).toBe(true)
    expect(Date.now() - started).toBeLessThan(5_000)
    const after = JSON.parse(await readFile(join(root, 'data', 'sessions', 'default', 'live.json'), 'utf8')) as {
      pid: number
    }
    expect(after.pid).toBe(before.pid)
    const stored = await sendBrowserCommand(context, {
      name: 'eval',
      args: { expression: `localStorage.getItem('browser-test')` }
    })
    expect(stored.ok && stored.data).toBe('from-code')
  }, 20_000)
})

describe.skipIf(!enabled)('real browser capacity pressure', () => {
  test('a waiting route reclaims an idle warm browser instead of timing out', async () => {
    const capacityRoot = await mkdtemp('/tmp/ankole-browser-capacity-')
    const capacitySocket = join(capacityRoot, 'socket', 'browser.sock')
    const capacityDaemon = await startDaemon(capacitySocket, 1)
    const contexts = ['br_capacity00000001', 'br_capacity00000002'].map((route, index) => {
      const material = BrowserMaterialSchema.parse({
        protocol_version: 1,
        route_id: route,
        data_root: join(capacityRoot, `data-${index}`),
        artifact_root: join(capacityRoot, `artifacts-${index}`),
        immutable_fingerprint: `sha256:capacity-${index}`,
        material_generation: 0,
        profile: { mode: 'persistent_user_data_dir' },
        backend: { kind: 'local_chromium', executable: chromiumExecutable, args: [] },
        navigation: { ssrf_filter: true, allow_file_urls: false },
        idle_ttl_ms: 60_000
      })
      return {
        socketPath: capacitySocket,
        route,
        session: 'default',
        material,
        artifactRoot: material.artifact_root,
        timeoutMs: 10_000
      } satisfies BrowserClientContext
    })
    try {
      expect(await sendBrowserCommand(contexts[0]!, { name: 'open', args: {} })).toMatchObject({ ok: true })
      expect(await sendBrowserCommand(contexts[1]!, { name: 'open', args: {} })).toMatchObject({ ok: true })
      expect(await sendBrowserCommand(contexts[0]!, { name: 'status', args: {} })).toMatchObject({
        ok: true,
        data: { state: 'detached' }
      })
    } finally {
      for (const candidate of contexts) {
        await sendBrowserCommand(
          candidate,
          { name: 'lifecycle', args: { verb: 'purge' } },
          { timeoutMs: 10_000 }
        ).catch(() => undefined)
      }
      capacityDaemon.kill('SIGTERM')
      await waitForExit(capacityDaemon, 5_000)
      await rm(capacityRoot, { recursive: true, force: true })
    }
  }, 40_000)
})

async function startDaemon(socketPath: string, maxActiveBrowsers?: number): Promise<ChildProcess> {
  const child = spawn(nodeExecutable, ['dist/daemon/main.js'], {
    cwd: resolve(import.meta.dir, '../..'),
    env: {
      ...process.env,
      ANKOLE_BROWSER_DAEMON_SOCKET: socketPath,
      ...(maxActiveBrowsers === undefined ? {} : { ANKOLE_BROWSER_MAX_ACTIVE_BROWSERS: String(maxActiveBrowsers) })
    },
    stdio: ['ignore', 'pipe', 'pipe']
  })
  await waitForDaemon(child, socketPath)
  return child
}

async function runCode(
  context: BrowserClientContext,
  scriptSource: string,
  timeoutMs = 10_000
): Promise<Record<string, unknown>> {
  const previousRunner = process.env.ANKOLE_BROWSER_RUNNER
  const previousNode = process.env.ANKOLE_BROWSER_NODE
  process.env.ANKOLE_BROWSER_RUNNER = resolve(import.meta.dir, '../../dist/runner/bootstrap.js')
  process.env.ANKOLE_BROWSER_NODE = nodeExecutable
  try {
    return await runBrowserCode({ context, scriptSource, scriptArgs: [], timeoutMs })
  } finally {
    if (previousRunner === undefined) delete process.env.ANKOLE_BROWSER_RUNNER
    else process.env.ANKOLE_BROWSER_RUNNER = previousRunner
    if (previousNode === undefined) delete process.env.ANKOLE_BROWSER_NODE
    else process.env.ANKOLE_BROWSER_NODE = previousNode
  }
}

async function runCodePath(
  context: BrowserClientContext,
  scriptPath: string,
  timeoutMs = 10_000
): Promise<Record<string, unknown>> {
  const previousRunner = process.env.ANKOLE_BROWSER_RUNNER
  const previousNode = process.env.ANKOLE_BROWSER_NODE
  process.env.ANKOLE_BROWSER_RUNNER = resolve(import.meta.dir, '../../dist/runner/bootstrap.js')
  process.env.ANKOLE_BROWSER_NODE = nodeExecutable
  try {
    return await runBrowserCode({ context, scriptPath, scriptArgs: [], timeoutMs })
  } finally {
    if (previousRunner === undefined) delete process.env.ANKOLE_BROWSER_RUNNER
    else process.env.ANKOLE_BROWSER_RUNNER = previousRunner
    if (previousNode === undefined) delete process.env.ANKOLE_BROWSER_NODE
    else process.env.ANKOLE_BROWSER_NODE = previousNode
  }
}

async function waitForPath(path: string): Promise<void> {
  const deadline = Date.now() + 10_000
  while (Date.now() < deadline) {
    try {
      await stat(path)
      return
    } catch {
      // Wait for the daemon to create its Unix domain socket.
    }
    await Bun.sleep(25)
  }
  throw new Error(`timed out waiting for ${path}`)
}

async function waitForDaemon(child: ChildProcess, path: string): Promise<void> {
  let stderr = ''
  child.stderr?.on('data', chunk => {
    stderr += String(chunk)
  })
  await Promise.race([
    waitForPath(path),
    new Promise<never>((_, reject) => {
      child.once('error', reject)
      child.once('exit', (code, signal) => reject(new Error(`daemon exited (${code ?? signal}): ${stderr}`)))
    })
  ])
}

async function waitForExit(child: ChildProcess, timeoutMs: number): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return
  await Promise.race([
    new Promise<void>(resolveExit => child.once('exit', () => resolveExit())),
    Bun.sleep(timeoutMs).then(() => {
      child.kill('SIGKILL')
    })
  ])
}
