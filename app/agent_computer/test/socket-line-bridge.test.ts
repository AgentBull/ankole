import { expect, it } from 'bun:test'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { requestSocketLineBridge, startSocketLineBridge } from '../src/core/socket-line-bridge'

it('sends a complete multibyte CLI response after the socket write buffer fills', async () => {
  const root = mkdtempSync(join(tmpdir(), 'ank-bridge-'))
  const result = { text: '完整 response 🐂\n'.repeat(150_000) }
  const bridge = startSocketLineBridge({
    socketPath: join(root, 'cli.sock'),
    maxRequestBytes: 1024,
    oversizeError: 'request too large',
    handleLine: async () => ({ ok: true, result })
  })

  try {
    const actual = await requestSocketLineBridge(bridge.socketPath, '{}', 'invalid response')
    expect((actual.text as string).length).toBe(result.text.length)
    expect(actual.text === result.text).toBe(true)
  } finally {
    bridge.close()
    rmSync(root, { recursive: true, force: true })
  }
})
