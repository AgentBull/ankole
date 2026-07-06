import { mkdirSync } from 'node:fs'
import { createServer } from 'node:net'
import { resolve } from 'node:path'
import {
  DEFAULT_BROWSER_COMMAND_TIMEOUT_MS,
  DEFAULT_CDP_CONNECT_TIMEOUT_MS,
  DEFAULT_LOCAL_BROWSER_IDLE_TTL_MS,
  LOCAL_CHROMIUM_SIDECAR_KEY,
  LOCAL_CHROMIUM_USER_AGENT,
  workspaceRoot
} from './constants'
import { drainProcessOutput, localCdpEndpointAlive, sleep } from './utils'
import { CdpClient } from './client'
import type { BrowserRuntimeOptions, JsonObject, LocalChromiumSidecar } from './types'

const localChromiumSidecars = new Map<string, LocalChromiumSidecar>()
let localChromiumShutdownHooksInstalled = false
let closeActiveSessionsForConnectUrl = (_connectUrl: string): void => {}

/**
 * Installs the callback used to close cached CDP sessions before a sidecar dies.
 */
export function setLocalChromiumSessionCloser(close: (connectUrl: string) => void): void {
  closeActiveSessionsForConnectUrl = close
}

/**
 * Creates an isolated BrowserContext and blank page inside a running Chromium
 * sidecar.
 *
 * One Chromium process can host many worker browser sessions, while each session
 * still gets isolated cookies/storage through its own BrowserContext.
 */
export async function createLocalBrowserContext(connectUrl: string): Promise<{
  browserContextId: string
  targetId: string
}> {
  const cdp = await CdpClient.connect(connectUrl, { timeoutMs: DEFAULT_CDP_CONNECT_TIMEOUT_MS })
  let browserContextId: string | undefined
  try {
    const context = await cdp.send<{ browserContextId: string }>('Target.createBrowserContext', {})
    browserContextId = context.browserContextId
    const target = await cdp.send<{ targetId: string }>('Target.createTarget', {
      url: 'about:blank',
      browserContextId
    })
    return { browserContextId, targetId: target.targetId }
  } catch (error) {
    if (browserContextId) {
      try {
        await cdp.send(
          'Target.disposeBrowserContext',
          { browserContextId },
          undefined,
          DEFAULT_BROWSER_COMMAND_TIMEOUT_MS
        )
      } catch {
        // Best-effort cleanup for a partially created local context.
      }
    }
    throw error
  } finally {
    cdp.close()
  }
}

/**
 * Locates the Chromium executable available in the worker image.
 */
export function findChromium(): string | null {
  const candidates = [
    process.env.ANKOLE_CHROMIUM_PATH,
    'chromium',
    'chromium-browser',
    'google-chrome',
    'google-chrome-stable'
  ].filter((candidate): candidate is string => typeof candidate === 'string' && candidate.length > 0)

  for (const candidate of candidates) {
    const result = Bun.spawnSync(['bash', '-lc', `command -v ${JSON.stringify(candidate)}`], {
      stdout: 'pipe',
      stderr: 'pipe'
    })
    const stdout = Buffer.from(result.stdout).toString('utf8').trim()
    if (result.exitCode === 0 && stdout) return stdout
  }

  return null
}

/**
 * Polls `/json/version` until Chromium exposes its browser WebSocket URL.
 */
async function pollJsonVersionForWebSocket(
  url: string,
  headers: Record<string, string> | undefined,
  exited?: Promise<number | null>
): Promise<string> {
  const deadline = Date.now() + 10_000
  let lastError = ''

  while (Date.now() < deadline) {
    if (exited) {
      const exit = await Promise.race([exited.then(code => ({ code })), sleep(0).then(() => null)])
      if (exit?.code !== undefined && exit.code !== null) break
    }

    try {
      const response = await fetch(url, {
        headers,
        signal: AbortSignal.timeout(1_000)
      })
      if (response.ok) {
        const body = (await response.json()) as JsonObject
        const connectUrl = body['webSocketDebuggerUrl']
        if (typeof connectUrl === 'string' && connectUrl.length > 0) return connectUrl
      }
      lastError = `HTTP ${response.status}`
    } catch (error) {
      lastError = error instanceof Error ? error.message : String(error)
    }
    await sleep(250)
  }

  throw new Error(`Chromium CDP did not become ready: ${lastError}`)
}

/**
 * Returns a live local Chromium sidecar or starts one.
 *
 * The sidecar is shared by sessions to avoid process startup cost. Session
 * isolation is handled by BrowserContext, and idle timers stop the process when
 * the worker no longer needs it.
 */
