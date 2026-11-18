import { afterEach, expect, spyOn, test } from 'bun:test'
import { HIDDEN_TAB_CLAIM_DELAY, serveAgentUIRequests, type AgentUIRequest } from './agent-ui-bridge'
import { RealtimeRequestError } from './realtime'

const settle = () => new Promise(resolve => setTimeout(resolve, 0))
const originalDocument = Object.getOwnPropertyDescriptor(globalThis, 'document')

afterEach(() => {
  if (originalDocument) Object.defineProperty(globalThis, 'document', originalDocument)
  else Reflect.deleteProperty(globalThis, 'document')
})

function tab(visibilityState: 'visible' | 'hidden', claim: (id: string) => Promise<unknown> = async () => ({})) {
  Object.defineProperty(globalThis, 'document', { configurable: true, value: { visibilityState } })
  const pushes: [string, Record<string, unknown>][] = []
  const listeners = new Map<string, (payload: unknown) => void>()
  const running: (string | undefined)[] = []
  const bridge = {
    snapshot: () => [{ ref: 'c1', component: 'button', label: 'Save', actions: ['press'] }],
    act: async (input: { steps: unknown[] }) => ({ ok: true, steps: input.steps, values: {}, appeared: [] }),
    query: async (input: { text?: string }) => {
      if (input.text === 'boom') throw new Error('The page is gone')
      return [{ ref: 'c2', component: 'select', label: input.text, actions: [] }]
    }
  }
  const stop = serveAgentUIRequests(
    {
      push: async <T>(event: string, payload: object) => {
        pushes.push([event, payload as Record<string, unknown>])
        return (event === 'claim' ? claim((payload as { id: string }).id) : {}) as Promise<T>
      },
      on: (event, callback) => {
        listeners.set(event, callback)
        return () => listeners.delete(event)
      }
    },
    bridge as never,
    request => running.push(request?.id)
  )
  const request = (id: string, operation: AgentUIRequest['operation'], args: Record<string, unknown> = {}) =>
    listeners.get('request')?.({ id, operation, arguments: args, agent: { uid: 'agent-1', name: 'Ada' } })
  return { pushes, running, request, stop, listeners }
}

test('a visible tab claims at once and routes each operation to the bridge', async () => {
  const { pushes, running, request } = tab('visible')
  request('r1', 'snapshot')
  request('r2', 'act', { steps: [{ ref: 'Save', action: 'press' }] })
  request('r3', 'query', { text: 'Region' })
  await settle()
  await settle()

  expect(pushes).toEqual([
    ['claim', { id: 'r1' }],
    ['claim', { id: 'r2' }],
    ['claim', { id: 'r3' }],
    ['result', { id: 'r1', result: [{ ref: 'c1', component: 'button', label: 'Save', actions: ['press'] }] }],
    ['result', { id: 'r2', result: { ok: true, steps: [{ ref: 'Save', action: 'press' }], values: {}, appeared: [] } }],
    ['result', { id: 'r3', result: [{ ref: 'c2', component: 'select', label: 'Region', actions: [] }] }]
  ])
  expect(running).toEqual(['r1', undefined, 'r2', undefined, 'r3', undefined])
})

test('a thrown bridge error and an unknown operation come back as errors', async () => {
  const { pushes, request } = tab('visible')
  request('r1', 'query', { text: 'boom' })
  request('r2', 'navigate' as never)
  await settle()
  await settle()

  expect(pushes.filter(([event]) => event === 'result')).toEqual([
    ['result', { id: 'r1', error: 'The page is gone' }],
    ['result', { id: 'r2', error: 'Unknown agent UI operation: navigate' }]
  ])
})

test('a tab that loses the claim leaves the request and ignores the same request pushed again', async () => {
  const { pushes, request } = tab('visible', async () => {
    throw new RealtimeRequestError({ reason: 'taken' })
  })
  request('r1', 'snapshot')
  request('r1', 'snapshot')
  await settle()

  expect(pushes).toEqual([['claim', { id: 'r1' }]])
})

test('a hidden tab waits before it claims, and stops waiting when it disconnects', async () => {
  const timers: [() => void, number | undefined][] = []
  const setTimeoutSpy = spyOn(globalThis, 'setTimeout').mockImplementation(((callback: () => void, delay?: number) => {
    timers.push([callback, delay])
    return timers.length as never
  }) as never)
  const clearTimeoutSpy = spyOn(globalThis, 'clearTimeout').mockImplementation(() => {})
  try {
    const { pushes, request, stop, listeners } = tab('hidden')
    request('r1', 'snapshot')
    request('r2', 'snapshot')
    expect(pushes).toEqual([])
    expect(timers.map(([, delay]) => delay)).toEqual([HIDDEN_TAB_CLAIM_DELAY, HIDDEN_TAB_CLAIM_DELAY])

    timers[0]![0]()
    expect(pushes).toEqual([['claim', { id: 'r1' }]])

    stop()
    expect(clearTimeoutSpy).toHaveBeenCalledWith(2)
    expect(listeners.has('request')).toBe(false)
  } finally {
    setTimeoutSpy.mockRestore()
    clearTimeoutSpy.mockRestore()
  }
})
