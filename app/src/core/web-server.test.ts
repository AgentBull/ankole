import { describe, expect, it } from 'bun:test'
import { mkdir, rm, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { loadTestEnvFiles } from '../common/tests/load-test-env'

await loadTestEnvFiles()

const { createWebServer } = await import('./web-server')
const webServer = await createWebServer({ serveStaticAssets: false })

describe('webServer API request guard', () => {
  it('allows unsafe API requests from a different origin', async () => {
    const response = await webServer.handle(
      new Request('http://localhost/api/session', {
        method: 'DELETE',
        headers: {
          Origin: 'http://evil.example'
        }
      })
    )

    expect(response.status).toBe(200)
    await expect(response.json()).resolves.toEqual({ ok: true })
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

describe('production static assets', () => {
  it('serves assets even when the build emits more files than @elysiajs/static staticLimit', async () => {
    const originalNodeEnv = Bun.env.NODE_ENV
    const assetDir = path.resolve(import.meta.dir, '../../public/assets/__static-limit-test')

    try {
      await rm(assetDir, { recursive: true, force: true })
      await mkdir(assetDir, { recursive: true })
      await Promise.all(
        Array.from({ length: 1030 }, (_, index) => writeFile(path.join(assetDir, `asset-${index}.txt`), 'ok'))
      )
      Bun.env.NODE_ENV = 'production'

      const server = await createWebServer()
      const response = await server.handle(new Request('http://localhost/assets/__static-limit-test/asset-1029.txt'))

      expect(response.status).toBe(200)
      await expect(response.text()).resolves.toBe('ok')
    } finally {
      if (originalNodeEnv === undefined) delete Bun.env.NODE_ENV
      else Bun.env.NODE_ENV = originalNodeEnv
      await rm(assetDir, { recursive: true, force: true })
    }
  })
})
