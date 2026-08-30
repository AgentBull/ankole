import { describe, expect, it } from 'bun:test'
import { CodexAppServerClient } from '../src/core/codex-runner/runtime/app-server-client'
import { toError } from '../src/common/errors'

describe('Codex app-server client transport', () => {
  it('rejects pending requests immediately when stdin write fails', async () => {
    let writes = 0
    const transport = fakeTransport({
      write: () => {
        writes += 1
        return writes === 1 ? undefined : Promise.reject(new Error('write EPIPE'))
      }
    })
    const client = new CodexAppServerClient(clientOptions(), transport.spawn)
    const alreadyPending = rejectionOf(client.request('thread/start', {}, 10_000))
    const failedWrite = rejectionOf(client.request('turn/start', {}, 10_000))

    expect((await alreadyPending).message).toBe('write EPIPE')
    expect((await failedWrite).message).toBe('write EPIPE')
    await expect(client.request('turn/start', {}, 10_000)).rejects.toThrow('write EPIPE')
    expect(transport.killCount()).toBe(1)
  })

  it('rejects every pending request when close is called and closes idempotently', async () => {
    const transport = fakeTransport()
    const client = new CodexAppServerClient(clientOptions(), transport.spawn)
    const first = rejectionOf(client.request('thread/start', {}, 10_000))
    const second = rejectionOf(client.request('turn/start', {}, 10_000))

    await client.close()
    expect((await first).message).toBe('codex app-server client is closed')
    expect((await second).message).toBe('codex app-server client is closed')
    await client.close()

    expect(transport.killCount()).toBe(1)
  })

  it('lets closeAndWait reap a clean EOF exit before it sends a kill', async () => {
    const transport = fakeTransport()
    const client = new CodexAppServerClient(clientOptions(), transport.spawn)

    const closing = client.closeAndWait()
    await Promise.resolve()
    transport.exit(0)
    await closing

    expect(transport.endCount()).toBe(1)
    expect(transport.killCount()).toBe(0)
  })

  it('reassembles one JSON-RPC response split across arbitrary byte chunks', async () => {
    const transport = fakeTransport()
    const client = new CodexAppServerClient(clientOptions(), transport.spawn)
    const pending = client.request('thread/start', {}, 10_000)
    await Promise.resolve()

    const bytes = new TextEncoder().encode('{"id":1,"result":{"text":"世界"}}\n')
    const splitAt = bytes.indexOf(new TextEncoder().encode('世')[0]!) + 1
    transport.stdout(bytes.slice(0, splitAt))
    transport.stdout(bytes.slice(splitAt))

    expect(await pending).toEqual({ text: '世界' })
    await client.close()
  })

  it('dispatches multiple JSON-RPC responses delivered in one stdout chunk', async () => {
    const transport = fakeTransport()
    const notifications: Array<{ method?: string }> = []
    const client = new CodexAppServerClient(
      { ...clientOptions(), onNotification: notification => notifications.push(notification) },
      transport.spawn
    )
    const first = client.request('thread/start', {}, 10_000)
    const second = client.request('turn/start', {}, 10_000)
    await Promise.resolve()

    transport.stdout(
      '{"id":1,"result":{"thread":"thread-1"}}\n{"method":"item/completed","params":{"id":"item-1"}}\n{"id":2,"result":{"turn":"turn-1"}}\n'
    )

    expect(await first).toEqual({ thread: 'thread-1' })
    expect(await second).toEqual({ turn: 'turn-1' })
    expect(notifications.map(notification => notification.method)).toEqual(['item/completed'])
    await client.close()
  })

  it('continues parsing after a malformed JSON line', async () => {
    const notifications: Array<{ method?: string }> = []
    const transport = fakeTransport()
    const client = new CodexAppServerClient(
      {
        ...clientOptions(),
        onNotification: message => notifications.push(message)
      },
      transport.spawn
    )
    const pending = client.request('thread/start', {}, 10_000)
    await Promise.resolve()

    transport.stdout('{not-json}\n{"id":1,"result":{"thread":"thread-1"}}\n')

    expect(await pending).toEqual({ thread: 'thread-1' })
    expect(notifications.map(message => message.method)).toEqual(['$parse_error'])
    await client.close()
  })

  it('rejects pending requests when the stdout response channel is lost', async () => {
    for (const mode of ['process_exit', 'eof', 'read_error'] as const) {
      const transport = fakeTransport()
      const client = new CodexAppServerClient(clientOptions(), transport.spawn)
      const pending = rejectionOf(client.request('thread/start', {}, 10_000))
      await Promise.resolve()

      if (mode === 'process_exit') transport.exit(9)
      else if (mode === 'eof') transport.closeStdout()
      else transport.errorStdout(new Error('stdout pipe broke'))

      const error = await settlesWithin(pending, 250)
      expect(error).toBeInstanceOf(Error)
      const expectedMessage =
        mode === 'process_exit' ? 'exited with code 9' : mode === 'eof' ? 'stdout closed' : 'stdout pipe broke'
      expect(error.message).toContain(expectedMessage)
      await expect(client.request('turn/start', {}, 10_000)).rejects.toThrow(error.message)
      expect(transport.killCount()).toBe(1)
    }
  })

  it('fails a timed-out thread resume without closing the shared transport', async () => {
    const methods: string[] = []
    const transport = fakeTransport({
      write: chunk => {
        const line = typeof chunk === 'string' ? chunk : new TextDecoder().decode(chunk)
        methods.push(String(JSON.parse(line).method))
      }
    })
    const client = new CodexAppServerClient(clientOptions(), transport.spawn)
    const resume = rejectionOf(client.request('thread/resume', {}, 10))
    const sibling = client.request('thread/loaded/list', {}, 10_000)

    await until(() => methods.includes('ankole/health_probe'))
    transport.stdout('{"id":3,"error":{"code":-32600,"message":"Invalid request"}}\n')
    expect((await settlesWithin(resume, 250)).message).toBe('codex app-server request timed out: thread/resume')
    expect(transport.killCount()).toBe(0)
    expect(methods).toEqual(['thread/resume', 'thread/loaded/list', 'ankole/health_probe'])

    transport.stdout('{"id":2,"result":{"data":[]}}\n')
    expect(await settlesWithin(sibling, 250)).toEqual({ data: [] })
    await client.close()
  })

  it('fails the transport instead of buffering an unbounded line', async () => {
    const transport = fakeTransport()
    const client = new CodexAppServerClient(clientOptions(), transport.spawn)
    const pending = rejectionOf(client.request('thread/start', {}, 10_000))

    // 64 MiB of a line that never ends. Buffering it would spend the shared
    // Worker's memory on one Codex runtime; the bound turns it into an ordinary
    // transport failure that ends this runtime alone.
    const chunk = 'x'.repeat(1024 * 1024)
    for (let sent = 0; sent <= 64; sent++) transport.stdout(chunk)

    expect((await settlesWithin(pending, 5_000)).message).toContain('without a newline')
    expect(transport.killCount()).toBe(1)
  })
})

