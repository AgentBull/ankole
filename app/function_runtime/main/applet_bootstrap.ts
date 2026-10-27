import { matchRoute, validateRoutes } from './routes.ts'
import { withRecordIDs } from '@ankole/applet-sdk/records'
import type { RecordWrite } from '@ankole/applet-sdk/types'

type InvocationState = {
  ws: WebSocket
  runId: string
  method: string
  logs: { level: string; message: string }[]
  pending: Map<number, { resolve: (value: any) => void; reject: (reason: unknown) => void }>
  nextCall: number
  finished: boolean
  timer: ReturnType<typeof setTimeout>
}

export function buildAppletWorkerBootstrap(source: string, inspectOnly = false) {
  // Install capabilities before the source runs. Wait for top-level await so self-import can read the default export.
  return `const __ankoleAppletReady = Promise.withResolvers();
{
const { AsyncLocalStorage } = await import("node:async_hooks");
const { Buffer } = await import("node:buffer");
const importApplet = () => import(import.meta.url);
const validateRoutes = ${validateRoutes.toString()};
const matchRoute = ${matchRoute.toString()};
const withRecordIDs = ${withRecordIDs.toString()};
(${appletWorker.toString()})(${inspectOnly}, __ankoleAppletReady.promise);
}
${source}
__ankoleAppletReady.resolve();`
}

