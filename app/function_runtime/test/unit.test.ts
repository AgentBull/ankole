import { describe, expect, test } from 'bun:test'
import { parse } from 'acorn'
import { runInNewContext } from 'node:vm'
import { buildAppletWorkerBootstrap } from '../main/applet-bootstrap.ts'
import { CodeCache, appletCodeDigest, appletBindingsDigest, type AppletBindings } from '../main/code-cache.ts'
import { InvocationCapacity } from '../main/capacity.ts'
import { matchRoute, validateRoutes } from '../main/routes.ts'

describe('Applet routes', () => {
  test('literal paths win over parameters and parameters decode once', () => {
    const routes = validateRoutes({ 'GET /orders/:id': () => {}, 'GET /orders/new': () => {} })
    expect(matchRoute(routes, 'GET', '/orders/new').route?.key).toBe('GET /orders/new')
    expect(matchRoute(routes, 'GET', '/orders/a%2Fb').params).toEqual({ id: 'a/b' })
    expect(matchRoute(routes, 'POST', '/orders/new').status).toBe(405)
    expect(matchRoute(routes, 'GET', '/orders/%').status).toBe(400)
  })
  test('conflicting route patterns are rejected', () => {
    expect(() => validateRoutes({ 'GET /:a': () => {}, 'GET /:b': () => {} })).toThrow('conflicting')
  })
})

test('code identity follows resolved table mappings independently of declaration ordering', async () => {
  const bindings: AppletBindings = {
    orders: {
      tableId: 'table-b',
      fields: { status: 'status-b', amount: 'amount-b' },
      status: 'ready',
      missing: [],
      required: true,
      description: null
    }
  }
  const reordered = { orders: { ...bindings.orders!, fields: { amount: 'amount-b', status: 'status-b' } } }
  expect(await appletBindingsDigest(bindings)).toBe(await appletBindingsDigest(reordered))
  const source = 'export default {}'
  expect(await appletCodeDigest({ source, env: { a: '1', b: '2' }, bindings })).toBe(
    await appletCodeDigest({ source, env: { b: '2', a: '1' }, bindings: reordered })
  )
  expect(await appletCodeDigest({ source, env: {}, bindings })).not.toBe(
    await appletCodeDigest({ source, env: {}, bindings: { orders: { ...bindings.orders!, tableId: 'table-c' } } })
  )
  const bootstrap = buildAppletWorkerBootstrap(source, false, bindings)
  expect(() => parse(bootstrap, { ecmaVersion: 'latest', sourceType: 'module' })).not.toThrow()
  expect(bootstrap).toContain('table-b')
})

test('code cache evicts least recently used entries within its byte budget', () => {
  const cache = new CodeCache(65)
  cache.put('a', { source: 'a', env: {} })
  cache.put('b', { source: 'b', env: {} })
  cache.get('a')
  cache.put('c', { source: 'c', env: {} })
  expect(cache.get('a')?.source).toBe('a')
  expect(cache.get('b')).toBeUndefined()
  expect(cache.get('c')?.source).toBe('c')
})

test('the configured concurrency ceiling applies across foreground and background work', () => {
  const capacity = new InvocationCapacity(24, 6, 1536, 2)
  const route = capacity.acquire('route', 128)!
  const action = capacity.acquire('action', 192)!
  expect(capacity.acquire('route', 1)).toBeNull()
  expect(capacity.acquire('action', 1)).toBeNull()
  action()
  expect(capacity.acquire('route', 128)).not.toBeNull()
  route()
})

test('foreground reservations count toward their headroom without wasting the shared heap budget', () => {
  const capacity = new InvocationCapacity()
  const routes = Array.from({ length: 4 }, () => capacity.acquire('route', 128))
  const actions = Array.from({ length: 5 }, () => capacity.acquire('action', 192))
  expect([...routes, ...actions].every(Boolean)).toBe(true)
  expect(capacity.usedHeapMb).toBe(1472)
  expect(capacity.acquire('action', 192)).toBeNull()
  routes.forEach(release => release!())
  const sixth = capacity.acquire('action', 192)
  expect(sixth).not.toBeNull()
  expect(capacity.acquire('action', 1)).toBeNull()
  expect(capacity.acquire('route', 128)).not.toBeNull()
  sixth!()
  sixth!()
  actions.forEach(release => release!())
  expect(capacity.usedHeapMb).toBe(128)
})

test('PTC executions cap at Math.max(1, maxConcurrent - 2) so interactive Applets retain concurrency headroom', () => {
  for (const maxConcurrent of [10, 4, 2, 1]) {
    const capacity = new InvocationCapacity(maxConcurrent, 6, 8192, maxConcurrent)
    const expectedPtcCap = Math.max(1, maxConcurrent - 2)
    const ptcLeases: Array<() => void> = []
    for (let i = 0; i < maxConcurrent + 2; i++) {
      const lease = capacity.acquire('ptc', 64)
      if (lease) ptcLeases.push(lease)
    }
    expect(ptcLeases).toHaveLength(expectedPtcCap)

    // Interactive Applet routes can still acquire all remaining slots up to `maxConcurrent`!
    const remainingSlots = maxConcurrent - expectedPtcCap
    const routeLeases: Array<() => void> = []
    for (let i = 0; i < remainingSlots; i++) {
      const lease = capacity.acquire('route', 64)
      expect(lease).not.toBeNull()
      routeLeases.push(lease!)
    }
    expect(capacity.acquire('route', 64)).toBeNull()

    ptcLeases.forEach(release => release())
    routeLeases.forEach(release => release())

    // With no PTC active, interactive Applet invocations can use ALL `maxConcurrent` slots.
    const fullRoutes = Array.from({ length: maxConcurrent }, () => capacity.acquire('route', 64))
    expect(fullRoutes.every(Boolean)).toBe(true)
    expect(capacity.acquire('route', 64)).toBeNull()
    fullRoutes.forEach(release => release!())
  }
})

