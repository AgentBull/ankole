import { fork, type ChildProcess } from 'node:child_process'
import { createWriteStream } from 'node:fs'
import { copyFile, mkdir, open, readFile, rename, stat } from 'node:fs/promises'
import { dirname, isAbsolute, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { BrowserDataError } from '../errors'
import type { BrowserCommand } from '../protocol'
import { sendBrowserCommand, type BrowserClientContext } from '../client'

type RunInput = {
  context: BrowserClientContext
  session?: string
  scriptPath?: string
  scriptSource?: string
  runDir?: string
  scriptArgs: string[]
  timeoutMs: number
  signal?: AbortSignal
}

type LeaseData = {
  lease_token: string
  endpoint: string
  context_ordinal: number
  page_ordinal: number
  expires_at: number
}

type RunResult = {
  run_id: string
  status: 'ok' | 'error' | 'cancelled' | 'timeout'
  value: unknown
  error: Record<string, unknown> | null
  started_at: string
  completed_at: string
}

export async function runBrowserCode(input: RunInput): Promise<Record<string, unknown>> {
  const runId = `run_${crypto.randomUUID()}`
  const runDir = resolveRunDir(input.context, input.runDir)
  const scriptCopy = resolve(runDir, 'script.mjs')
  const scriptCwd = process.cwd()
  let executionScript: string
  await mkdir(runDir, { recursive: true })
  if (input.scriptSource !== undefined) {
    await atomicText(scriptCopy, input.scriptSource)
    executionScript = scriptCopy
  } else if (input.scriptPath) {
    executionScript = resolve(input.scriptPath)
    if (executionScript !== scriptCopy) await copyFile(executionScript, scriptCopy)
  } else throw new BrowserDataError('invalid_command', 'run requires script source or path')

  const controller = new AbortController()
  const timeout = setTimeout(
    () => controller.abort(new BrowserDataError('timeout', 'browser code run timed out', { retryable: true })),
    input.timeoutMs
  )
  timeout.unref()
  const forwardAbort = (): void => controller.abort(input.signal?.reason ?? new DOMException('cancelled', 'AbortError'))
  input.signal?.addEventListener('abort', forwardAbort, { once: true })

  let lease: LeaseData | undefined
  let child: ChildProcess | undefined
  let outcome: 'ok' | 'error' | 'cancelled' = 'error'
  const startedAt = new Date().toISOString()
  try {
    lease = leaseData(
      await successfulData(
        input.context,
        { name: 'lease.acquire', args: { run_id: runId } },
        input.session,
        input.timeoutMs,
        controller.signal
      )
    )
    child = spawnRunner({ input, lease, runId, runDir, executionScript, scriptCwd })
    const runner = observeRunner(child)
    await abortable(runner.ready, controller.signal)
    await successfulData(
      input.context,
      { name: 'lease.delegate', args: { lease_token: lease.lease_token } },
      input.session,
      remaining(input.timeoutMs, startedAt),
      controller.signal
    )
    child.send?.({ type: 'runner.start' })
    await abortable(runner.done, controller.signal)
    if (!(await waitForExit(child, 2_000))) await stopRunner(child, 'runner completed but did not exit')
    const result = await readRunResult(runDir)
    outcome = result.status === 'ok' ? 'ok' : result.status === 'cancelled' ? 'cancelled' : 'error'
    return {
      run_dir: modelRunDir(input.context, runDir),
      status: result.status,
      value: result.value,
      error: result.error
    }
  } catch (error) {
    outcome = controller.signal.aborted ? 'cancelled' : 'error'
    if (child) await stopRunner(child, controller.signal.reason)
    const status = error instanceof BrowserDataError && error.code === 'timeout' ? 'timeout' : outcome
    const fallback: RunResult = {
      run_id: runId,
      status,
      value: null,
      error: serializableError(error),
      started_at: startedAt,
      completed_at: new Date().toISOString()
    }
    await ensureRunResult(runDir, fallback)
    throw error
  } finally {
    clearTimeout(timeout)
    input.signal?.removeEventListener('abort', forwardAbort)
    if (lease) {
      await sendBrowserCommand(
        input.context,
        { name: 'lease.release', args: { lease_token: lease.lease_token, outcome } },
        { session: input.session, timeoutMs: 5_000 }
      ).catch(() => undefined)
    }
  }
}

function spawnRunner(input: {
  input: RunInput
  lease: LeaseData
  runId: string
  runDir: string
  executionScript: string
  scriptCwd: string
}): ChildProcess {
  const runnerPath =
    process.env.ANKOLE_BROWSER_RUNNER ?? fileURLToPath(new URL('../runner/bootstrap.js', import.meta.url))
  const nodePath = process.env.ANKOLE_BROWSER_NODE ?? process.execPath
  const env = Object.fromEntries(
    Object.entries(process.env).filter(([key, value]) => value !== undefined && !key.startsWith('ANKOLE_BROWSER_'))
  ) as Record<string, string>
  Object.assign(env, {
    ANKOLE_BROWSER_BOUND_ENDPOINT: input.lease.endpoint,
    ANKOLE_BROWSER_LEASE_TOKEN: input.lease.lease_token,
    ANKOLE_BROWSER_CONTEXT_ORDINAL: String(input.lease.context_ordinal),
    ANKOLE_BROWSER_PAGE_ORDINAL: String(input.lease.page_ordinal),
    ANKOLE_BROWSER_RUN_ID: input.runId,
    ANKOLE_BROWSER_RUN_DIR: input.runDir,
    ANKOLE_BROWSER_SCRIPT: input.executionScript,
    ANKOLE_BROWSER_SCRIPT_ARGS: JSON.stringify(input.input.scriptArgs)
  })
  const stdout = createWriteStream(resolve(input.runDir, 'runner.stdout.log'), { flags: 'a', mode: 0o600 })
  const stderr = createWriteStream(resolve(input.runDir, 'runner.stderr.log'), { flags: 'a', mode: 0o600 })
  const child = fork(runnerPath, [], {
    execPath: nodePath,
    cwd: input.scriptCwd,
    env,
    stdio: ['ignore', 'pipe', 'pipe', 'ipc'],
    serialization: 'json'
  })
  child.stdout?.pipe(stdout)
  child.stderr?.pipe(stderr)
  child.once('close', () => {
    stdout.end()
    stderr.end()
  })
  return child
}

function observeRunner(child: ChildProcess): { ready: Promise<void>; done: Promise<void> } {
  let resolveReady!: () => void
  let rejectReady!: (error: unknown) => void
  let resolveDone!: () => void
  let rejectDone!: (error: unknown) => void
  const ready = new Promise<void>((resolve, reject) => {
    resolveReady = resolve
    rejectReady = reject
  })
  const done = new Promise<void>((resolve, reject) => {
    resolveDone = resolve
    rejectDone = reject
  })
  let readySeen = false
  let doneSeen = false
  child.on('message', message => {
    if (!message || typeof message !== 'object') return
    const type = (message as { type?: unknown }).type
    if (type === 'runner.ready' && !readySeen) {
      readySeen = true
      resolveReady()
    }
    if (type === 'runner.done' && !doneSeen) {
      doneSeen = true
      if (!readySeen) rejectReady(new BrowserDataError('internal', 'browser runner finished before ready'))
      resolveDone()
    }
  })
  const fail = (error: unknown): void => {
    if (!readySeen) rejectReady(error)
    if (!doneSeen) rejectDone(error)
  }
  child.once('error', fail)
  child.once('exit', (code, signal) => {
    if (!doneSeen) fail(new BrowserDataError('internal', `browser runner exited before completion (${code ?? signal})`))
  })
  return { ready, done }
}

async function stopRunner(child: ChildProcess, reason: unknown): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return
  child.send?.({
    type: 'runner.abort',
    reason: reason instanceof Error ? reason.message : String(reason ?? 'cancelled')
  })
  if (await waitForExit(child, 2_000)) return
  child.kill('SIGTERM')
  if (await waitForExit(child, 500)) return
  child.kill('SIGKILL')
}