function clientOptions() {
  return {
    cwd: '/tmp',
    env: {}
  }
}

function fakeTransport(overrides: { write?: (chunk: string | Uint8Array) => unknown } = {}) {
  let kills = 0
  let ends = 0
  let resolveExited: ((code: number | null) => void) | undefined
  let stdoutController: ReadableStreamDefaultController<Uint8Array> | undefined
  const stdout = new ReadableStream<Uint8Array>({
    start: controller => {
      stdoutController = controller
    }
  })
  const stderr = new ReadableStream<Uint8Array>()
  const proc = {
    stdin: {
      write: overrides.write ?? (() => undefined),
      end: () => {
        ends += 1
      }
    },
    stdout,
    stderr,
    exited: new Promise<number | null>(resolve => {
      resolveExited = resolve
    }),
    kill: () => {
      kills += 1
    }
  }

  return {
    spawn: () => proc,
    killCount: () => kills,
    endCount: () => ends,
    stdout: (chunk: string | Uint8Array) =>
      stdoutController?.enqueue(typeof chunk === 'string' ? new TextEncoder().encode(chunk) : chunk),
    closeStdout: () => stdoutController?.close(),
    errorStdout: (error: Error) => stdoutController?.error(error),
    exit: (code: number | null) => resolveExited?.(code)
  }
}

async function settlesWithin<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
  return Promise.race([
    promise,
    new Promise<never>((_resolve, reject) =>
      setTimeout(() => reject(new Error(`promise did not settle within ${timeoutMs}ms`)), timeoutMs)
    )
  ])
}

async function until(predicate: () => boolean, timeoutMs = 250): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error('condition did not become true')
    await Bun.sleep(1)
  }
}

async function rejectionOf(promise: Promise<unknown>): Promise<Error> {
  try {
    await promise
    throw new Error('expected promise to reject')
  } catch (error) {
    return toError(error)
  }
}
