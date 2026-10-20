import { spawn, type ChildProcess } from 'node:child_process'
import { cp, mkdir, open, readFile, rename, rm, stat } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { chromium, type Browser } from 'playwright-core'
import { startWebProxy, type WebProxy } from '@ankole/kernel'
import type { BrowserMaterial } from '../protocol'
import { BrowserDataError, isFileNotFound } from '../errors'
import { dismissOrphanDialogsBeforeAttach } from './raw-cdp'

type LiveMetadata = {
  pid: number
  endpoint: string
  profile_dir: string
  started_at: string
  proxy_port?: number
  ssrf_filter?: boolean
}

export type LocalChromiumHandle = {
  browser: Browser
  process?: ChildProcess
  pid: number
  endpoint: string
  stop: () => Promise<void>
}

export async function connectLocalChromium(material: BrowserMaterial, session: string): Promise<LocalChromiumHandle> {
  if (material.backend.kind !== 'local_chromium') throw new Error('local backend material required')
  const sessionRoot = join(material.data_root, 'sessions', session)
  const profileDir = join(sessionRoot, 'profile')
  const livePath = join(sessionRoot, 'live.json')
  await mkdir(sessionRoot, { recursive: true })
  await initializeProfile(profileDir, material.profile.seed_path)

  validateProxyArguments(material.backend.args)
  const recovered = await recoverLiveBrowser(livePath, 30_000, material.navigation.ssrf_filter)
  if (recovered) return recovered

  const proxy = startWebProxy(material.navigation.ssrf_filter)
  const child = spawn(
    material.backend.executable,
    [
      '--headless=new',
      '--no-sandbox',
      '--disable-dev-shm-usage',
      '--disable-background-networking',
      '--disable-default-apps',
      '--disable-sync',
      '--no-first-run',
      '--no-default-browser-check',
      '--remote-debugging-address=127.0.0.1',
      '--remote-debugging-port=0',
      `--user-data-dir=${profileDir}`,
      ...material.backend.args,
      `--proxy-server=socks5://127.0.0.1:${proxy.port}`,
      '--proxy-bypass-list=<-loopback>',
      '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1',
      '--disable-quic',
      '--force-webrtc-ip-handling-policy=disable_non_proxied_udp',
      'about:blank'
    ],
    {
      cwd: sessionRoot,
      detached: true,
      stdio: ['ignore', 'ignore', 'pipe'],
      env: process.env
    }
  )
  child.unref()
  let browser: Browser | undefined
  try {
    const endpoint = await waitForDevToolsEndpoint(child, 30_000)
    const pid = child.pid
    if (!pid) throw new BrowserDataError('backend_unavailable', 'Chromium did not expose a process id')
    browser = await chromium.connectOverCDP(endpoint, { timeout: 30_000 })
    const metadata: LiveMetadata = {
      pid,
      endpoint,
      profile_dir: profileDir,
      started_at: new Date().toISOString(),
      proxy_port: proxy.port,
      ssrf_filter: material.navigation.ssrf_filter
    }
    await atomicJSON(livePath, metadata)
    return handle(browser, endpoint, pid, livePath, child, proxy)
  } catch (error) {
    await browser?.close().catch(() => undefined)
    await stopChild(child)
    await proxy.close()
    await rm(livePath, { force: true })
    throw error
  }
}

export async function purgeDetachedLocalChromium(material: BrowserMaterial, session: string): Promise<void> {
  if (material.backend.kind !== 'local_chromium') return
  const sessionRoot = join(material.data_root, 'sessions', session)
  const livePath = join(sessionRoot, 'live.json')
  const recovered = await recoverLiveBrowser(livePath, 2_000)
  if (recovered) await recovered.stop()
}

async function recoverLiveBrowser(
  livePath: string,
  timeout: number,
  ssrfFilter?: boolean
): Promise<LocalChromiumHandle | undefined> {
  let metadata: LiveMetadata
  try {
    metadata = JSON.parse(await readFile(livePath, 'utf8')) as LiveMetadata
  } catch (error) {
    if (isFileNotFound(error)) return undefined
    throw error
  }
  if (!Number.isInteger(metadata.pid) || !metadata.endpoint || !processAlive(metadata.pid)) {
    await rm(livePath, { force: true })
    return undefined
  }
  let proxy: WebProxy | undefined
  try {
    if (
      ssrfFilter !== undefined &&
      metadata.ssrf_filter === ssrfFilter &&
      Number.isInteger(metadata.proxy_port) &&
      metadata.proxy_port! > 0 &&
      metadata.proxy_port! <= 65535
    ) {
      proxy = startWebProxy(ssrfFilter, metadata.proxy_port)
    }
    await dismissOrphanDialogsBeforeAttach(metadata.endpoint)
    const browser = await chromium.connectOverCDP(metadata.endpoint, { timeout })
    const recovered = handle(browser, metadata.endpoint, metadata.pid, livePath, undefined, proxy)
    // A pre-proxy browser or a changed network policy needs a new process. Keep
    // its profile, and close only through its verified CDP connection.
    if (ssrfFilter !== undefined && !proxy) {
      await recovered.stop()
      return undefined
    }
    return recovered
  } catch (cause) {
    await proxy?.close()
    throw new BrowserDataError(
      'backend_unavailable',
      'Saved Chromium is unreachable. Profile and live metadata were retained; restore CDP or stop that browser before retrying',
      { cause }
    )
  }
}

