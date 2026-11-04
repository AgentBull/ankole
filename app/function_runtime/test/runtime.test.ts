import { describe, expect, test } from 'bun:test'
import { availableParallelism } from 'node:os'

const base = process.env.ANKOLE_FUNCTION_RUNTIME_URL || 'http://127.0.0.1:5435'
const headers = {
  authorization: `Bearer ${process.env.ANKOLE_FUNCTION_RUNTIME_TOKEN || 'dev-function-runtime-token'}`,
  'content-type': 'application/json',
  'x-ankole-mcp-origin': 'http://host.docker.internal:5546',
  'x-ankole-caller-mcp-token': 'caller-test-token',
  'x-ankole-admin-mcp-token': 'admin-test-token'
}
const post = async (path: string, body: unknown) =>
  await fetch(base + path, { method: 'POST', headers, body: JSON.stringify(body) })
const tool = { namespace: 'test', name: 'lookup', global_name: 'lookup' }
const run = async (program: string, memo: unknown[] = [], options = {}) => {
  const response = await post('/v1/program/run', { program, tools: [tool], memo, ...options })
  expect(response.status).toBe(200)
  const bytes = await response.text()
  const value = JSON.parse(bytes)
  if (!value || typeof value !== 'object') {
    throw new Error(`Invalid program outcome: HTTP ${response.status} ${JSON.stringify(bytes)}`)
  }
  return value
}

async function publish(source: string, env: Record<string, string> = {}) {
  const entries = Object.entries(env).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
  const sha = new Bun.CryptoHasher('sha256').update(`${source}\n${JSON.stringify(entries)}`).digest('hex')
  const response = await fetch(`${base}/v1/applet/code/${sha}`, {
    method: 'PUT',
    headers,
    body: JSON.stringify({ source, env })
  })
  expect(response.status).toBe(204)
  return sha
}

async function invoke(
  sha: string,
  context: Record<string, unknown> = { method: 'POST', path: '/' },
  options: {
    page?: string
    lane?: 'route' | 'action'
    revision?: number
    timeout?: number
    call?: (frame: { operation: string; args: unknown[] }) => Promise<unknown>
  } = {}
) {
  const runId = crypto.randomUUID()
  const path = `/v1/applet/invoke?tenant_id=test&page_id=${options.page || sha}&revision=${options.revision || 1}&sha256=${sha}&run_id=${runId}&timeout_ms=${options.timeout || 2000}&lane=${options.lane || 'route'}`
  const ready = await fetch(base + path, { headers })
  expect(ready.status).toBe(204)
  try {
    return await new Promise<any>((resolve, reject) => {
      const ws = new WebSocket(base.replace(/^http/, 'ws') + path, { headers })
      let settled = false
      ws.onopen = () => ws.send(JSON.stringify({ type: 'start', run_id: runId, context }))
      ws.onmessage = async event => {
        const frame = JSON.parse(String(event.data))
        if (frame.type === 'done') {
          settled = true
          resolve(frame.outcome)
        }
        if (frame.type === 'call') {
          try {
            const value = await options.call!(frame)
            ws.send(JSON.stringify({ type: 'reply', call_id: frame.call_id, value }))
          } catch (error) {
            reject(error)
            ws.close()
          }
        }
      }
      ws.onerror = reject
      ws.onclose = () => {
        if (!settled) reject(new Error('Invocation closed before completion'))
      }
    })
  } finally {
    expect((await fetch(`${base}/v1/applet/invocations/${runId}`, { method: 'DELETE', headers })).status).toBe(204)
  }
}