async function waitForExit(child: ChildProcess, timeoutMs: number): Promise<boolean> {
  if (child.exitCode !== null || child.signalCode !== null) return true
  return await new Promise(resolve => {
    const timer = setTimeout(() => resolve(false), timeoutMs)
    child.once('exit', () => {
      clearTimeout(timer)
      resolve(true)
    })
  })
}

async function successfulData(
  context: BrowserClientContext,
  command: BrowserCommand,
  session: string | undefined,
  timeoutMs: number,
  signal?: AbortSignal
): Promise<unknown> {
  const response = await sendBrowserCommand(context, command, { session, timeoutMs, signal })
  if (response.ok) return response.data
  throw new BrowserDataError(response.error.code, response.error.message, {
    retryable: response.error.retryable,
    details: response.error.details
  })
}

function leaseData(value: unknown): LeaseData {
  if (!value || typeof value !== 'object') throw new BrowserDataError('internal', 'lease response is invalid')
  const candidate = value as Record<string, unknown>
  if (
    typeof candidate.lease_token !== 'string' ||
    typeof candidate.endpoint !== 'string' ||
    !Number.isInteger(candidate.context_ordinal) ||
    !Number.isInteger(candidate.page_ordinal) ||
    !Number.isInteger(candidate.expires_at)
  ) {
    throw new BrowserDataError('internal', 'lease response fields are invalid')
  }
  return candidate as LeaseData
}

