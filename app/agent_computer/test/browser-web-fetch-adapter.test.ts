import { afterEach, describe, expect, test } from 'bun:test'
import { mkdir, mkdtemp, readdir, rm } from 'node:fs/promises'
import { createServer, type Server, type Socket } from 'node:net'
import { dirname, join } from 'node:path'
import type { BrowserRequest } from '@ankole/browser/protocol'
import { BrowserRouteMaterializer } from '../src/browser-runtime/materializer'
import { BrowserWebFetchAdapter, type BrowserWebFetchFailureEvent } from '../src/browser-runtime/web-fetch-adapter'

const roots: string[] = []
const servers: Server[] = []
const sockets = new Set<Socket>()

afterEach(async () => {
  for (const socket of sockets) socket.destroy()
  sockets.clear()
  await Promise.all(servers.splice(0).map(server => new Promise<void>(resolve => server.close(() => resolve()))))
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })))
})

async function runtime() {
  const root = await mkdtemp('/tmp/ankole-browser-fetch-')
  roots.push(root)
  const socketPath = join(root, 'browser.sock')
  const materializer = new BrowserRouteMaterializer({
    root: join(root, 'runtime'),
    socketPath,
    runnerPath: '/bin/true',
    localChromiumExecutable: '/bin/true'
  })
  return { root, socketPath, materializer }
}

async function daemon(socketPath: string, respond: (request: BrowserRequest) => unknown) {
  const server = createServer(socket => {
    sockets.add(socket)
    socket.once('close', () => sockets.delete(socket))
    let buffer = ''
    socket.on('data', chunk => {
      buffer += String(chunk)
      const newline = buffer.indexOf('\n')
      if (newline === -1) return
      const request = JSON.parse(buffer.slice(0, newline)) as BrowserRequest
      const body = respond(request)
      if (body === undefined) return
      const response = {
        v: 1,
        id: request.id,
        route: request.route,
        session: request.session,
        ...((body as { ok?: boolean }).ok === false ? {} : { ok: true, data: {}, warnings: [] }),
        ...(body as object)
      }
      socket.end(`${JSON.stringify(response)}\n`)
    })
    socket.on('end', () => socket.destroy())
  })
  servers.push(server)
  await mkdir(dirname(socketPath), { recursive: true })
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject)
    server.listen(socketPath, resolve)
  })
}

function successful(request: BrowserRequest) {
  return request.command.name === 'fetch'
    ? { data: { results: [{ url: 'https://example.com', text: 'rendered' }] } }
    : { data: { purged: true } }
}

const remoteEnv = {
  BROWSER_BACKEND_JSON: JSON.stringify({
    kind: 'remote_cdp',
    endpoint: 'wss://remote-user:endpoint-secret@remote.example:9222',
    headers: { authorization: 'Bearer header-secret' },
    session_identity: 'remote-test'
  })
}

