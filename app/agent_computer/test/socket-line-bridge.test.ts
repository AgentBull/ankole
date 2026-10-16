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

it('rejects oversized requests before dispatch without consuming admission slots', async () => {
  const root = mkdtempSync(join(tmpdir(), 'ank-bridge-'))
  let handled = 0
  const bridge = startSocketLineBridge({
    socketPath: join(root, 'cli.sock'),
    maxRequestBytes: 8,
    oversizeError: 'request too large',
    handleLine: async () => {
      handled += 1
      return { ok: true, result: { accepted: true } }
    }
  })
  try {
    for (let index = 0; index < 70; index++) {
      await expect(requestSocketLineBridge(bridge.socketPath, 'xxxxxxxx', 'invalid response')).rejects.toThrow(
        'request too large'
      )
    }
    expect(handled).toBe(0)
    expect(await requestSocketLineBridge(bridge.socketPath, '{}', 'invalid response')).toEqual({ accepted: true })
    expect(handled).toBe(1)
  } finally {
    bridge.close()
    rmSync(root, { recursive: true, force: true })
  }
})

it('expires a trickled request but leaves an accepted slow operation running', async () => {
  const root = mkdtempSync(join(tmpdir(), 'ank-bridge-'))
  const operation = Promise.withResolvers<void>()
  let handled = 0
  const bridge = startSocketLineBridge({
    socketPath: join(root, 'cli.sock'),
    maxRequestBytes: 1024,
    oversizeError: 'request too large',
    handleLine: async () => {
      handled += 1
      await operation.promise
      return { ok: true, result: { completed: true } }
    }
  })
  const partial = await connectSocket(bridge.socketPath)
  const accepted = await connectSocket(bridge.socketPath, '{}\n')
  let acceptedClosed = false
  void accepted.closed.then(() => {
    acceptedClosed = true
  })
  const trickle = setInterval(() => partial.socket.write(' '), 100)
  try {
    await partial.closed
    expect(JSON.parse(partial.text())).toEqual({
      ok: false,
      error: 'CLI bridge request read timed out; request was not accepted'
    })
    expect(handled).toBe(1)
    expect(acceptedClosed).toBe(false)
    operation.resolve()
    await accepted.closed
    expect(JSON.parse(accepted.text())).toEqual({ ok: true, result: { completed: true } })
  } finally {
    clearInterval(trickle)
    bridge.close()
    operation.resolve()
    await Promise.all([partial.closed, accepted.closed])
    rmSync(root, { recursive: true, force: true })
  }
}, 20_000)

it('keeps 64 shared slots until disconnected handlers settle across bridge recreation', async () => {
  const root = mkdtempSync(join(tmpdir(), 'ank-bridge-'))
  const held = new Map<string, () => void>()
  const serialized: string[] = []
  let settled = 0
  const start = (name: string) =>
    startSocketLineBridge({
      socketPath: join(root, `${name}.sock`),
      maxRequestBytes: 1024,
      oversizeError: 'request too large',
      handleLine: async line => {
        const id = String(JSON.parse(line).id)
        await new Promise<void>(resolve => held.set(id, resolve))
        settled += 1
        return {
          ok: true,
          result: {
            get id() {
              serialized.push(id)
              return id
            }
          }
        }
      }
    })
  const first = start('first')
  const second = start('second')
  const bridges = [first, second]
  const clients: Awaited<ReturnType<typeof connectSocket>>[] = []
  try {
    for (let index = 0; index < 64; index++) {
      const bridge = index < 32 ? first : second
      clients.push(await connectSocket(bridge.socketPath, `${JSON.stringify({ id: String(index) })}\n`))
    }
    await until(() => held.size === 64)
    clients[0]!.socket.terminate()
    first.close()
    await Promise.all(clients.slice(0, 32).map(client => client.closed))
    const replacement = start('replacement')
    bridges.push(replacement)
    for (let index = 0; index < 3; index++) {
      await expect(requestSocketLineBridge(replacement.socketPath, '{}', 'invalid response')).rejects.toThrow(
        'busy; request was not accepted'
      )
    }
    expect(held.size).toBe(64)

    held.get('0')!()
    await until(() => settled === 1)
    clients.push(await connectSocket(replacement.socketPath, '{"id":"replacement"}\n'))
    await until(() => held.has('replacement'))
    await expect(requestSocketLineBridge(replacement.socketPath, '{}', 'invalid response')).rejects.toThrow('busy')
    expect(serialized).toEqual([])
  } finally {
    for (const bridge of bridges) bridge.close()
    await Promise.all(clients.map(client => client.closed))
    for (const resolve of held.values()) resolve()
    await until(() => settled === held.size)
    expect(serialized).toEqual([])
    rmSync(root, { recursive: true, force: true })
  }
})

async function connectSocket(path: string, initial?: string) {
  const closed = Promise.withResolvers<void>()
  const chunks: Buffer[] = []
  const socket = await Bun.connect({
    unix: path,
    socket: {
      open(socket) {
        if (initial) socket.write(initial)
      },
      data(_socket, data) {
        chunks.push(Buffer.from(data))
      },
      close() {
        closed.resolve()
      },
      error(socket) {
        socket.terminate()
      }
    }
  })
  return { socket, closed: closed.promise, text: () => Buffer.concat(chunks).toString('utf8') }
}

async function until(predicate: () => boolean): Promise<void> {
  const deadline = Date.now() + 2_000
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error('bridge operation did not settle')
    await Bun.sleep(1)
  }
}