function handle(
  browser: Browser,
  endpoint: string,
  pid: number,
  livePath: string,
  child?: ChildProcess,
  proxy?: WebProxy
): LocalChromiumHandle {
  return {
    browser,
    process: child,
    pid,
    endpoint,
    stop: async () => {
      try {
        try {
          const session = await browser.newBrowserCDPSession()
          await session.send('Browser.close')
        } catch (cause) {
          if (!child) {
            throw new BrowserDataError(
              'backend_unavailable',
              'Chromium could not be closed through its saved CDP connection; profile and live metadata were retained',
              { cause }
            )
          }
        }
        if (child) await stopChild(child)
        await browser.close().catch(() => undefined)
        await rm(livePath, { force: true })
      } finally {
        await proxy?.close()
      }
    }
  }
}

function validateProxyArguments(args: string[]): void {
  const managed = new Set([
    '--proxy-server',
    '--proxy-bypass-list',
    '--proxy-pac-url',
    '--proxy-auto-detect',
    '--no-proxy-server',
    '--host-resolver-rules',
    '--enable-quic',
    '--force-webrtc-ip-handling-policy'
  ])
  const conflict = args.find(arg => managed.has(arg.split('=')[0]!))
  if (conflict) {
    throw new BrowserDataError(
      'invalid_material',
      `Chromium argument conflicts with the browser network policy: ${conflict}`
    )
  }
}

async function initializeProfile(profileDir: string, seedPath?: string): Promise<void> {
  try {
    await stat(profileDir)
    return
  } catch (error) {
    if (!isFileNotFound(error)) throw error
  }
  await mkdir(dirname(profileDir), { recursive: true })
  if (seedPath) await cp(seedPath, profileDir, { recursive: true, force: false, errorOnExist: false })
  else await mkdir(profileDir, { recursive: true })
}

async function waitForDevToolsEndpoint(child: ChildProcess, timeoutMs: number): Promise<string> {
  const stderr = child.stderr
  if (!stderr) throw new BrowserDataError('backend_unavailable', 'Chromium stderr is unavailable')
  return await new Promise<string>((resolve, reject) => {
    let buffer = ''
    let settled = false
    const finish = (callback: () => void): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      stderr.removeAllListeners()
      child.removeListener('exit', onExit)
      child.removeListener('error', onError)
      callback()
    }
    const onExit = (code: number | null): void =>
      finish(() =>
        reject(new BrowserDataError('backend_unavailable', `Chromium exited before CDP was ready (${code})`))
      )
    const onError = (error: Error): void =>
      finish(() =>
        reject(
          new BrowserDataError('backend_unavailable', `Chromium failed to start: ${error.message}`, { cause: error })
        )
      )
    const timer = setTimeout(
      () => finish(() => reject(new BrowserDataError('backend_unavailable', 'Chromium CDP startup timed out'))),
      timeoutMs
    )
    child.once('exit', onExit)
    child.once('error', onError)
    stderr.on('data', chunk => {
      buffer = `${buffer}${Buffer.from(chunk).toString('utf8')}`.slice(-64 * 1024)
      const match = buffer.match(/DevTools listening on (ws:\/\/[^\s]+)/)
      if (match?.[1]) finish(() => resolve(match[1]!))
    })
  })
}

// Only the live ChildProcess handle may receive OS signals. Persisted PIDs
// are observation hints and never termination authority.
async function stopChild(child: ChildProcess): Promise<void> {
  if (!child.pid || child.exitCode !== null || child.signalCode !== null) return
  child.kill('SIGTERM')
  const exited = new Promise<void>(resolve => child.once('exit', () => resolve()))
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    await Promise.race([
      exited,
      new Promise<void>(resolve => {
        timer = setTimeout(resolve, 2_000)
      })
    ])
    if (child.exitCode === null && child.signalCode === null) {
      child.kill('SIGKILL')
      await exited
    }
  } finally {
    if (timer) clearTimeout(timer)
  }
}

function processAlive(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

async function atomicJSON(path: string, value: unknown): Promise<void> {
  await mkdir(dirname(path), { recursive: true })
  const temporary = `${path}.${crypto.randomUUID()}.tmp`
  const file = await open(temporary, 'w', 0o600)
  try {
    await file.writeFile(`${JSON.stringify(value)}\n`)
  } finally {
    await file.close()
  }
  await rename(temporary, path)
}