export async function ensureLocalChromiumSidecar(key: string, idleTtlMs: number): Promise<LocalChromiumSidecar> {
  installLocalChromiumShutdownHooks()

  const existing = localChromiumSidecars.get(key)
  if (existing && existing.proc.exitCode === null && (await localCdpEndpointAlive(existing.connectUrl))) {
    existing.lastUsedAtUnixMs = Date.now()
    existing.idleTtlMs = idleTtlMs
    scheduleLocalSidecarIdleStop(existing)
    return existing
  }

  if (existing) {
    await stopLocalSidecar(existing)
  }

  const chromium = findChromium()
  if (!chromium) throw new Error('local browser requires Chromium; no remote CDP override is configured')

  const port = await allocateLocalPort()
  const profileDir = resolve(workspaceRoot, '.sessions/_browser/chromium/profile')
  mkdirSync(profileDir, { recursive: true })
  const proc = Bun.spawn(
    [
      chromium,
      '--headless=new',
      '--renderer-process-limit=4',
      '--no-zygote',
      '--no-sandbox',
      '--disable-gpu',
      '--disable-dev-shm-usage',
      '--disable-sync',
      '--disable-background-networking',
      '--disable-default-apps',
      '--disable-translate',
      '--disable-popup-blocking',
      '--disable-notifications',
      '--disable-extensions',
      `--user-agent=${LOCAL_CHROMIUM_USER_AGENT}`,
      '--remote-debugging-address=127.0.0.1',
      `--remote-debugging-port=${port}`,
      `--user-data-dir=${profileDir}`,
      'about:blank'
    ],
    {
      cwd: workspaceRoot,
      env: process.env,
      stdout: 'pipe',
      stderr: 'pipe'
    }
  )
  drainProcessOutput(proc.stdout, `chromium:${key}:stdout`)
  drainProcessOutput(proc.stderr, `chromium:${key}:stderr`)

  const cdpHttpUrl = `http://127.0.0.1:${port}`
  const connectUrl = await pollJsonVersionForWebSocket(`${cdpHttpUrl}/json/version`, undefined, proc.exited)
  const sidecar: LocalChromiumSidecar = {
    key,
    port,
    proc,
    connectUrl,
    cdpHttpUrl,
    profileDir,
    startedAtUnixMs: Date.now(),
    lastUsedAtUnixMs: Date.now(),
    idleTtlMs
  }
  localChromiumSidecars.set(key, sidecar)
  scheduleLocalSidecarIdleStop(sidecar)
  proc.exited.then(() => {
    const current = localChromiumSidecars.get(key)
    if (current === sidecar) {
      if (sidecar.idleTimer) clearTimeout(sidecar.idleTimer)
      localChromiumSidecars.delete(key)
      closeActiveSessionsForConnectUrl(sidecar.connectUrl)
    }
  })
  return sidecar
}

/**
 * Returns the singleton key for the local Chromium sidecar.
 */
export function localSidecarKey(): string {
  return LOCAL_CHROMIUM_SIDECAR_KEY
}

/**
 * Reads the configured idle TTL with a sane default.
 */
export function localBrowserIdleTtlMs(options?: BrowserRuntimeOptions): number {
  const value = options?.localBrowserIdleTtlMs
  if (typeof value === 'number' && Number.isFinite(value) && value > 0) {
    return Math.floor(value)
  }
  return DEFAULT_LOCAL_BROWSER_IDLE_TTL_MS
}

/**
 * Refreshes the sidecar idle deadline after a session uses it.
 */
export function touchLocalChromiumSidecar(key: string, idleTtlMs: number): void {
  const sidecar = localChromiumSidecars.get(key)
  if (!sidecar || sidecar.proc.exitCode !== null) return
  sidecar.lastUsedAtUnixMs = Date.now()
  sidecar.idleTtlMs = idleTtlMs
  scheduleLocalSidecarIdleStop(sidecar)
}

/**
 * Schedules best-effort sidecar shutdown after the idle TTL.
 */
function scheduleLocalSidecarIdleStop(sidecar: LocalChromiumSidecar): void {
  if (sidecar.idleTimer) clearTimeout(sidecar.idleTimer)
  sidecar.idleTimer = setTimeout(() => {
    const current = localChromiumSidecars.get(sidecar.key)
    if (current !== sidecar) return
    if (Date.now() - sidecar.lastUsedAtUnixMs < sidecar.idleTtlMs) {
      scheduleLocalSidecarIdleStop(sidecar)
      return
    }
    stopLocalSidecar(sidecar).catch(() => {
      // Best-effort idle cleanup.
    })
  }, sidecar.idleTtlMs)
  sidecar.idleTimer.unref?.()
}

/**
 * Stops a local Chromium sidecar and closes cached sessions attached to it.
 */
export async function stopLocalSidecar(sidecar: LocalChromiumSidecar): Promise<void> {
  if (sidecar.idleTimer) clearTimeout(sidecar.idleTimer)
  localChromiumSidecars.delete(sidecar.key)
  closeActiveSessionsForConnectUrl(sidecar.connectUrl)
  if (sidecar.proc.exitCode !== null) return

  try {
    sidecar.proc.kill('SIGTERM')
  } catch {
    return
  }

  const exited = await Promise.race([sidecar.proc.exited.then(() => true), sleep(5_000).then(() => false)])
  if (!exited && sidecar.proc.exitCode === null) {
    try {
      sidecar.proc.kill('SIGKILL')
    } catch {
      // Process may already be gone.
    }
  }
}

/**
 * Stops a local Chromium sidecar by cache key when it exists.
 */
export async function stopLocalSidecarByKey(key: string): Promise<void> {
  const sidecar = localChromiumSidecars.get(key)
  if (sidecar) await stopLocalSidecar(sidecar)
}

/**
 * Registers process signal handlers that terminate local Chromium sidecars.
 */
function installLocalChromiumShutdownHooks(): void {
  if (localChromiumShutdownHooksInstalled) return
  localChromiumShutdownHooksInstalled = true
  for (const signal of ['SIGINT', 'SIGTERM'] as const) {
    process.once(signal, () => {
      for (const sidecar of localChromiumSidecars.values()) {
        try {
          sidecar.proc.kill('SIGTERM')
        } catch {
          // Process may already be gone.
        }
      }
    })
  }
}

/**
 * Allocates a loopback TCP port for Chromium remote debugging.
 */
async function allocateLocalPort(): Promise<number> {
  return await new Promise((resolvePort, rejectPort) => {
    const server = createServer()
    server.once('error', rejectPort)
    server.listen(0, '127.0.0.1', () => {
      const address = server.address()
      if (!address || typeof address === 'string') {
        server.close()
        rejectPort(new Error('failed to allocate local browser port'))
        return
      }
      const port = address.port
      server.close(error => {
        if (error) rejectPort(error)
        else resolvePort(port)
      })
    })
  })
}
