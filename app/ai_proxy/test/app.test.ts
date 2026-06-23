import { mkdtemp } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { describe, expect, test } from 'bun:test'

import { app } from '../src/app'
import { startAiProxyServer } from '../src/server'

describe('ai_proxy', () => {
  test('responds through the Elysia app', async () => {
    const response = await app.fetch(new Request('http://localhost/health'))

    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({
      service: 'ai_proxy',
      status: 'ok'
    })
  })

  test('listens on a unix socket', async () => {
    const socketDir = await mkdtemp(join(tmpdir(), 'ankole-ai-proxy-'))
    const socketPath = join(socketDir, 'server.sock')
    const runtime = await startAiProxyServer({ socketPath })

    try {
      const response = await fetch('http://localhost/health', { unix: socketPath })

      expect(response.status).toBe(200)
      expect(await response.json()).toEqual({
        service: 'ai_proxy',
        status: 'ok'
      })
    } finally {
      await runtime.stop()
    }
  })
})
