import { afterEach, beforeEach, describe, expect, spyOn, test } from 'bun:test'
import { Channel, Socket, type Push, type PushStatus } from 'phoenix'
import { client } from './api/generated/client.gen'
import { PodRealtime, RealtimeRequestError, type TopicConnection } from './realtime'

function controlledPush() {
  const callbacks = new Map<PushStatus, ((response: unknown) => void)[]>()
  const push: Push = {
    send() {},
    resend() {},
    receive(status, callback) {
      callbacks.set(status, [...(callbacks.get(status) ?? []), callback])
      return push
    }
  }
  return {
    push,
    reply(status: PushStatus, response: unknown = {}) {
      for (const callback of callbacks.get(status) ?? []) callback(response)
    }
  }
}

describe('realtime connection ownership', () => {
  const originalFetch = globalThis.fetch
  const originalDocument = Object.getOwnPropertyDescriptor(globalThis, 'document')
  let realtime: PodRealtime
  let originalConfig: ReturnType<typeof client.getConfig>
  let joining: ReturnType<typeof controlledPush>
  let request: ReturnType<typeof controlledPush>
  let connect: ReturnType<typeof spyOn<Socket, 'connect'>>
  let join: ReturnType<typeof spyOn<Channel, 'join'>>
  let push: ReturnType<typeof spyOn<Channel, 'push'>>

  beforeEach(() => {
    originalConfig = client.getConfig()
    Object.defineProperty(globalThis, 'document', {
      configurable: true,
      value: { querySelector: () => ({ content: 'token' }), removeEventListener() {} }
    })
    client.setConfig({ baseUrl: 'https://ankole.test' })
    globalThis.fetch = (async (_request: Request) =>
      Response.json({ token: 'socket-token', principal: { uid: 'human' } })) as typeof fetch
    connect = spyOn(Socket.prototype, 'connect').mockImplementation(() => {})
    join = spyOn(Channel.prototype, 'join').mockImplementation(() => {
      joining = controlledPush()
      return joining.push
    })
    push = spyOn(Channel.prototype, 'push').mockImplementation(() => {
      request = controlledPush()
      return request.push
    })
    realtime = new PodRealtime()
  })

  afterEach(() => {
    realtime.dispose()
    client.setConfig(originalConfig)
    connect.mockRestore()
    join.mockRestore()
    push.mockRestore()
    globalThis.fetch = originalFetch
    if (originalDocument) Object.defineProperty(globalThis, 'document', originalDocument)
    else Reflect.deleteProperty(globalThis, 'document')
  })

  test('visibility reconciliation delivers the file object identity from the server', async () => {
    const events = new EventTarget()
    Object.defineProperty(globalThis, 'document', {
      configurable: true,
      value: {
        visibilityState: 'visible',
        querySelector: () => ({ content: 'token' }),
        addEventListener: events.addEventListener.bind(events),
        removeEventListener: events.removeEventListener.bind(events)
      }
    })
    globalThis.fetch = (async (_request: Request) =>
      Response.json({
        pages: [{ id: 'file', revision: 0, object_id: 'runtime-object' }],
        tables: []
      })) as typeof fetch
    const changed = Promise.withResolvers<{ revision: number | undefined; objectID?: string | null }>()
    const stop = realtime.watchVersion('pages', 'file', (revision, objectID) => changed.resolve({ revision, objectID }))
    events.dispatchEvent(new Event('visibilitychange'))
    expect(await changed.promise).toEqual({ revision: 0, objectID: 'runtime-object' })
    stop()
  })

  test.each(['error', 'timeout'] as const)('a %s joining a topic publishes disconnected', async status => {
    const handle = await realtime.join('page:document')
    const states: TopicConnection[] = []
    handle.on('connection', ({ status }) => states.push(status))
    joining.reply(status, { reason: 'forbidden' })
    await expect(handle.ready).rejects.toBeInstanceOf(Error)
    expect(states).toEqual(['connecting', 'disconnected'])
    handle.close()
  })

  test.each(['error', 'timeout'] as const)(
    'a request %s and successful retry do not change a joined connection',
    async status => {
      const handle = await realtime.join('page:document')
      const states: TopicConnection[] = []
      handle.on('connection', ({ status }) => states.push(status))
      joining.reply('ok')
      await handle.ready
      const failed = handle.push('sync', { revision: 0 })
      await Promise.resolve()
      request.reply(status, { reason: 'temporary_failure' })
      await expect(failed).rejects.toBeInstanceOf(status === 'error' ? RealtimeRequestError : Error)
      const retried = handle.push('sync', { revision: 0 })
      await Promise.resolve()
      request.reply('ok', { revision: 0, changes: [] })
      await expect(retried).resolves.toEqual({ revision: 0, changes: [] })
      expect(states).toEqual(['connecting', 'connected'])
      handle.close()
    }
  )

  test('closing one handle disconnects only its observers while another owner keeps the topic', async () => {
    const first = await realtime.join('page:document')
    const second = await realtime.join('page:document')
    const firstStates: TopicConnection[] = [],
      secondStates: TopicConnection[] = []
    first.on('connection', ({ status }) => firstStates.push(status))
    second.on('connection', ({ status }) => secondStates.push(status))
    joining.reply('ok')
    await first.ready
    first.close()
    first.close()
    expect(firstStates).toEqual(['connecting', 'connected', 'disconnected'])
    expect(secondStates).toEqual(['connecting', 'connected'])
    const remaining = second.push('sync', { revision: 0 })
    await Promise.resolve()
    request.reply('ok', { revision: 0, changes: [] })
    await expect(remaining).resolves.toEqual({ revision: 0, changes: [] })
    second.close()
    expect(secondStates.at(-1)).toBe('disconnected')
  })
})
