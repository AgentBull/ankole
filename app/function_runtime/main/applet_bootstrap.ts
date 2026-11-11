import { matchRoute, validateRoutes, validateActions } from './routes.ts'
import { withRecordIDs } from '@ankole/applet-sdk/records'
import type { RecordWrite } from '@ankole/applet-sdk/types'

type InvocationState = {
  ws: WebSocket
  runId: string
  method: string
  readOnly: boolean
  deadline: number
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
const validateActions = ${validateActions.toString()};
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
    retryable?: boolean
    request_sent?: boolean
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
  const hostError = (value: {
    status: number
    code: string
    message: string
    details?: unknown
    retryable?: boolean
    request_sent?: boolean
  }) =>
    Object.assign(new HttpError(value.status, value.code, value.message, value.details, trusted), {
      retryable: value.retryable,
      request_sent: value.request_sent
    })
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
    const capability = operation.replace(/^admin\./, '')
    if (
      state.readOnly &&
      [
        'base.write',
        'file.write',
        'state.set',
        'state.delete',
        'signals.emit',
        'ai.generateImage',
        'notifications.post',
        'approvals.request',
        'approvals.decide',
        'brain.writeTake'
      ].includes(capability)
    ) {
      throw hostError({ status: 500, code: 'read_only_route', message: 'GET routes cannot write data' })
    }
    const callId = ++state.nextCall
    const result: any = await new Promise((resolve, reject) => {
      state.pending.set(callId, { resolve, reject })
      state.ws.send(json({ type: 'call', run_id: state.runId, call_id: callId, operation, args }))
    })
    if (capability === 'file.read' && typeof result?.bytes?.__ankole_bytes === 'string') {
      result.bytes = new Uint8Array(Buffer.from(result.bytes.__ankole_bytes, 'base64'))
    }
    return result
  }
  function capabilities(prefix = '') {
    const invoke = (operation: string, args: unknown[]) => call(prefix + operation, args)
    return Object.freeze({
      base: Object.freeze({
        schema: (tableId: string) => invoke('base.schema', [tableId]),
        query: (tableId: string, query = {}) => invoke('base.query', [tableId, query]),
        aggregate: (tableId: string, query: unknown) => invoke('base.aggregate', [tableId, query]),
        write: (tableId: string, changes: RecordWrite) => invoke('base.write', [tableId, withRecordIDs(changes)])
      }),
      metrics: Object.freeze({
        query: (metric: string, options = {}) => invoke('metrics.query', [metric, options])
      }),
      brain: Object.freeze({
        listTakes: (options: unknown) => invoke('brain.listTakes', [options]),
        listFacts: (options: unknown) => invoke('brain.listFacts', [options]),
        writeTake: (options: unknown) => invoke('brain.writeTake', [options]),
        calibration: (options: unknown) => invoke('brain.calibration', [options])
      }),
      notifications: Object.freeze({
        post: (request: unknown) => invoke('notifications.post', [request])
      }),
      approvals: Object.freeze({
        request: (request: unknown) => invoke('approvals.request', [request]),
        get: (id: string) => invoke('approvals.get', [id]),
        list: () => invoke('approvals.list', []),
        ...(prefix === '' ? { decide: (request: unknown) => invoke('approvals.decide', [request]) } : {})
      }),
      file: Object.freeze({
        list: (pageId: string) => invoke('file.list', [pageId]),
        read: (path: string, options?: { sha256?: string }) =>
          invoke('file.read', options === undefined ? [path] : [path, options]),
        write: (pageId: string, file: { bytes: Uint8Array }) => {
          store()
          if (!(file.bytes instanceof Uint8Array)) throw new TypeError('file.write bytes must be Uint8Array')
          return invoke('file.write', [
            pageId,
            { ...file, bytes: { __ankole_bytes: Buffer.from(file.bytes).toString('base64') } }
          ])
        }
      }),
      ai: Object.freeze({
        generateText: (options: unknown) => invoke('ai.generateText', [options]),
        generateImage: (options: unknown) => invoke('ai.generateImage', [options]),
        decide: (options: unknown) => invoke('ai.decide', [options])
      }),
      web: Object.freeze({
        search: (options: unknown) => invoke('web.search', [options]),
        fetch: (options: unknown) => invoke('web.fetch', [options])
      }),
      mcp: Object.freeze({
        call: (tool: string, args: unknown = {}, options: unknown = {}) => invoke('mcp.call', [tool, args, options])
      }),
      signals: Object.freeze({
        call: (request: unknown) => invoke('signals.call', [request]),
        emit: (request: unknown) => invoke('signals.emit', [request]),
        run: (runId: number) => invoke('signals.run', [runId])
      })
    })
  }
  Object.defineProperty(globalThis, 'AnkoleRuntime', {
    value: Object.freeze({ HttpError, ...capabilities(), admin: capabilities('admin.') }),
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

  const failure = (status: number, code: string, message: string, extra?: Record<string, unknown>) => ({
    status,
    body: { error: { code, message, ...extra } }
  })
  let handlers: Record<string, (input: unknown) => unknown>
  let routes: ReturnType<typeof validateRoutes>
  let actions: Record<string, any>
  let policies: ReturnType<typeof validateActions>
  let loadError: unknown
  let structured = false
  const loaded = (async () => {
    await initialized
    const mod = await importApplet()
    if (inspectionCallAttempted) throw new Error('Capabilities are unavailable during module inspection')
    structured = mod.default && ('routes' in mod.default || 'actions' in mod.default)
    const routeHandlers = structured ? (mod.default.routes ?? {}) : mod.default
    routes = validateRoutes(routeHandlers)
    handlers = routeHandlers
    actions = structured ? (mod.default.actions ?? {}) : {}
    policies = validateActions(actions)
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
      const input = (await req.json()) as { contexts?: Record<string, any>[] }
      const keys: Record<string, string> = {}
      for (const context of input.contexts ?? []) {
        const action = actions[context.actionKey]
        if (!action) continue
        const key = action.concurrencyKey ? await action.concurrencyKey(context) : 'default'
        if (typeof key !== 'string' || key.length < 1 || key.length > 255) {
          return Response.json({ code: 'invalid_concurrency_key' }, { status: 422 })
        }
        keys[context.job.id] = key
      }
      return Response.json({ routes: routes.map(route => route.key), actions: policies, concurrencyKeys: keys })
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
        readOnly: frame.context.read_only === true || frame.context.method === 'GET',
        deadline: Date.now() + (Number(new URL(req.url).searchParams.get('timeout_ms')) || 60000),
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
        const continuations = new WeakMap<object, unknown>()
        function scope(scopeKey = 'default'): any {
          return Object.freeze({
            get: (key: string) => call('state.get', [scopeKey, key]),
            set: (key: string, value: unknown) => call('state.set', [scopeKey, key, value]),
            delete: (key: string) => call('state.delete', [scopeKey, key]),
            scope
          })
        }
        const context = Object.freeze({
          ...frame.context,
          remainingMs: () => Math.max(0, store().deadline - Date.now()),
          state: scope(),
          continueSlice: async (options: unknown = {}) => {
            const current = store()
            if (current.readOnly) throw new HttpError(400, 'read_only_route')
            if (!frame.context.canContinueSlice) throw new HttpError(400, 'action_attempt_required')
            const continuation = Object.freeze({})
            continuations.set(continuation, options)
            return continuation
          }
        })
        if (frame.context.actionKey) {
          try {
            const action = actions[frame.context.actionKey]
            if (!action) return finish(failure(422, 'missing_action_key', 'Action is not exported'))
            const result = await action.handler(context)
            const continuing = continuations.has(result as object)
            const encoded = json(continuing ? continuations.get(result as object) : (result ?? null))
            if (new TextEncoder().encode(encoded).length > 1024 * 1024) {
              return finish(failure(500, 'handler_output_limit', 'Action output limit exceeded'))
            }
            finish({ status: 200, [continuing ? 'continueSlice' : 'body']: JSON.parse(encoded) })
          } catch (error: any) {
            finish(
              failure(
                errorInstances.has(error) ? error.status : 500,
                errorInstances.has(error) ? error.code : 'handler_error',
                String(error?.message ?? error),
                errorInstances.has(error)
                  ? { details: error.details, retryable: error.retryable, request_sent: error.request_sent }
                  : undefined
              )
            )
          }
          return
        }
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
          const body = await (handlers[matched.route.key] as any)({ ...context, params: matched.params }, context)
          if (body === undefined) finish({ status: 204 })
          else {
            const encoded = json(body)
            if (encoded === undefined) throw new TypeError('handler result is not JSON serializable')
            if (new TextEncoder().encode(encoded).length > 1024 * 1024) {
              finish(failure(500, 'handler_output_limit', 'Applet handler output limit exceeded'))
            } else {
              const value = JSON.parse(encoded)
              finish(
                structured && typeof value?.status === 'number' && 'body' in value
                  ? { status: value.status, body: value.body }
                  : { status: 200, body: value }
              )
            }
          }
        } catch (error: any) {
          if (errorInstances.has(error)) {
            finish({
              status: error.status,
              body: {
                error: {
                  code: error.code,
                  message: error.message,
                  details: error.details,
                  retryable: error.retryable,
                  request_sent: error.request_sent
                }
              }
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
