import { parse } from 'acorn'
import { buildAppletWorkerBootstrap } from './applet_bootstrap.ts'
import { CodeCache, type AppletCode } from './code_cache.ts'
import { buildPtcRunnerModule, type ProgramRequest } from './ptc_bootstrap.ts'

const token = Deno.env.get('ANKOLE_FUNCTION_RUNTIME_TOKEN')
if (!token) throw new Error('ANKOLE_FUNCTION_RUNTIME_TOKEN is required')
const capacity = Number(Deno.env.get('ANKOLE_FUNCTION_RUNTIME_MAX_CONCURRENCY') || 32)
const codeCache = new CodeCache()
let active = 0
const invocations = new Map<
  string,
  {
    code: AppletCode
    release: (aborted?: boolean) => Promise<void>
    started: boolean
    worker?: ReturnType<typeof worker>
  }
>()
let draining = false
addEventListener('drain', () => {
  draining = true
})
addEventListener('beforeunload', () => {
  draining = true
})

const json = (status: number, code: string, message = code) => Response.json({ code, message }, { status })
const noPermissions = {
  allow_all: false,
  allow_net: null,
  allow_read: null,
  allow_write: null,
  allow_env: null,
  allow_run: null,
  allow_ffi: null,
  allow_sys: null,
  allow_import: null
}

async function body(req: Request): Promise<Record<string, any>> {
  const value = await req.json()
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new TypeError('Expected a JSON object')
  return value as Record<string, any>
}

async function codeDigest(code: AppletCode) {
  const entries = Object.entries(code.env).sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0))
  const digest = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(`${code.source}\n${JSON.stringify(entries)}`)
  )
  return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('')
}

function codePayload(value: Record<string, any>): AppletCode {
  if (
    typeof value.source !== 'string' ||
    !value.env ||
    typeof value.env !== 'object' ||
    Array.isArray(value.env) ||
    Object.values(value.env).some(entry => typeof entry !== 'string') ||
    new TextEncoder().encode(JSON.stringify(value.env)).length > 64 * 1024
  ) {
    throw new TypeError('Expected source and a flat string environment of at most 64 KiB')
  }
  return { source: value.source, env: value.env }
}

async function worker(service: string, runId: string, module: string, options: Record<string, unknown>) {
  return await EdgeRuntime.userWorkers.create({
    servicePath: `/tmp/ankole-workers/${service}/${runId}`,
    maybeModuleCode: module,
    envVars: [],
    noModuleCache: false,
    noNpm: true,
    allowRemoteModules: false,
    permissions: noPermissions,
    ...options
  })
}

function forward(req: Request) {
  const headers = new Headers(req.headers)
  headers.delete('authorization')
  headers.delete('content-length')
  const forwarded = new Request(req.url, { method: req.method, headers })
  EdgeRuntime.applySupabaseTag(req, forwarded)
  return forwarded
}

async function fetchOneShot(instance: Awaited<ReturnType<typeof worker>>, req: Request) {
  const response = await instance.fetch(forward(req), { signal: req.signal })
  const bytes = await response.arrayBuffer()
  return new Response(bytes, { status: response.status, headers: response.headers })
}