describe('rendered web_fetch browser adapter', () => {
  test('sends final material and a five-minute deadline without writing a material file', async () => {
    const { root, socketPath, materializer } = await runtime()
    const requests: BrowserRequest[] = []
    await daemon(socketPath, request => {
      requests.push(request)
      return successful(request)
    })
    const before = Date.now()
    const result = await new BrowserWebFetchAdapter(materializer).fetch(['https://example.com'], {
      ssrfFilter: true,
      workerEnv: {
        BROWSER_BACKEND_JSON: JSON.stringify({
          kind: 'local_chromium',
          executable: '/bin/true',
          args: ['--final-only']
        })
      }
    })
    const captured = requests[0]!
    expect(result).toMatchObject({ results: [{ text: 'rendered' }] })
    expect(captured.command).toEqual({ name: 'fetch', args: { urls: ['https://example.com'] } })
    expect(captured.route).toBe(captured.material.route_id)
    expect(captured.session).toBe('default')
    expect(captured.deadline_unix_ms - before).toBeGreaterThanOrEqual(299_000)
    expect(captured.deadline_unix_ms - before).toBeLessThanOrEqual(301_000)
    expect(captured.material.backend).toMatchObject({ kind: 'local_chromium', args: ['--final-only'] })
    expect(await readdir(join(root, 'runtime', 'materials')).catch(() => [])).toEqual([])
    expect(await readdir(join(root, 'runtime', 'ephemeral-artifacts'))).toEqual([])
    expect(requests[1]!.command).toEqual({ name: 'lifecycle', args: { verb: 'purge' } })
  })

  test('restores the supervised daemon and retries ephemeral purge after a daemon crash', async () => {
    const { socketPath, materializer } = await runtime()
    let ensureCalls = 0
    let purgeCommand: unknown
    const adapter = new BrowserWebFetchAdapter(materializer, {
      ensureDaemon: async () => {
        ensureCalls += 1
        await daemon(socketPath, request => {
          purgeCommand = request.command
          return successful(request)
        })
      }
    })
    await expect(adapter.fetch(['https://example.com'], { ssrfFilter: true })).rejects.toMatchObject({
      code: 'backend_unavailable',
      retryable: true
    })
    expect(ensureCalls).toBe(1)
    expect(purgeCommand).toEqual({ name: 'lifecycle', args: { verb: 'purge' } })
  })

  test('reports a remote backend failure without endpoint or credential material', async () => {
    const { socketPath, materializer } = await runtime()
    await daemon(socketPath, request =>
      request.command.name === 'fetch'
        ? {
            ok: false,
            error: {
              code: 'backend_unavailable',
              message: 'remote Chromium connection failed',
              retryable: true,
              details: {
                endpoint: 'wss://remote-user:endpoint-secret@remote.example:9222',
                headers: { authorization: 'Bearer header-secret' }
              }
            }
          }
        : successful(request)
    )
    const failures: BrowserWebFetchFailureEvent[] = []
    const adapter = new BrowserWebFetchAdapter(materializer, { onFailure: event => failures.push(event) })
    await expect(
      adapter.fetch(['https://example.com'], { ssrfFilter: true, workerEnv: remoteEnv })
    ).rejects.toMatchObject({ code: 'backend_unavailable' })
    expect(failures).toEqual([
      {
        backendKind: 'remote_cdp',
        stage: 'invoke',
        errorCode: 'backend_unavailable',
        errorMessage: 'remote Chromium connection failed',
        retryable: true
      }
    ])
    expect(JSON.stringify(failures)).not.toContain('endpoint-secret')
    expect(JSON.stringify(failures)).not.toContain('header-secret')
  })

  test('reports a remote page failure with only its safe URL origin', async () => {
    const { socketPath, materializer } = await runtime()
    await daemon(socketPath, request =>
      request.command.name === 'fetch'
        ? {
            data: {
              success: false,
              results: [
                {
                  url: 'https://example.com/private?token=url-secret',
                  error:
                    'page.goto: Timeout 14000ms exceeded at https://example.com/private?token=url-secret\nCall log',
                  error_code: 'timeout',
                  retryable: true
                }
              ]
            }
          }
        : successful(request)
    )
    const failures: BrowserWebFetchFailureEvent[] = []
    await new BrowserWebFetchAdapter(materializer, { onFailure: event => failures.push(event) }).fetch(
      ['https://example.com/private?token=url-secret'],
      { ssrfFilter: true, workerEnv: remoteEnv }
    )
    expect(failures).toEqual([
      {
        backendKind: 'remote_cdp',
        stage: 'url',
        errorCode: 'timeout',
        errorMessage: 'page.goto: Timeout 14000ms exceeded at [redacted endpoint]',
        retryable: true,
        urlIndex: 0,
        urlScheme: 'https',
        urlHost: 'example.com'
      }
    ])
    for (const secret of ['/private', 'url-secret', 'endpoint-secret', 'header-secret']) {
      expect(JSON.stringify(failures)).not.toContain(secret)
    }
  })

  test('cancels a pending fetch immediately, skips failure logging and purges the route', async () => {
    const { socketPath, materializer } = await runtime()
    const commands: string[] = []
    let received!: () => void
    const pending = new Promise<void>(resolve => {
      received = resolve
    })
    await daemon(socketPath, request => {
      commands.push(request.command.name)
      if (request.command.name === 'fetch') {
        received()
        return undefined
      }
      return successful(request)
    })
    const failures: BrowserWebFetchFailureEvent[] = []
    const controller = new AbortController()
    const reason = new Error('cancelled fetch')
    const fetch = new BrowserWebFetchAdapter(materializer, { onFailure: event => failures.push(event) }).fetch(
      ['https://example.com'],
      { ssrfFilter: true },
      controller.signal
    )
    await pending
    await Bun.sleep(50)
    const before = Date.now()
    controller.abort(reason)
    await expect(fetch).rejects.toBe(reason)
    expect(Date.now() - before).toBeLessThan(1_000)
    expect(failures).toEqual([])
    expect(commands).toEqual(['fetch', 'lifecycle'])
  })
})
