import { describe, expect, it } from 'bun:test'
import { loadTestEnvFiles } from '../common/tests/load-test-env'

await loadTestEnvFiles()

const { createWebServer } = await import('./web-server')
const webServer = await createWebServer({ serveStaticAssets: false })

describe('webServer API request guard', () => {
  it('rejects unsafe API requests from a different origin', async () => {
    const response = await webServer.handle(
      new Request('http://localhost/api/session', {
        method: 'DELETE',
        headers: {
          Origin: 'http://evil.example'
        }
      })
    )

    expect(response.status).toBe(403)
    await expect(response.json()).resolves.toEqual({ error: 'invalid origin' })
  })

  it('rejects unsafe API requests with a non-JSON body regardless of method', async () => {
    const response = await webServer.handle(
      new Request('http://localhost/api/session', {
        method: 'DELETE',
        headers: {
          Origin: 'http://localhost',
          'Content-Type': 'text/plain'
        },
        body: 'logout'
      })
    )

    expect(response.status).toBe(415)
    await expect(response.json()).resolves.toEqual({ error: 'expected application/json' })
  })

  it('allows unsafe API requests with no declared body', async () => {
    const response = await webServer.handle(
      new Request('http://localhost/api/session', {
        method: 'DELETE',
        headers: {
          Origin: 'http://localhost'
        }
      })
    )

    expect(response.status).toBe(200)
    await expect(response.json()).resolves.toEqual({ ok: true })
  })
})