Deno.serve(async (req: Request) => {
  const url = new URL(req.url)
  if (url.pathname === '/_internal/health') {
    return json(draining ? 503 : 200, draining ? 'draining' : 'ok')
  }
  if (!url.pathname.startsWith('/v1/')) return json(404, 'not_found')
  if (req.headers.get('authorization') !== `Bearer ${token}`) return json(401, 'unauthorized')
  try {
    const cacheMatch = /^\/v1\/applet\/code\/([a-f0-9]{64})$/.exec(url.pathname)
    if (req.method === 'PUT' && cacheMatch) {
      const code = codePayload(await body(req))
      if ((await codeDigest(code)) !== cacheMatch[1]) return json(422, 'applet_code_digest_mismatch')
      codeCache.put(cacheMatch[1], code)
      return new Response(null, { status: 204 })
    }
    const settle = /^\/v1\/applet\/invocations\/([^/]+)$/.exec(url.pathname)
    if (req.method === 'DELETE' && settle) {
      const invocation = invocations.get(settle[1])
      await invocation?.release(url.searchParams.get('aborted') === '1')
      return new Response(null, { status: 204 })
    }
    if (url.pathname !== '/v1/applet/invoke' && (draining || active >= capacity)) return json(503, 'runtime_busy')
    if (req.method === 'POST' && url.pathname === '/v1/applet/inspect') {
      const payload = await body(req)
      if (typeof payload.source !== 'string') return json(400, 'invalid_request')
      const env = codePayload({ source: payload.source, env: payload.env || {} }).env
      active++
      try {
        const instance = await worker(
          'inspect',
          crypto.randomUUID(),
          buildAppletWorkerBootstrap(payload.source, true),
          {
            forceCreate: true,
            context: { supervisor: { requestAbsentTimeoutMs: 0 } },
            envVars: Object.entries(env),
            permissions: { ...noPermissions, allow_read: ['/tmp'], allow_write: ['/tmp'], allow_env: [] },
            memoryLimitMb: payload.memory_mb || 64,
            workerTimeoutMs: payload.timeout_ms || 5000,
            cpuTimeSoftLimitMs: payload.timeout_ms || 5000,
            cpuTimeHardLimitMs: payload.timeout_ms || 5000
          }
        )
        return await fetchOneShot(instance, req)
      } catch (error: any) {
        return json(422, 'invalid_applet_routes', String(error?.message || error))
      } finally {
        active--
      }
    }
    if (req.method === 'POST' && url.pathname === '/v1/program/run') {
      const payload = (await body(req)) as ProgramRequest
      if (
        typeof payload.program !== 'string' ||
        (payload.tools !== undefined && !Array.isArray(payload.tools)) ||
        (payload.memo !== undefined && !Array.isArray(payload.memo))
      ) {
        return json(400, 'invalid_program_request')
      }
      const sourceFailure = validateProgramSource(payload)
      if (sourceFailure) return Response.json(sourceFailure)
      active++
      try {
        const timeout = payload.timeout_ms ?? 30000
        const instance = await worker('ptc', crypto.randomUUID(), buildPtcRunnerModule(payload), {
          forceCreate: true,
          context: { supervisor: { requestAbsentTimeoutMs: 0 } },
          memoryLimitMb: 256,
          workerTimeoutMs: timeout,
          cpuTimeSoftLimitMs: timeout,
          cpuTimeHardLimitMs: timeout
        })
        const response = await fetchOneShot(instance, req)
        if (response.status !== 200) {
          return Response.json(programFailure('program_execution_failed', 'Program worker failed'))
        }
        return response
      } catch (error: any) {
        return Response.json(
          programFailure(
            error instanceof Deno.errors.WorkerMemoryLimitExceeded
              ? 'program_heap_limit_exceeded'
              : error instanceof Deno.errors.WorkerRequestCancelled
                ? 'program_timeout'
                : 'program_execution_failed',
            String(error?.message || error)
          )
        )
      } finally {
        active--
      }
    }
    if (req.method === 'GET' && url.pathname === '/v1/applet/invoke') {
      const runId = url.searchParams.get('run_id')
      const tenant = url.searchParams.get('tenant_id')
      const page = url.searchParams.get('page_id')
      const revision = url.searchParams.get('revision')
      if (!runId || !tenant || !page || !revision) return json(400, 'invalid_request')
      const timeout = Number(url.searchParams.get('timeout_ms')) || 60000
      const poolKey = `${tenant}:${page}:${revision}`
      let lease = invocations.get(runId)
      if (!lease) {
        if (draining || active >= capacity) return json(503, 'runtime_busy')
        const code = codeCache.get(url.searchParams.get('sha256') || '')
        if (!code) return json(428, 'applet_code_missing')
        active++
        let settlement: Promise<void> | undefined
        const release = (aborted = false) => {
          return (settlement ??= (async () => {
            active--
            clearTimeout(timer)
            if (aborted && lease?.worker) await (await lease.worker).retire()
          })().finally(() => invocations.delete(runId)))
        }
        const timer = setTimeout(() => {
          void release(true).catch(error => console.error('Applet worker retirement failed', error))
        }, timeout + 500)
        lease = { code, release, started: false }
        invocations.set(runId, lease)
      }
      if (req.headers.get('upgrade')?.toLowerCase() !== 'websocket') return new Response(null, { status: 204 })
      if (lease.started) return json(409, 'invocation_already_started')
      lease.started = true
      const { code, release } = lease
      let instance: Awaited<ReturnType<typeof worker>> | undefined
      try {
        lease.worker = worker('applet', poolKey, buildAppletWorkerBootstrap(code.source), {
          poolKey,
          envVars: Object.entries(code.env),
          memoryLimitMb: Number(url.searchParams.get('memory_mb')) || 128,
          workerTimeoutMs: 300000,
          cpuTimeSoftLimitMs: Math.min(timeout, 10000),
          cpuTimeHardLimitMs: Math.min(timeout, 15000),
          permissions: { ...noPermissions, allow_net: [], allow_read: ['/tmp'], allow_write: ['/tmp'], allow_env: [] }
        })
        instance = await lease.worker
        const response = await instance.fetch(forward(req))
        if (response.status !== 101) {
          await release(true)
        }
        return response
      } catch (error: any) {
        if (!instance) lease.worker = undefined
        await release(true)
        return json(500, 'handler_error', String(error?.message || error))
      }
    }
    return json(404, 'not_found')
  } catch (error: any) {
    return json(error instanceof RangeError ? 413 : 400, 'invalid_request', String(error?.message || error))
  }
})

function programFailure(code: string, message: string) {
  return { status: 'failed', output: [], pending_calls: [], error_code: code, error: message }
}

function validateProgramSource(payload: ProgramRequest) {
  if (new TextEncoder().encode(payload.program).length > 256 * 1024) {
    return programFailure('program_source_limit_exceeded', 'program source exceeded the byte limit')
  }
  try {
    const nodes: any[] = [
      parse(payload.program, {
        ecmaVersion: 'latest',
        allowAwaitOutsideFunction: true,
        allowReturnOutsideFunction: true
      })
    ]
    while (nodes.length) {
      const node = nodes.pop()
      if (node.type === 'ImportExpression') throw new SyntaxError('Module imports are unavailable in programs')
      for (const value of Object.values(node) as any[]) {
        if (Array.isArray(value)) nodes.push(...value.filter(item => item && typeof item.type === 'string'))
        else if (value && typeof value === 'object' && typeof value.type === 'string') nodes.push(value)
      }
    }
  } catch (error: any) {
    return programFailure('program_execution_failed', String(error?.message || error))
  }
}