test('serialized applet bootstrap embeds AnkoleRuntime.idempotent cleanly and bridges durable idempotency capabilities', () => {
  const bootstrapSource = buildAppletWorkerBootstrap(
    `export default { 'POST /pay': async ({ body }) => AnkoleRuntime.idempotent(body.key, () => ({ charged: true })) }`
  )
  expect(() => parse(bootstrapSource, { ecmaVersion: 'latest', sourceType: 'module' })).not.toThrow()
  expect(bootstrapSource).toContain('createIdempotencyExecutor')
  expect(bootstrapSource).toContain('idempotency.claim')
  expect(bootstrapSource).toContain('claim_id')
  expect(bootstrapSource).toContain('idempotency.complete')
  expect(bootstrapSource).toContain('idempotency.release')
  expect(bootstrapSource).toContain('reserved_state_scope')
})

test('cancelling during warm-worker eviction prevents a late worker creation', async () => {
  const retiring = Promise.withResolvers<void>()
  const retired = Promise.withResolvers<void>()
  let creations = 0
  const host = await runtimeHost(async () => {
    creations++
    return {
      fetch: async () => new Response(),
      retire: async () => {
        retiring.resolve()
        await retired.promise
      }
    }
  })
  const first = await host.reserve('first', 'warm-page')
  expect((await host.request(first, true)).status).toBe(200)
  await host.request('/v1/applet/invocations/first', false, 'DELETE')
  const next = await host.reserve('next', 'another-page')
  host.advance(21_000)
  const opening = host.request(next, true)
  await retiring.promise
  await host.request('/v1/applet/invocations/next?aborted=1', false, 'DELETE')
  retired.resolve()
  expect((await opening).status).toBe(504)
  expect(creations).toBe(1)
  await host.reserve('replacement', 'another-page')
})

test('cancelling during worker creation retires the late isolate and releases capacity', async () => {
  const creating = Promise.withResolvers<void>()
  const created = Promise.withResolvers<EdgeRuntime.UserWorker>()
  let retirements = 0
  const host = await runtimeHost(async () => {
    creating.resolve()
    return created.promise
  })
  const next = await host.reserve('next', 'page')
  const opening = host.request(next, true)
  await creating.promise
  const cancellation = host.request('/v1/applet/invocations/next?aborted=1', false, 'DELETE')
  created.resolve({
    fetch: async () => new Response(),
    retire: async () => {
      retirements++
    }
  })
  expect((await opening).status).toBe(504)
  expect((await cancellation).status).toBe(204)
  expect(retirements).toBe(1)
  // Upgrade arriving after DELETE must not revive the deleted invocation lease.
  expect((await host.request(next, true)).status).toBe(404)
  await host.reserve('replacement', 'page')
})

// Isolate the host entrypoint with a controllable native-worker boundary; no process globals are replaced.
async function runtimeHost(create: () => Promise<EdgeRuntime.UserWorker>) {
  const built = await Bun.build({
    entrypoints: [new URL('../main/index.ts', import.meta.url).pathname],
    target: 'browser',
    format: 'iife',
    external: ['mcporter']
  })
  if (!built.success) throw new Error(String(built.logs))
  let handler!: (request: Request) => Promise<Response>
  let now = Date.now()
  class Clock extends Date {
    static now() {
      return now
    }
  }
  class Socket extends EventTarget {
    constructor() {
      super()
      queueMicrotask(() => this.dispatchEvent(new Event('open')))
    }
    close() {}
  }
  runInNewContext(await built.outputs[0].text(), {
    Request,
    Response,
    Headers,
    URL,
    TextEncoder,
    crypto,
    console,
    Date: Clock,
    WebSocket: Socket,
    setInterval: () => 0,
    setTimeout: () => 0,
    clearTimeout: () => {},
    addEventListener: () => {},
    require: () => ({
      createRuntime: () => {
        throw new Error('Unexpected MCP call')
      }
    }),
    Deno: {
      env: { get: (name: string) => (name === 'ANKOLE_FUNCTION_RUNTIME_TOKEN' ? 'unit-token' : '1') },
      readTextFileSync: () => 'VmRSS: 1024',
      serve: (next: typeof handler) => {
        handler = next
      },
      upgradeWebSocket: () => ({ socket: new Socket(), response: new Response() })
    },
    EdgeRuntime: { userWorkers: { create } }
  })
  const request = (path: string, upgrade = false, method = 'GET', body?: string) =>
    handler(
      new Request(`http://runtime${path}`, {
        method,
        body,
        headers: {
          authorization: 'Bearer unit-token',
          ...(upgrade ? { upgrade: 'websocket' } : {}),
          'x-ankole-mcp-origin': 'http://control-plane',
          'x-ankole-caller-mcp-token': 'caller',
          'x-ankole-admin-mcp-token': 'admin'
        }
      })
    )
  const code = { source: 'export default {}', env: {} }
  const sha = await appletCodeDigest(code)
  expect((await request(`/v1/applet/code/${sha}`, false, 'PUT', JSON.stringify(code))).status).toBe(204)
  return {
    request,
    advance: (ms: number) => {
      now += ms
    },
    reserve: async (id: string, page: string) => {
      const path = `/v1/applet/invoke?tenant_id=test&page_id=${page}&revision=1&sha256=${sha}&run_id=${id}&timeout_ms=60000`
      expect((await request(path)).status).toBe(204)
      return path
    }
  }
}
