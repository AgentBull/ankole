import { spawn, type ChildProcess } from 'node:child_process'
import { stat } from 'node:fs/promises'
import { resolve } from 'node:path'
import type { BrowserClientContext } from '../../src/client'
import { runBrowserCode } from '../../src/cli/run-command'

export const integrationEnabled = process.env.ANKOLE_BROWSER_INTEGRATION === '1'
export const chromiumExecutable =
  process.env.ANKOLE_BROWSER_TEST_CHROMIUM ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'

const packageRoot = resolve(import.meta.dir, '../..')
const runnerBootstrapPath = resolve(packageRoot, 'dist/runner/bootstrap.js')

export async function startDaemon(socketPath: string, maxActiveBrowsers?: number): Promise<ChildProcess> {
  const child = spawn(process.execPath, ['dist/daemon/main.js'], {
    cwd: packageRoot,
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

export async function withRunnerEnv<T>(fn: () => Promise<T>): Promise<T> {
  const previousRunner = process.env.ANKOLE_BROWSER_RUNNER
  process.env.ANKOLE_BROWSER_RUNNER = runnerBootstrapPath
  try {
    return await fn()
  } finally {
    if (previousRunner === undefined) delete process.env.ANKOLE_BROWSER_RUNNER
    else process.env.ANKOLE_BROWSER_RUNNER = previousRunner
  }
}

export async function runCode(
  context: BrowserClientContext,
  scriptSource: string,
  timeoutMs = 10_000
): Promise<Record<string, unknown>> {
  return await withRunnerEnv(() => runBrowserCode({ context, scriptSource, scriptArgs: [], timeoutMs }))
}

export async function runCodePath(
  context: BrowserClientContext,
  scriptPath: string,
  timeoutMs = 10_000
): Promise<Record<string, unknown>> {
  return await withRunnerEnv(() => runBrowserCode({ context, scriptPath, scriptArgs: [], timeoutMs }))
}

export async function waitForPath(path: string): Promise<void> {
  const deadline = Date.now() + 10_000
  while (Date.now() < deadline) {
    try {
      await stat(path)
      return
    } catch {
      // Wait for the daemon or runner to materialize its filesystem path.
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

export async function waitForExit(child: ChildProcess, timeoutMs: number): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return
  await Promise.race([
    new Promise<void>(resolveExit => child.once('exit', () => resolveExit())),
    Bun.sleep(timeoutMs).then(() => {
      child.kill('SIGKILL')
    })
  ])
}
