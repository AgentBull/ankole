import { readFile } from 'node:fs/promises'
import { createConnection } from 'node:net'
import {
  BrowserMaterialSchema,
  BrowserProtocolVersion,
  BrowserResponseSchema,
  type BrowserCommand,
  type BrowserMaterial,
  type BrowserRequest,
  type BrowserResponse
} from './protocol'
import { BrowserDataError } from './errors'

const MaxResponseBytes = 8 * 1024 * 1024

export type BrowserClientContext = {
  socketPath: string
  route: string
  session: string
  material: BrowserMaterial
  /** Client-visible artifact root; material.artifact_root remains daemon-visible. */
  artifactRoot: string
  timeoutMs: number
}

export async function browserClientContextFromEnv(
  env: Record<string, string | undefined> = process.env
): Promise<BrowserClientContext> {
  const socketPath = requiredEnv(env, 'ANKOLE_BROWSER_SOCKET')
  const route = requiredEnv(env, 'ANKOLE_BROWSER_ROUTE')
  const session = normalizeSession(env.ANKOLE_BROWSER_SESSION ?? 'default')
  const materialPath = requiredEnv(env, 'ANKOLE_BROWSER_MATERIAL')
  const parsed = BrowserMaterialSchema.safeParse(JSON.parse(await readFile(materialPath, 'utf8')))
  if (!parsed.success) {
    throw new BrowserDataError('invalid_material', 'browser material is invalid', {
      details: { issues: parsed.error.issues.map(issue => issue.message) }
    })
  }
  if (parsed.data.route_id !== route) {
    throw new BrowserDataError('invalid_material', 'browser route does not match material route_id')
  }
  return {
    socketPath,
    route,
    session,
    material: parsed.data,
    artifactRoot: env.ANKOLE_BROWSER_ARTIFACT_ROOT?.trim() || parsed.data.artifact_root,
    timeoutMs: positiveInteger(env.ANKOLE_BROWSER_TIMEOUT_MS, 30_000)
  }
}

export async function sendBrowserCommand(
  context: BrowserClientContext,
  command: BrowserCommand,
  options: { session?: string; timeoutMs?: number; signal?: AbortSignal } = {}
): Promise<BrowserResponse> {
  const timeoutMs = options.timeoutMs ?? context.timeoutMs
  const request: BrowserRequest = {
    v: BrowserProtocolVersion,
    id: `req_${crypto.randomUUID()}`,
    route: context.route,
    session: normalizeSession(options.session ?? context.session),
    material: context.material,
    deadline_unix_ms: Date.now() + timeoutMs,
    command
  }
  return await sendBrowserRequest(context.socketPath, request, { timeoutMs, signal: options.signal })
}

export async function sendBrowserRequest(
  socketPath: string,
  request: BrowserRequest,
  options: { timeoutMs: number; signal?: AbortSignal }
): Promise<BrowserResponse> {
  if (options.signal?.aborted) throw options.signal.reason

  return await new Promise<BrowserResponse>((resolve, reject) => {
    const socket = createConnection(socketPath)
    let buffer = Buffer.alloc(0)
    let settled = false
    const finish = (callback: () => void): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      options.signal?.removeEventListener('abort', onAbort)
      socket.destroy()
      callback()
    }
    const onAbort = (): void =>
      finish(() => reject(options.signal?.reason ?? new DOMException('cancelled', 'AbortError')))
    const timer = setTimeout(
      () =>
        finish(() => reject(new BrowserDataError('timeout', 'browser daemon response timed out', { retryable: true }))),
      options.timeoutMs
    )
    options.signal?.addEventListener('abort', onAbort, { once: true })

    socket.once('connect', () => {
      socket.write(`${JSON.stringify(request)}\n`)
    })
    socket.on('data', chunk => {
      buffer = Buffer.concat([buffer, Buffer.from(chunk)])
      if (buffer.length > MaxResponseBytes) {
        finish(() => reject(new BrowserDataError('internal', 'browser daemon response exceeded size limit')))
        return
      }
      const newline = buffer.indexOf(10)
      if (newline === -1) return
      try {
        const response = BrowserResponseSchema.parse(JSON.parse(buffer.subarray(0, newline).toString('utf8')))
        finish(() => resolve(response))
      } catch (error) {
        finish(() => reject(new BrowserDataError('internal', 'browser daemon returned invalid JSON', { cause: error })))
      }
    })
    socket.once('error', error => {
      finish(() =>
        reject(
          new BrowserDataError('backend_unavailable', `browser daemon connection failed: ${error.message}`, {
            retryable: true,
            cause: error
          })
        )
      )
    })
    socket.once('end', () => {
      if (!settled) finish(() => reject(new BrowserDataError('internal', 'browser daemon closed without a response')))
    })
  })
}

function requiredEnv(env: Record<string, string | undefined>, key: string): string {
  const value = env[key]?.trim()
  if (value) return value
  throw new BrowserDataError(
    key === 'ANKOLE_BROWSER_ROUTE' ? 'missing_route' : 'invalid_material',
    `${key} is required`
  )
}

function normalizeSession(value: string): string {
  if (!/^[A-Za-z0-9._-]{1,64}$/.test(value)) {
    throw new BrowserDataError('invalid_command', 'session must match [A-Za-z0-9._-]{1,64}')
  }
  return value
}

function positiveInteger(value: string | undefined, fallback: number): number {
  const parsed = Number(value)
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback
}
