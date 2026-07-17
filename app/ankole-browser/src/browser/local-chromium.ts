import { spawn, type ChildProcess } from 'node:child_process'
import { cp, mkdir, open, readFile, rename, rm, stat } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { chromium, type Browser } from 'playwright-core'
import type { BrowserMaterial } from '../protocol'
import { BrowserDataError } from '../errors'
import { dismissOrphanDialogsBeforeAttach } from './raw-cdp'

type LiveMetadata = {
  pid: number
  endpoint: string
  profile_dir: string
  started_at: string
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

  const recovered = await recoverLiveBrowser(livePath, 30_000)
  if (recovered) return recovered

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
      started_at: new Date().toISOString()
    }
    await atomicJSON(livePath, metadata)
    return handle(browser, endpoint, pid, livePath, child)
  } catch (error) {
    await browser?.close().catch(() => undefined)
    if (child.pid) await terminateProcessGroup(child.pid)
    await rm(livePath, { force: true })
    throw error
  }
}

export async function purgeDetachedLocalChromium(material: BrowserMaterial, session: string): Promise<void> {
  if (material.backend.kind !== 'local_chromium') return
  const sessionRoot = join(material.data_root, 'sessions', session)
  const livePath = join(sessionRoot, 'live.json')
  try {
    const metadata = JSON.parse(await readFile(livePath, 'utf8')) as Partial<LiveMetadata>
    if (Number.isInteger(metadata.pid) && metadata.pid! > 0) await terminateProcessGroup(metadata.pid!)
  } catch {
    // Missing or malformed metadata has no process identity that can be reclaimed safely.
  }
  await rm(livePath, { force: true })
}

async function recoverLiveBrowser(livePath: string, timeout: number): Promise<LocalChromiumHandle | undefined> {
  let metadata: LiveMetadata
  try {
    metadata = JSON.parse(await readFile(livePath, 'utf8')) as LiveMetadata
  } catch {
    return undefined
  }
  if (!Number.isInteger(metadata.pid) || !metadata.endpoint || !processAlive(metadata.pid)) {
    await rm(livePath, { force: true })
    return undefined
  }
  try {
    await dismissOrphanDialogsBeforeAttach(metadata.endpoint)
    const browser = await chromium.connectOverCDP(metadata.endpoint, { timeout })
    return handle(browser, metadata.endpoint, metadata.pid, livePath)
  } catch {
    await terminateProcessGroup(metadata.pid)
    await rm(livePath, { force: true })
    return undefined
  }
}

function handle(
  browser: Browser,
  endpoint: string,
  pid: number,
  livePath: string,
  child?: ChildProcess
): LocalChromiumHandle {
  return {
    browser,
    process: child,
    pid,
    endpoint,
    stop: async () => {
      await rm(livePath, { force: true })
      await terminateProcessGroup(pid)
    }
  }
}

async function initializeProfile(profileDir: string, seedPath?: string): Promise<void> {
  try {
    await stat(profileDir)
    return
  } catch {
    // Initialize once below.
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

async function terminateProcessGroup(pid: number): Promise<void> {
  if (!processAlive(pid)) return
  try {
    process.kill(-pid, 'SIGTERM')
  } catch {
    try {
      process.kill(pid, 'SIGTERM')
    } catch {
      return
    }
  }
  const deadline = Date.now() + 2_000
  while (Date.now() < deadline && processAlive(pid)) await new Promise(resolve => setTimeout(resolve, 50))
  if (!processAlive(pid)) return
  try {
    process.kill(-pid, 'SIGKILL')
  } catch {
    try {
      process.kill(pid, 'SIGKILL')
    } catch {
      // Process already exited.
    }
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