function appletWorker(inspectOnly: boolean, initialized: Promise<void>) {
  ;(globalThis as Record<string, unknown>).Buffer ??= Buffer
  const als = new AsyncLocalStorage<InvocationState>()
  const errorInstances = new WeakSet()
  const trusted = Symbol()
  const json = JSON.stringify
  let inspectionCallAttempted = false
  class HttpError extends Error {
    status: number
    code: string
    details: unknown
    constructor(status: number, code: string, message = code, details?: unknown, authority?: symbol) {
      if (
        !Number.isInteger(status) ||
        status < 400 ||
        status > (authority === trusted ? 599 : 499) ||
        typeof code !== 'string'
      ) {
        throw new TypeError('HttpError requires status 400..499 and a string code')
      }
      super(String(message))
      this.status = status
      this.code = code
      this.details = details
      errorInstances.add(this)
    }
  }
  const hostError = (value: { status: number; code: string; message: string; details?: unknown }) =>
    new HttpError(value.status, value.code, value.message, value.details, trusted)
  function store() {
    const state = als.getStore()
    if (inspectOnly) inspectionCallAttempted = true
    if (!state || inspectOnly) {
      throw hostError({
        status: 500,
        code: 'inspect_only',
        message: 'Capabilities are unavailable during module inspection'
      })
    }
    if (state.finished) throw hostError({ status: 499, code: 'handler_cancelled', message: 'Applet invocation ended' })
    return state
  }
  async function call(operation: string, args: unknown[]) {
    const state = store()
    if (state.method === 'GET' && (operation === 'base.write' || operation === 'file.write')) {
      throw hostError({ status: 500, code: 'read_only_route', message: 'GET routes cannot write data' })
    }
    const callId = ++state.nextCall
    const result: any = await new Promise((resolve, reject) => {
      state.pending.set(callId, { resolve, reject })
      state.ws.send(json({ type: 'call', run_id: state.runId, call_id: callId, operation, args }))
    })
    if (operation === 'file.read' && typeof result?.bytes?.__ankole_bytes === 'string') {
      result.bytes = new Uint8Array(Buffer.from(result.bytes.__ankole_bytes, 'base64'))
    }
    return result
  }
  Object.defineProperty(globalThis, 'AnkoleRuntime', {
    value: Object.freeze({
      HttpError,
      base: Object.freeze({
        schema: (tableId: string) => call('base.schema', [tableId]),
        query: (tableId: string, query = {}) => call('base.query', [tableId, query]),
        aggregate: (tableId: string, query: unknown) => call('base.aggregate', [tableId, query]),
        write: (tableId: string, changes: RecordWrite) => call('base.write', [tableId, withRecordIDs(changes)])
      }),
      file: Object.freeze({
        list: (pageId: string) => call('file.list', [pageId]),
        read: (path: string) => call('file.read', [path]),
        write: (pageId: string, file: { bytes: Uint8Array }) => {
          store()
          if (!(file.bytes instanceof Uint8Array)) throw new TypeError('file.write bytes must be Uint8Array')
          return call('file.write', [
            pageId,
            { ...file, bytes: { __ankole_bytes: Buffer.from(file.bytes).toString('base64') } }
          ])
        }
      }),
      ai: Object.freeze({ generateText: (options: unknown) => call('ai.generateText', [options]) })
    }),
    enumerable: true
  })
  Object.defineProperty(globalThis, 'console', {
    value: Object.freeze(
      Object.fromEntries(
        ['log', 'info', 'warn', 'error', 'debug'].map(level => [
          level,
          (...args: unknown[]) => {
            const state = als.getStore()
            if (!state || state.finished || state.logs.length >= 100) return
            let message
            try {
              message = args.map(value => (typeof value === 'string' ? value : json(value))).join(' ')
            } catch {
              message = '[unserializable console value]'
            }
            state.logs.push({ level, message: message.slice(0, 16384) })
          }
        ])
      )
    ),
    configurable: false
  })

  const failure = (status: number, code: string, message: string) => ({ status, body: { error: { code, message } } })
  let handlers: Record<string, (input: unknown) => unknown>
  let routes: ReturnType<typeof validateRoutes>
  let loadError: unknown
  const loaded = (async () => {
    await initialized
    const mod = await importApplet()
    if (inspectionCallAttempted) throw new Error('Capabilities are unavailable during module inspection')
    routes = validateRoutes(mod.default)
    handlers = Object.fromEntries(routes.map(route => [route.key, mod.default[route.key]]))
  })().catch(error => {
    loadError = error
  })

  Deno.serve(async (req: Request) => {
    try {
      await loaded
      if (loadError) throw loadError
    } catch (error: any) {
      return Response.json({ code: 'invalid_applet_routes', message: String(error?.message || error) }, { status: 422 })
    }
    if (inspectOnly) {
      return Response.json({ routes: routes.map(route => route.key) })
    }
    const { socket: ws, response } = Deno.upgradeWebSocket(req)
    let state: ReturnType<typeof als.getStore>
    let finishLifetime: () => void
    EdgeRuntime.waitUntil(
      new Promise<void>(resolve => {
        finishLifetime = resolve
      })
    )
    function finish(outcome: Record<string, unknown>) {
      if (!state || state.finished) return
      state.finished = true
      clearTimeout(state.timer)
      for (const pending of state.pending.values()) {
        pending.reject(hostError({ status: 499, code: 'handler_cancelled', message: 'Applet invocation ended' }))
      }
      state.pending.clear()
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(json({ type: 'done', run_id: state.runId, outcome: { ...outcome, logs: state.logs } }))
        ws.close(1000)
      }
      finishLifetime()
    }
    ws.onclose = () => {
      finish(failure(499, 'handler_cancelled', 'Applet invocation ended'))
      finishLifetime()
    }
    ws.onmessage = (event: MessageEvent) => {
      let frame
      try {
        frame = JSON.parse(event.data)
      } catch {
        ws.close(1003, 'Invalid JSON')
        return
      }
      if (frame.type === 'reply' && state && !state.finished) {
        const pending = state.pending.get(frame.call_id)
        if (!pending) return
        state.pending.delete(frame.call_id)
        if (frame.error) pending.reject(hostError(frame.error))
        else pending.resolve(frame.value)
        return
      }
      if (frame.type === 'cancel' && state && frame.run_id === state.runId) {
        finish(failure(499, 'handler_cancelled', 'Applet invocation cancelled'))
        return
      }
      if (frame.type !== 'start' || state) return
      state = {
        ws,
        runId: frame.run_id,
        method: frame.context.method,
        logs: [],
        pending: new Map(),
        nextCall: 0,
        finished: false,
        timer: setTimeout(
          () => finish(failure(504, 'handler_timeout', 'Applet handler timed out')),
          Number(new URL(req.url).searchParams.get('timeout_ms')) || 60000
        )
      }
      als.run(state, async () => {
        const matched = matchRoute(routes, frame.context.method, frame.context.path)
        if (!matched.route) {
          const code =
            matched.status === 400
              ? 'invalid_request'
              : matched.status === 405
                ? 'method_not_allowed'
                : 'route_not_found'
          finish(failure(matched.status, code, 'Applet route not found'))
          return
        }
        try {
          const body = await handlers[matched.route.key]({ ...frame.context, params: matched.params })
          if (body === undefined) finish({ status: 204 })
          else {
            const encoded = json(body)
            if (encoded === undefined) throw new TypeError('handler result is not JSON serializable')
            if (new TextEncoder().encode(encoded).length > 1024 * 1024) {
              finish(failure(500, 'handler_output_limit', 'Applet handler output limit exceeded'))
            } else finish({ status: 200, body: JSON.parse(encoded) })
          }
        } catch (error: any) {
          if (errorInstances.has(error)) {
            finish({
              status: error.status,
              body: { error: { code: error.code, message: error.message, details: error.details } }
            })
          } else {
            finish({
              ...failure(500, 'handler_error', 'Applet handler failed'),
              debug: {
                message: String(error?.message || error).slice(0, 16384),
                stack: String(error?.stack || '').slice(0, 16384)
              }
            })
          }
        }
      })
    }
    return response
  })
}
