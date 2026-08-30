import { mkdir, open, readFile, rename, rm } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { chromium, type Browser } from 'playwright-core'
import type { BrowserMaterial, RemoteSessionRequestBackendSchema } from '../protocol'
import { BrowserDataError, isFileNotFound } from '../errors'
import type { z } from 'zod'

type RemoteSessionRequestBackend = z.infer<typeof RemoteSessionRequestBackendSchema>

type PersistedRemote = {
  endpoint: string
  session_identity: string
  created_at: string
}

export type RemoteChromiumHandle = {
  browser: Browser
  endpoint: string
  cleanup: () => Promise<void>
}

export async function connectRemoteChromium(material: BrowserMaterial, session: string): Promise<RemoteChromiumHandle> {
  const backend = material.backend
  if (backend.kind === 'local_chromium') throw new Error('remote backend material required')
  const remotePath = join(material.data_root, 'sessions', session, 'remote.json')
  let endpoint: string
  let headers: Record<string, string>
  let cleanup = async (): Promise<void> => undefined
  let created = false

  if (backend.kind === 'remote_cdp') {
    endpoint = backend.endpoint
    headers = backend.headers
  } else {
    const resolved = await resolveOrCreateRemoteSession(remotePath, backend)
    endpoint = resolved.endpoint
    created = resolved.created
    headers = backend.connect_headers
    cleanup = async () => cleanupPersistedRemoteSession(remotePath, backend)
  }

  try {
    const browser = await chromium.connectOverCDP(endpoint, {
      headers,
      timeout: backend.connect_timeout_ms
    })
    return { browser, endpoint, cleanup }
  } catch (error) {
    if (created) await cleanup().catch(() => undefined)
    throw new BrowserDataError('backend_unavailable', 'remote Chromium connection failed', {
      retryable: true,
      details: { endpoint: redactEndpoint(endpoint) },
      cause: error
    })
  }
}

export async function purgeDetachedRemoteChromium(material: BrowserMaterial, session: string): Promise<void> {
  if (material.backend.kind !== 'remote_session_request') return
  const remotePath = join(material.data_root, 'sessions', session, 'remote.json')
  await cleanupPersistedRemoteSession(remotePath, material.backend)
}

async function resolveOrCreateRemoteSession(
  path: string,
  backend: RemoteSessionRequestBackend
): Promise<{ endpoint: string; created: boolean }> {
  try {
    const persisted = JSON.parse(await readFile(path, 'utf8')) as PersistedRemote
    if (persisted.session_identity === backend.session_identity && persisted.endpoint) {
      return { endpoint: persisted.endpoint, created: false }
    }
  } catch (error) {
    if (!isFileNotFound(error)) throw error
  }

  const response = await executeRequest(backend.request, backend.connect_timeout_ms)
  const endpoint = jsonPath(response, backend.response.endpoint_json_path)
  if (typeof endpoint !== 'string' || !endpoint) {
    throw new BrowserDataError('backend_unavailable', 'remote session response did not contain a CDP endpoint')
  }
  try {
    await atomicJSON(path, {
      endpoint,
      session_identity: backend.session_identity,
      created_at: new Date().toISOString()
    } satisfies PersistedRemote)
  } catch (error) {
    if (backend.cleanup_request) {
      await executeRequest(backend.cleanup_request, backend.connect_timeout_ms).catch(() => undefined)
    }
    throw error
  }
  return { endpoint, created: true }
}

async function cleanupPersistedRemoteSession(path: string, backend: RemoteSessionRequestBackend): Promise<void> {
  let persisted: PersistedRemote
  try {
    persisted = JSON.parse(await readFile(path, 'utf8')) as PersistedRemote
  } catch (error) {
    if (isFileNotFound(error)) return
    throw error
  }
  if (persisted.session_identity !== backend.session_identity || !persisted.endpoint) return
  if (backend.cleanup_request) await executeRequest(backend.cleanup_request, backend.connect_timeout_ms)
  await rm(path, { force: true })
}

async function executeRequest(request: RemoteSessionRequestBackend['request'], timeoutMs: number): Promise<unknown> {
  const response = await fetch(request.url, {
    method: request.method,
    headers: { 'content-type': 'application/json', ...request.headers },
    ...(request.body === undefined ? {} : { body: JSON.stringify(request.body) }),
    signal: AbortSignal.timeout(timeoutMs)
  })
  if (!response.ok) {
    throw new BrowserDataError('backend_unavailable', `remote session request failed with HTTP ${response.status}`, {
      retryable: response.status >= 500
    })
  }
  const contentType = response.headers.get('content-type') ?? ''
  return contentType.includes('json') ? await response.json() : await response.text()
}

function jsonPath(value: unknown, path: string[]): unknown {
  let current = value
  for (const key of path) {
    if (!current || typeof current !== 'object' || Array.isArray(current)) return undefined
    current = (current as Record<string, unknown>)[key]
  }
  return current
}

function redactEndpoint(endpoint: string): string {
  try {
    const url = new URL(endpoint)
    return `${url.protocol}//${url.host}/…`
  } catch {
    return '[redacted]'
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