describe('real edge-runtime protocol', () => {
  test('host MCPorter keeps caller and admin credentials out of the Applet and consumes MCP capability frames', async () => {
    const calls: { token: string | null; path: string; name: string }[] = []
    let failure: Record<string, unknown> | undefined
    const gateway = Bun.serve({
      hostname: '0.0.0.0',
      port: 5546,
      async fetch(request) {
        if (request.method === 'DELETE') return new Response(null, { status: 204 })
        const body = (await request.json()) as { id?: string; method: string; params?: { name?: string } }
        if (body.method.startsWith('notifications/')) return new Response(null, { status: 202 })
        let result: unknown
        if (body.method === 'server/discover') {
          result = { supportedVersions: ['2026-07-28'], capabilities: { tools: {} }, ttlMs: 0, cacheScope: 'private' }
        } else if (body.method === 'initialize') {
          result = {
            protocolVersion: '2026-07-28',
            capabilities: { tools: {} },
            serverInfo: { name: 'test', version: '1' }
          }
        } else if (body.method === 'tools/list') {
          result = { tools: [{ name: 'inspect', inputSchema: { type: 'object' } }] }
        } else {
          calls.push({
            token: request.headers.get('authorization'),
            path: new URL(request.url).pathname + new URL(request.url).search,
            name: body.params!.name!
          })
          result = failure
            ? {
                isError: true,
                structuredContent: { error: failure },
                content: [{ type: 'text', text: JSON.stringify(failure) }]
              }
            : { structuredContent: { identity: calls.length }, content: [{ type: 'text', text: 'ok' }] }
        }
        return Response.json({ jsonrpc: '2.0', id: body.id, result: { ...(result as object), resultType: 'complete' } })
      }
    })
    try {
      const sha = await publish(`export default {'POST /': async () => ({
        caller: await AnkoleRuntime.mcp.call('inspect', {}, {server:'github',connection:'work',account:'installation'}),
        admin: await AnkoleRuntime.admin.mcp.call('inspect', {}, {skill:'research',server:'context'}),
        leaked: Boolean(process.env.ANKOLE_MCP_TOKEN || Deno.env.get('ANKOLE_MCP_TOKEN') || process.env.ANKOLE_FUNCTION_RUNTIME_TOKEN)
      })}`)
      const result = await invoke(
        sha,
        { method: 'POST', path: '/' },
        {
          timeout: 15000,
          call: async () => {
            throw new Error('MCP escaped the trusted host')
          }
        }
      )
      expect(result).toMatchObject({ status: 200 })
      expect(result.body).toEqual({ caller: { identity: 1 }, admin: { identity: 2 }, leaked: false })
      expect(calls).toEqual([
        {
          token: 'Bearer caller-test-token',
          path: '/api/internal/mcp/toolkits/github?connection=work&account=installation',
          name: 'inspect'
        },
        { token: 'Bearer admin-test-token', path: '/api/internal/mcp/skills/research/context', name: 'inspect' }
      ])
      const catching = await publish(`export default {'POST /': async () => {
        try { await AnkoleRuntime.mcp.call('inspect', {}, {server:'github'}); }
        catch (error) { return {code:error.code, details:error.details, retryable:error.retryable, request_sent:error.request_sent}; }
      }}`)
      const action = await publish(`export default {actions:{inspect:{handler:async () =>
        await AnkoleRuntime.admin.mcp.call('inspect', {}, {server:'github'})
      }}}`)
      for (const error of [
        {
          code: 'oauth_consent_required',
          authorization_url: '/connectors?connection=work&scopes=repo',
          retryable: false
        },
        { code: 'rate_limited', retryAfterSeconds: 12, retryable: true, request_sent: false },
        { code: 'invalid_upstream_response', status: 200, retryable: false },
        {
          code: 'partial_success',
          resource_id: 'approval-42',
          completed_step: 'approve',
          failed_step: 'card_update',
          retryable: false
        }
      ]) {
        failure = error
        const handled = await invoke(catching, { method: 'POST', path: '/' }, { timeout: 15000 })
        expect(handled).toMatchObject({
          status: 200,
          body: { code: error.code, details: error, retryable: error.retryable }
        })
        const unhandled = await invoke(sha, { method: 'POST', path: '/' }, { timeout: 15000 })
        expect(unhandled).toMatchObject({ status: 502, body: { error: { code: error.code, details: error } } })
        const failedAction = await invoke(action, { actionKey: 'inspect' }, { lane: 'action', timeout: 15000 })
        expect(failedAction).toMatchObject({
          status: 502,
          body: { error: { code: error.code, details: error } }
        })
      }
    } finally {
      gateway.stop(true)
    }
  }, 20000)

  test('host MCP protocol rejection promptly preserves the authorization error', async () => {
    const gateway = Bun.serve({
      hostname: '0.0.0.0',
      port: 5546,
      async fetch(request) {
        const body = (await request.json()) as { id?: string; method: string }
        if (body.method.startsWith('notifications/')) return new Response(null, { status: 202 })
        if (body.method === 'server/discover') {
          return Response.json({
            jsonrpc: '2.0',
            id: body.id,
            result: {
              resultType: 'complete',
              supportedVersions: ['2026-07-28'],
              capabilities: { tools: {} },
              ttlMs: 0,
              cacheScope: 'private'
            }
          })
        }
        return Response.json({
          jsonrpc: '2.0',
          id: body.id,
          error: {
            code: -32603,
            message: 'user_authority_unavailable',
            data: { code: 'user_authority_unavailable', message: 'No human caller', request_sent: false }
          }
        })
      }
    })
    try {
      const sha = await publish(`export default {actions:{inspect:{handler:async () => {
        try { await AnkoleRuntime.mcp.call('inspect', {}, {server:'github'}); }
        catch (error) { return {code:error.code, details:error.details, request_sent:error.request_sent}; }
      }}}}`)
      const result = await invoke(sha, { actionKey: 'inspect' }, { lane: 'action', timeout: 5000 })
      expect(result).toMatchObject({
        status: 200,
        body: {
          code: 'user_authority_unavailable',
          details: { code: 'user_authority_unavailable', message: 'No human caller' },
          request_sent: false
        }
      })
    } finally {
      gateway.stop(true)
    }
  }, 8000)

  test('published quant monitor Action reads its Pod configuration and emits a weekly event through host MCP', async () => {
    const build = await Bun.build({
      entrypoints: [
        new URL('../../../internals/agent-plugins/quant-factor-monitor/runtime/automation-main.ts', import.meta.url)
          .pathname
      ],
      target: 'browser',
      format: 'esm'
    })
    expect(build.success).toBe(true)
    const source = await build.outputs[0]!.text()
    const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Shanghai' }).format(new Date())
    const config = {
      version: 3,
      plugin: 'quant-factor-monitor',
      portfolio_id: 'proof',
      drive_root: 'chats/proof/quant-factor-monitor/proof',
      input_drive_path: 'positions.csv',
      state_drive_path: 'state.json',
      data_trade_date: '2020-01-01',
      stocks: []
    }
    const upstream: string[] = []
    const gateway = Bun.serve({
      hostname: '0.0.0.0',
      port: 5546,
      async fetch(request) {
        const body = (await request.json()) as any
        let result: any
        if (body.method === 'server/discover') {
          result = { supportedVersions: ['2026-07-28'], capabilities: { tools: {} }, ttlMs: 0, cacheScope: 'private' }
        } else if (body.method === 'tools/list') {
          result = {
            tools: [{ name: 'bullx_semantic_query', inputSchema: { type: 'object' } }],
            ttlMs: 0,
            cacheScope: 'private'
          }
        } else {
          expect(request.headers.get('authorization')).toBe('Bearer admin-test-token')
          expect(new URL(request.url).pathname).toBe(
            '/api/internal/mcp/skills/bullx-financial-data/bullx-financial-data'
          )
          const args = body.params.arguments
          upstream.push(args.operation)
          const data =
            args.operation === 'describe'
              ? { catalog_revision: 'proof' }
              : {
                  rows: ['000001.SZ', '600519.SH', '300750.SZ'].map(symbol => ({ symbol, trade_date: today }))
                }
          result = { content: [], structuredContent: { success: true, data } }
        }
        return Response.json({ jsonrpc: '2.0', id: body.id, result: { resultType: 'complete', ...result } })
      }
    })
    try {
      const inspected = await post('/v1/applet/inspect', { source })
      expect(inspected.status).toBe(200)
      expect(((await inspected.json()) as any).actions.monitor).toMatchObject({
        idempotent: false,
        concurrency: 'serial_fifo'
      })
      const sha = await publish(source)
      const events: any[] = []
      const result = await invoke(
        sha,
        {
          kind: 'action',
          actionKey: 'monitor',
          applet: { pageId: 'quant-page', revision: 1 },
          job: { id: 41, config: {} },
          run: { id: 42, attemptId: 'attempt', sliceCount: 0, progress: {} },
          signal: { id: 'weekly-proof', type: 'schedule.fired', data: { mode: 'weekly' } }
        },
        {
          lane: 'action',
          timeout: 15000,
          async call(frame) {
            if (frame.operation === 'admin.file.read') {
              expect(frame.args).toEqual(['pages/quant-page/src/server/config.json'])
              return { bytes: { __ankole_bytes: Buffer.from(JSON.stringify(config)).toString('base64') } }
            }
            expect(frame.operation).toBe('admin.signals.emit')
            events.push((frame.args as any[])[0])
            return { accepted: true, signalId: 'accepted' }
          }
        }
      )
      expect(result.status).toBe(200)
      expect(upstream).toEqual(['describe', 'execute'])
      expect(events).toEqual([
        {
          id: 'weekly-proof:quant-factor-monitor.weekly',
          type: 'quant-factor-monitor.weekly',
          data: {
            kind: 'quant-factor-monitor.weekly',
            portfolio_id: 'proof',
            drive_root: config.drive_root,
            input_drive_path: 'positions.csv',
            previous_state_drive_path: 'state.json',
            previous_data_trade_date: '2020-01-01',
            data_trade_date: today,
            touches: {
              price_below_stop: [],
              touched_stop: [],
              touched_sell_zone: [],
              touched_buy_zone: [],
              no_bars: []
            },
            instruction:
              'Use the quant-factor-monitor Skill to start the weekly tracking Background Agent Job for this portfolio with these drive paths and data trade date.'
          }
        }
      ])
    } finally {
      await gateway.stop(true)
    }
  }, 20000)

  test('Action remainingMs uses the invocation budget supplied by its control-plane owner', async () => {
    const sha = await publish(`export default {actions:{inspect:{handler:ctx => ({remaining:ctx.remainingMs()})}}}`)
    const result = await invoke(sha, { actionKey: 'inspect' }, { lane: 'action', timeout: 240000 })
    expect(result.status).toBe(200)
    expect(result.body.remaining).toBeGreaterThan(230000)
    expect(result.body.remaining).toBeLessThanOrEqual(240000)
  })

  test('Action can complete an awaited operation after sixty seconds within its invocation budget', async () => {
    const sha = await publish(`export default {actions:{inspect:{handler:async ctx => {
      await new Promise(resolve => setTimeout(resolve, 61000));
      return {completed:true, remaining:ctx.remainingMs()};
    }}}}`)
    const result = await invoke(sha, { actionKey: 'inspect' }, { lane: 'action', timeout: 75000 })
    expect(result.status).toBe(200)
    expect(result.body.completed).toBe(true)
    expect(result.body.remaining).toBeGreaterThan(0)
  }, 80000)

  test('capacity saturation rejects new work without failing liveness', async () => {
    const sha = await publish('export default {"GET /":()=>1}')
    const runs: string[] = []
    const capacity = 24
    try {
      for (let index = 0; index < capacity; index++) {
        const runId = crypto.randomUUID()
        const path = `/v1/applet/invoke?tenant_id=health&page_id=health&revision=1&sha256=${sha}&run_id=${runId}&timeout_ms=30000&memory_mb=64`
        expect((await fetch(base + path, { headers })).status).toBe(204)
        runs.push(runId)
      }
      expect((await post('/v1/applet/inspect', { source: 'export default {"GET /":()=>1}' })).status).toBe(503)
      expect((await fetch(`${base}/_internal/health`)).status).toBe(200)
    } finally {
      for (const runId of runs) {
        await fetch(`${base}/v1/applet/invocations/${runId}`, { method: 'DELETE', headers })
      }
    }
    expect((await post('/v1/applet/inspect', { source: 'export default {"GET /":()=>1}' })).status).toBe(200)
  })

  test('six background slices leave foreground capacity and use separate pools', async () => {
    const sha = await publish(`let count=0; export default {
      routes:{'POST /':()=>++count},
      actions:{work:{idempotent:true,handler:async()=>{
        const bytes=new Uint8Array(150*1024*1024); bytes.fill(1);
        await AnkoleRuntime.admin.base.query('hold'); return ++count + bytes[0] - 1
      }}}
    }`)
    const page = crypto.randomUUID()
    let release!: () => void
    const hold = new Promise<void>(resolve => {
      release = resolve
    })
    let ready = 0
    const background = Array.from({ length: 6 }, () =>
      invoke(sha, { actionKey: 'work' } as any, {
        page,
        lane: 'action',
        timeout: 20000,
        call: async () => {
          ready++
          await hold
          return {}
        }
      })
    )
    try {
      for (let i = 0; i < 500 && ready < 6; i++) await Bun.sleep(10)
      expect(ready).toBe(6)
      const path = `/v1/applet/invoke?tenant_id=test&page_id=${page}&revision=1&sha256=${sha}&run_id=${crypto.randomUUID()}&lane=action`
      expect((await fetch(base + path, { headers })).status).toBe(503)
      expect((await invoke(sha, undefined, { page })).body).toBe(1)
      expect(await run('text("foreground PTC");')).toMatchObject({
        status: 'completed',
        output: [{ kind: 'text', value: 'foreground PTC' }]
      })
      expect((await fetch(`${base}/_internal/health`)).status).toBe(200)
    } finally {
      release()
    }
    const results = await Promise.all(background)
    expect(results.every(result => result.status === 200 && result.body === 1)).toBe(true)
  }, 30000)

  test('separate Applet workers have separate temporary files', async () => {
    const sha = await publish(
      'import {readFile,writeFile} from "node:fs/promises"; export default {"POST /":async r=>{if(r.body){await writeFile("/tmp/isolation-test",r.body);return "saved"}try{return await readFile("/tmp/isolation-test","utf8")}catch(error){return error.code}}}'
    )
    const prefix = crypto.randomUUID()
    expect(
      (await invoke(sha, { method: 'POST', path: '/', body: 'private' } as any, { page: `${prefix}-a` })).body
    ).toBe('saved')
    expect((await invoke(sha, { method: 'POST', path: '/' }, { page: `${prefix}-b` })).body).toBe('ENOENT')
    expect((await invoke(sha, { method: 'POST', path: '/' }, { page: `${prefix}-a` })).body).toBe('private')
  })

  test('a canceled CPU-bound Applet leaves unrelated cold inspections available', async () => {
    const sha = await publish(
      'export default {"POST /":async r=>{if(r.body==="loop"){await AnkoleRuntime.base.query("ready",{});while(true){}}return 1}}'
    )
    const prefix = `isolation-${crypto.randomUUID()}`
    const threadCount = availableParallelism()
    const warmCount = Math.max(2, Math.ceil(20 / threadCount)) * threadCount
    // Give every native execution thread equal resident load before testing a cold worker.
    for (let index = 0; index < warmCount; index++) {
      expect(
        await invoke(sha, { method: 'POST', path: '/' }, { page: `${prefix}-${index}`, timeout: 10000 })
      ).toMatchObject({
        status: 200,
        body: 1
      })
    }

    const runId = crypto.randomUUID()
    const path = `/v1/applet/invoke?tenant_id=test&page_id=${prefix}-0&revision=1&sha256=${sha}&run_id=${runId}&timeout_ms=10000`
    expect((await fetch(base + path, { headers })).status).toBe(204)
    const ws = new WebSocket(base.replace(/^http/, 'ws') + path, { headers })
    let end!: () => void
    const ended = new Promise<void>(resolve => {
      end = resolve
    })
    ws.onclose = end
    try {
      await new Promise<void>((resolve, reject) => {
        ws.onerror = reject
        ws.onopen = () =>
          ws.send(
            JSON.stringify({ type: 'start', run_id: runId, context: { method: 'POST', path: '/', body: 'loop' } })
          )
        ws.onmessage = event => {
          const frame = JSON.parse(String(event.data))
          if (frame.type === 'call') {
            ws.send(JSON.stringify({ type: 'reply', call_id: frame.call_id, value: {} }))
            resolve()
          }
        }
      })
      await Bun.sleep(50)
      ws.send(JSON.stringify({ type: 'cancel', run_id: runId }))
      const inspected = await post('/v1/applet/inspect', { source: 'export default {"GET /":()=>1}', timeout_ms: 5000 })
      expect(inspected.status).toBe(200)
      expect(await inspected.json()).toMatchObject({ routes: ['GET /'] })
    } finally {
      let cleanupTimer!: ReturnType<typeof setTimeout>
      await Promise.race([
        ended,
        new Promise<void>(resolve => {
          cleanupTimer = setTimeout(resolve, 25000)
        })
      ])
      clearTimeout(cleanupTimer)
      ws.close()
      await fetch(`${base}/v1/applet/invocations/${runId}`, { method: 'DELETE', headers })
    }
  }, 35000)

  test('protects runtime endpoints and reports cache misses before upgrade', async () => {
    expect((await fetch(`${base}/v1/program/run`, { method: 'POST' })).status).toBe(401)
    const path = `/v1/applet/invoke?tenant_id=t&page_id=p&revision=1&sha256=${'0'.repeat(64)}&run_id=${crypto.randomUUID()}`
    expect((await fetch(base + path, { headers })).status).toBe(428)
  })
  test('a canceled CPU-bound Applet leaves its next invocation available on a fresh worker', async () => {
    const sha = await publish(
      'let count=0; export default {"GET /ok":()=>++count,"POST /loop":async()=>{await AnkoleRuntime.base.query("started");while(true){}}}'
    )
    const page = crypto.randomUUID()
    expect((await invoke(sha, { method: 'GET', path: '/ok' }, { page, timeout: 10000 })).body).toBe(1)
    const runId = crypto.randomUUID()
    const path = `/v1/applet/invoke?tenant_id=test&page_id=${page}&revision=1&sha256=${sha}&run_id=${runId}&timeout_ms=10000`
    expect((await fetch(base + path, { headers })).status).toBe(204)
    const ws = new WebSocket(base.replace(/^http/, 'ws') + path, { headers })
    let timer: ReturnType<typeof setTimeout> | undefined
    try {
      await new Promise<void>((resolve, reject) => {
        timer = setTimeout(() => reject(new Error('Looping Applet did not start')), 2000)
        ws.onerror = reject
        ws.onclose = () => reject(new Error('Looping Applet closed before its capability call'))
        ws.onopen = () =>
          ws.send(JSON.stringify({ type: 'start', run_id: runId, context: { method: 'POST', path: '/loop' } }))
        ws.onmessage = event => {
          const frame = JSON.parse(String(event.data))
          if (frame.type === 'call') {
            ws.send(JSON.stringify({ type: 'reply', call_id: frame.call_id, value: true }))
            resolve()
          }
        }
      })
      clearTimeout(timer)
      await Bun.sleep(50)
      ws.send(JSON.stringify({ type: 'cancel', run_id: runId }))
      expect(
        (await fetch(`${base}/v1/applet/invocations/${runId}?aborted=1`, { method: 'DELETE', headers })).status
      ).toBe(204)
      ws.close()
      expect((await invoke(sha, { method: 'GET', path: '/ok' }, { page })).body).toBe(1)
    } finally {
      clearTimeout(timer)
      ws.close()
      await fetch(`${base}/v1/applet/invocations/${runId}?aborted=1`, { method: 'DELETE', headers })
    }
  })
  test('inspects route functions without invoking handlers and rejects conflicting routes', async () => {
    expect(
      await (
        await post('/v1/applet/inspect', { source: 'export default {"GET /":()=>{throw Error("not invoked")}}' })
      ).json()
    ).toEqual({ routes: ['GET /'], actions: {}, concurrencyKeys: {} })
    const invalid = await post('/v1/applet/inspect', { source: 'export default {"GET /:x":()=>1,"GET /:y":()=>2}' })
    expect(invalid.status).toBe(422)
    const guarded = await post('/v1/applet/inspect', {
      source: 'await AnkoleRuntime.base.query("t"); export default {}'
    })
    expect(guarded.status).toBe(422)
    const caught = await post('/v1/applet/inspect', {
      source: 'try { await AnkoleRuntime.base.query("t") } catch {} export default {}'
    })
    expect(caught.status).toBe(422)
  })
  test('inspection reads the published environment during module initialization', async () => {
    const response = await post('/v1/applet/inspect', {
      source:
        'const hook=new URL(process.env.HOOK); if(process.env.ANKOLE_FUNCTION_RUNTIME_TOKEN || Deno.env.get("ANKOLE_FUNCTION_RUNTIME_TOKEN")) throw Error("Main environment leaked"); export default {"GET /":()=>hook.href}',
      env: { HOOK: 'https://example.com/hook' }
    })
    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({ routes: ['GET /'], actions: {}, concurrencyKeys: {} })
  })
  test('inspection and invocation support CommonJS builtin loading and global Buffer', async () => {
    const source = `import {createRequire} from 'node:module';
      const require=createRequire(import.meta.url);
      const {createHash}=require('node:crypto');
      const bytes=Buffer.from('applet');
      const digest=createHash('sha256').update(bytes).digest('hex');
      export default {'GET /':()=>({text:bytes.toString(),digest})};`
    const inspected = await post('/v1/applet/inspect', { source })
    expect(inspected.status).toBe(200)
    expect(await inspected.json()).toMatchObject({ routes: ['GET /'] })
    const sha = await publish(source)
    expect(await invoke(sha, { method: 'GET', path: '/' })).toMatchObject({
      status: 200,
      body: { text: 'applet', digest: new Bun.CryptoHasher('sha256').update('applet').digest('hex') }
    })
  })
  test('inspection and invocation wait for top-level await before reading the default export', async () => {
    const source = `const runtime=AnkoleRuntime;
      await new Promise(resolve=>setTimeout(resolve,200));
      const label=Buffer.from('initialized').toString();
      export default {'POST /':()=>({label,capabilities:runtime===AnkoleRuntime})};`
    const inspected = await post('/v1/applet/inspect', { source, timeout_ms: 1000 })
    expect(inspected.status).toBe(200)
    expect(await inspected.json()).toEqual({ routes: ['POST /'], actions: {}, concurrencyKeys: {} })
    const sha = await publish(source)
    expect(await invoke(sha, undefined, { timeout: 1000 })).toMatchObject({
      status: 200,
      body: { label: 'initialized', capabilities: true }
    })
  })
  test('PTC completes, pauses, resumes, preserves null and checks namespace', async () => {
    const program = 'const value=await tools.lookup(null); text(value.price);'
    expect(await run(program)).toMatchObject({
      status: 'pending',
      pending_calls: [{ namespace: 'test', name: 'lookup', arguments: null }]
    })
    expect(
      await run(program, [{ namespace: 'test', name: 'lookup', arguments: null, output: { price: 42 } }])
    ).toMatchObject({ status: 'completed', output: [{ kind: 'text', value: '42' }] })
    expect(await run('text(Date.now()); text(Math.random());')).toEqual(
      await run('text(Date.now()); text(Math.random());')
    )
  })
  test('PTC detects replay divergence, unused memo and source/output/pending limits', async () => {
    const memo = [{ namespace: 'test', name: 'lookup', arguments: { x: 1 }, output: {} }]
    expect(await run('await tools.lookup({x:2});', memo)).toMatchObject({ error_code: 'program_replay_diverged' })
    expect(await run('text("done")', memo)).toMatchObject({ error_code: 'program_replay_memo_unused' })
    expect(await run('for (let i = 0; i < 17; i++) text("x".repeat(65536))')).toMatchObject({
      error_code: 'program_output_limit_exceeded'
    })
    expect(await run(`text("${'x'.repeat(256 * 1024)}")`)).toMatchObject({
      error_code: 'program_source_limit_exceeded'
    })
    expect(
      await run('await Promise.all([tools.lookup(1),tools.lookup(2)])', [], { max_pending_calls: 1 })
    ).toMatchObject({ error_code: 'program_pending_limit_exceeded' })
    expect(await run('throw Error("boom")')).toMatchObject({ error_code: 'program_execution_failed' })
  })
  test('PTC cannot publish pending calls after catching a replay mismatch', async () => {
    const memo = [{ namespace: 'test', name: 'lookup', arguments: { x: 1 }, output: 'recorded' }]
    expect(
      await run(
        'try { await tools.lookup({x:2}); } catch {} await tools.lookup({x:1}); await tools.lookup({x:3});',
        memo
      )
    ).toMatchObject({
      status: 'failed',
      error_code: 'program_replay_diverged',
      pending_calls: []
    })
  })
  test('PTC parses source as a function body and rejects direct module imports', async () => {
    expect(await run('}; text(typeof Deno); const escape = async () => {')).toMatchObject({
      status: 'failed',
      output: [],
      error_code: 'program_execution_failed'
    })
    expect(await run('const crypto = await import("node:crypto"); text(crypto.randomUUID())')).toMatchObject({
      status: 'failed',
      output: [],
      error_code: 'program_execution_failed'
    })
    expect(await run('text("import(node:crypto)")')).toMatchObject({ status: 'completed' })
  })
  test('PTC isolates direct IO and terminates a CPU loop without affecting later requests', async () => {
    expect(await run('text(typeof fetch); text(typeof Deno); text(typeof setTimeout)')).toMatchObject({
      output: Array(3).fill({ kind: 'text', value: 'undefined' })
    })
    expect(await run('for(;;){}', [], { timeout_ms: 100 })).toMatchObject({
      status: 'failed',
      error_code: 'program_timeout'
    })
    expect(await run('text(3)')).toMatchObject({ status: 'completed' })
  })
  test('PTC timeout returns a structured response without closing its parent request', async () => {
    const response = await post('/v1/program/run', { program: 'for(;;){}', tools: [], memo: [], timeout_ms: 1000 })
    expect(response.status).toBe(200)
    expect(await response.json()).toMatchObject({ status: 'failed', error_code: 'program_timeout' })
    expect(await run('text("healthy-after-timeout")')).toMatchObject({
      status: 'completed',
      output: [{ kind: 'text', value: 'healthy-after-timeout' }]
    })
  })
  test('PTC reports its heap quota separately from timeout and leaves later requests available', async () => {
    expect(
      await run('const blocks=[];for(let i=0;i<384;i++)blocks.push(new Array(262144).fill(i));', [], {
        timeout_ms: 10000
      })
    ).toMatchObject({ status: 'failed', error_code: 'program_heap_limit_exceeded', output: [], pending_calls: [] })
    expect(await run('text(1)')).toMatchObject({ status: 'completed', output: [{ kind: 'text', value: '1' }] })
  }, 15000)
  test('Applet environment and Node crypto deliver a signed request to a real HTTP webhook', async () => {
    const received: { method: string; path: string; body: string; signature: string | null }[] = []
    const webhook = Bun.serve({
      hostname: '0.0.0.0',
      port: 0,
      async fetch(request) {
        received.push({
          method: request.method,
          path: new URL(request.url).pathname,
          body: await request.text(),
          signature: request.headers.get('x-signature')
        })
        return Response.json({ accepted: true })
      }
    })
    try {
      const sha = await publish(
        `import {createHmac} from 'node:crypto';
         export default {'POST /':async()=>{
           const body='what do ya want for nothing?';
           const signature=createHmac('sha256',process.env.SIGNING_KEY).update(body).digest('hex');
           const response=await fetch(process.env.HOOK,{method:'POST',headers:{'x-signature':signature},body});
           return await response.json();
         }}`,
        { HOOK: `http://host.docker.internal:${webhook.port}/signed`, SIGNING_KEY: 'Jefe' }
      )
      expect(await invoke(sha)).toMatchObject({ status: 200, body: { accepted: true } })
      expect(received).toEqual([
        {
          method: 'POST',
          path: '/signed',
          body: 'what do ya want for nothing?',
          signature: '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843'
        }
      ])
    } finally {
      await webhook.stop(true)
    }
  })
  test('warm Applets support Node builtins, /tmp, env and retain module state', async () => {
    const source =
      'import {createHash} from "node:crypto"; import {writeFile,readFile} from "node:fs/promises"; let count=0; export default {"POST /":async()=>{await writeFile("/tmp/test","ok");return {count:++count,env:process.env.VALUE,token:process.env.ANKOLE_FUNCTION_RUNTIME_TOKEN,denoToken:Deno.env.get("ANKOLE_FUNCTION_RUNTIME_TOKEN"),mainCapacity:Deno.env.get("ANKOLE_FUNCTION_RUNTIME_MAX_CONCURRENCY"),hash:createHash("sha256").update("ok").digest("hex"),file:await readFile("/tmp/test","utf8"),fetch:await(await fetch("data:text/plain,hello")).text()}}}'
    const page = crypto.randomUUID()
    const sha = await publish(source, { VALUE: 'first' })
    expect((await invoke(sha, undefined, { page })).body).toMatchObject({
      count: 1,
      env: 'first',
      file: 'ok',
      fetch: 'hello'
    })
    const again = await invoke(sha, undefined, { page })
    expect(again.body.count).toBe(2)
    expect(again.body.token).toBeUndefined()
    expect(again.body.denoToken).toBeUndefined()
    expect(again.body.mainCapacity).toBeUndefined()
    const next = await publish(source, { VALUE: 'second' })
    expect(next).not.toBe(sha)
    expect((await invoke(next, undefined, { page, revision: 2 })).body.env).toBe('second')
  })
  test('file capabilities transfer binary bytes without text conversion', async () => {
    const bytes = Uint8Array.from({ length: 256 }, (_, value) => value)
    const encoded = Buffer.from(bytes).toString('base64')
    const sha = await publish(
      'export default {"POST /":async()=>{const bytes=Uint8Array.from({length:256},(_,value)=>value);await AnkoleRuntime.file.write("page",{bytes});const file=await AnkoleRuntime.file.read("path");return Array.from(file.bytes)}}'
    )
    const operations: string[] = []
    const result = await invoke(
      sha,
      { method: 'POST', path: '/' },
      {
        call: async frame => {
          operations.push(frame.operation)
          if (frame.operation === 'file.write') {
            expect(frame.args).toEqual(['page', { bytes: { __ankole_bytes: encoded } }])
            return { path: 'path' }
          }
          expect(frame.args).toEqual(['path'])
          return { bytes: { __ankole_bytes: encoded } }
        }
      }
    )
    expect(operations).toEqual(['file.write', 'file.read'])
    expect(result.body).toEqual(Array.from(bytes))
  })

  test('warm concurrent calls keep capability replies and logs within their invocation', async () => {
    const sha = await publish(
      'export default {"POST /":async()=>{const value=await AnkoleRuntime.base.query("t");console.log(value);return value}}'
    )
    const [left, right] = await Promise.all([
      invoke(sha, undefined, {
        call: async () => {
          await Bun.sleep(20)
          return 'left'
        }
      }),
      invoke(sha, undefined, { call: async () => 'right' })
    ])
    expect(left).toMatchObject({ body: 'left', logs: [{ message: 'left' }] })
    expect(right).toMatchObject({ body: 'right', logs: [{ message: 'right' }] })
  })
  test('one Applet CPU loop leaves another warm Applet responsive', async () => {
    const healthy = await publish('export default {"POST /":()=>({ok:true})}')
    const healthyPage = crypto.randomUUID()
    expect((await invoke(healthy, undefined, { page: healthyPage })).status).toBe(200)
    const looping = await publish(
      'export default {"POST /":async()=>{await AnkoleRuntime.base.query("started");while(true){}}}'
    )
    let entered!: () => void
    const running = new Promise<void>(resolve => {
      entered = resolve
    })
    let terminal = 'pending'
    const bad = invoke(looping, undefined, {
      page: crypto.randomUUID(),
      timeout: 1000,
      call: async () => {
        entered()
        return true
      }
    }).then(
      outcome => {
        terminal = outcome.status >= 400 ? 'failed' : 'completed'
      },
      () => {
        terminal = 'failed'
      }
    )
    await running
    await Bun.sleep(20)
    expect((await invoke(healthy, undefined, { page: healthyPage })).body).toEqual({ ok: true })
    expect(terminal).toBe('pending')
    await bad
    expect(terminal).toBe('failed')
  })
  test('GET cannot dispatch writes and completed invocations release admission slots', async () => {
    const sha = await publish('export default {"GET /":()=>AnkoleRuntime.base.write("t",{}),"POST /":()=>1}')
    expect((await invoke(sha, { method: 'GET', path: '/' })).body.error.code).toBe('read_only_route')
    for (let i = 0; i < 40; i++) expect((await invoke(sha)).status).toBe(200)
  })
})
