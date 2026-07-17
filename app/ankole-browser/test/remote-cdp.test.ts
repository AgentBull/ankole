import { afterEach, describe, expect, test } from 'bun:test'
import { createServer, type Server } from 'node:http'
import { mkdtemp, rm, stat } from 'node:fs/promises'
import type { AddressInfo } from 'node:net'
import { join } from 'node:path'
import type { BrowserMaterial } from '../src/protocol'
import { connectRemoteChromium } from '../src/browser/remote-cdp'

const roots: string[] = []
const servers: Server[] = []

afterEach(async () => {
  await Promise.all(servers.splice(0).map(server => new Promise<void>(resolve => server.close(() => resolve()))))
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })))
})

describe('remote session ownership', () => {
  test('cleans up a newly created remote session when CDP attach fails', async () => {
    let cleanupCalls = 0
    const server = createServer((request, response) => {
      response.setHeader('content-type', 'application/json')
      if (request.url === '/create') response.end(JSON.stringify({ endpoint: 'http://127.0.0.1:1' }))
      else if (request.url === '/cleanup') {
        cleanupCalls += 1
        response.end(JSON.stringify({ ok: true }))
      } else {
        response.statusCode = 404
        response.end(JSON.stringify({ error: 'not found' }))
      }
    })
    servers.push(server)
    await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
    const port = (server.address() as AddressInfo).port
    const root = await mkdtemp('/tmp/ankole-browser-remote-')
    roots.push(root)
    const material = remoteMaterial(root, port)

    await expect(connectRemoteChromium(material, 'default')).rejects.toMatchObject({ code: 'backend_unavailable' })

    expect(cleanupCalls).toBe(1)
    await expect(stat(join(root, 'data', 'sessions', 'default', 'remote.json'))).rejects.toMatchObject({
      code: 'ENOENT'
    })
  }, 5_000)
})

function remoteMaterial(root: string, port: number): BrowserMaterial {
  return {
    protocol_version: 1,
    route_id: 'br_1234567890abcdef',
    data_root: join(root, 'data'),
    artifact_root: join(root, 'artifacts'),
    immutable_fingerprint: 'sha256:test',
    material_generation: 0,
    profile: { mode: 'persistent_user_data_dir' },
    backend: {
      kind: 'remote_session_request',
      request: { url: `http://127.0.0.1:${port}/create`, method: 'POST', headers: {} },
      response: { endpoint_json_path: ['endpoint'] },
      connect_headers: {},
      connect_timeout_ms: 250,
      session_identity: 'test-session',
      cleanup_request: { url: `http://127.0.0.1:${port}/cleanup`, method: 'POST', headers: {} }
    },
    navigation: { ssrf_filter: true, allow_file_urls: false },
    idle_ttl_ms: 60_000
  }
}