function resolveRunDir(context: BrowserClientContext, requested?: string): string {
  const root = resolve(context.artifactRoot)
  let path: string
  if (!requested) path = resolve(root, 'runs', `ad-hoc-${new Date().toISOString().replace(/[:.]/g, '-')}`)
  else if (requested.startsWith('browser/')) path = resolve(root, requested.slice('browser/'.length))
  else path = isAbsolute(requested) ? resolve(requested) : resolve(root, requested)
  const child = relative(root, path)
  if (child === '..' || child.startsWith(`..${process.platform === 'win32' ? '\\' : '/'}`) || isAbsolute(child)) {
    throw new BrowserDataError('invalid_command', 'run directory must stay inside browser artifact root')
  }
  return path
}

function modelRunDir(_context: BrowserClientContext, runDir: string): string {
  return runDir
}

async function readRunResult(runDir: string): Promise<RunResult> {
  try {
    return JSON.parse(await readFile(resolve(runDir, 'result.json'), 'utf8')) as RunResult
  } catch (error) {
    throw new BrowserDataError('invalid_result', 'browser runner did not write a valid result.json', { cause: error })
  }
}

async function ensureRunResult(runDir: string, value: RunResult): Promise<void> {
  try {
    await stat(resolve(runDir, 'result.json'))
  } catch {
    await atomicText(resolve(runDir, 'result.json'), `${JSON.stringify(value, null, 2)}\n`)
  }
}

async function atomicText(path: string, value: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true })
  const temporary = `${path}.${crypto.randomUUID()}.tmp`
  const file = await open(temporary, 'w', 0o600)
  try {
    await file.writeFile(value)
  } finally {
    await file.close()
  }
  await rename(temporary, path)
}

function serializableError(error: unknown): Record<string, unknown> {
  if (error instanceof BrowserDataError) return error.toBrowserError()
  if (error instanceof Error) return { code: 'internal', message: error.message, details: {} }
  return { code: 'internal', message: String(error), details: {} }
}

function remaining(timeoutMs: number, startedAt: string): number {
  return Math.max(1, timeoutMs - (Date.now() - Date.parse(startedAt)))
}

async function abortable<T>(promise: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) throw signal.reason
  return await new Promise<T>((resolve, reject) => {
    const abort = (): void => reject(signal.reason)
    signal.addEventListener('abort', abort, { once: true })
    promise.then(resolve, reject).finally(() => signal.removeEventListener('abort', abort))
  })
}
