import type { DirectoryBackupRecord } from '@cloudflare/sandbox'
import type { RegistryEntry } from './registry'
import {
  authorized,
  type Contract,
  type DeleteRequest,
  type Instance,
  type Result,
  type StorageObservation,
  type WorkerObject
} from './types'

export interface WorkerApi {
  create(input: Contract): Promise<Result<WorkerObject>>
  remove(providerId: string, generation: string, request: DeleteRequest): Promise<Result<void>>
  state(providerId: string): Promise<Result<WorkerObject | null>>
  images(): Promise<Result<string[]>>
  restore(authorization: string | null): Promise<Result<void>>
  backup(authorization: string | null): Promise<Result<DirectoryBackupRecord>>
  storageRef(providerId: string): Promise<Result<StorageObservation>>
  deleteStorage(agentUid: string, providerId: string): Promise<Result<void>>
}

export interface Backend {
  token: string
  worker(agentUid: string): WorkerApi
  list(providerId: string): Promise<RegistryEntry[]>
}

class BadRequest extends Error {}

export async function handle(request: Request, backend: Backend): Promise<Response> {
  const url = new URL(request.url)
  const path = url.pathname.split('/').filter(Boolean).map(decodeURIComponent)
  try {
    // Only these two routes use the generation credential. The DO verifies it
    // against its own contract; the entrypoint never receives the adapter key.
    if (request.method === 'POST' && path.length === 4 && path[0] === 'agents' && path[2] === 'storage') {
      const worker = backend.worker(agentUid(path[1]!))
      const authorization = request.headers.get('authorization')
      if (path[3] === 'restore') return reply(await worker.restore(authorization), () => json(200, { restored: true }))
      if (path[3] === 'backup') {
        return reply(await worker.backup(authorization), record => json(200, { storage_ref: record }))
      }
    }
    if (!authorized(request.headers.get('authorization'), backend.token)) {
      return json(401, { error: 'unauthorized', message: 'a valid adapter credential is required' })
    }
    if (request.method === 'GET' && path.length === 1 && path[0] === 'health') {
      return reply(await backend.worker('_images').images(), images => json(200, { images }))
    }
    if (request.method === 'GET' && path.length === 1 && path[0] === 'workers') {
      const providerId = query(url, 'provider_id')
      const entries = await backend.list(providerId)
      const workers: WorkerObject[] = []
      for (const entry of entries) {
        const state = await backend.worker(entry.agent_uid).state(providerId)
        // A failed observation must never become an empty list of instances.
        if (!state.ok) return failure(state)
        if (state.value) workers.push(state.value)
      }
      return json(200, { workers })
    }
    if (path.length === 3 && path[0] === 'agents') {
      const uid = agentUid(path[1]!)
      const worker = backend.worker(uid)
      if (path[2] === 'storage') {
        const providerId = query(url, 'provider_id')
        if (request.method === 'GET') {
          return reply(await worker.storageRef(providerId), observation => json(200, observation))
        }
        if (request.method === 'DELETE') {
          return reply(await worker.deleteStorage(uid, providerId), () => json(200, { deleted: true }))
        }
      }
      if (path[2] === 'worker') {
        if (request.method === 'GET') {
          return reply(await worker.state(query(url, 'provider_id')), state =>
            state ? json(200, state) : json(404, { error: 'worker_not_found', message: 'no instance' })
          )
        }
        if (request.method === 'PUT') {
          const body = await objectBody(request)
          const contract: Contract = {
            agentUid: uid,
            providerId: text(body, 'provider_id'),
            generation: text(body, 'generation'),
            image: text(body, 'image'),
            env: stringMap(body.env),
            instance: instance(body.instance),
            storageRef: backupRecord(body.storage_ref)
          }
          return reply(await worker.create(contract), state => json(201, state))
        }
        if (request.method === 'DELETE') {
          const body = await objectBody(request)
          if (body.mode !== 'now' && body.mode !== 'graceful') throw new BadRequest('mode must be graceful or now')
          if (!Number.isInteger(body.grace_seconds) || (body.grace_seconds as number) <= 0) {
            throw new BadRequest('grace_seconds must be a positive integer')
          }
          return reply(
            await worker.remove(text(body, 'provider_id'), text(body, 'generation'), {
              mode: body.mode,
              graceSeconds: body.grace_seconds as number
            }),
            () => json(202, { accepted: true })
          )
        }
      }
    }
    return json(404, { error: 'not_found', message: 'unknown adapter route' })
  } catch (error) {
    if (error instanceof BadRequest) return json(400, { error: 'bad_request', message: error.message })
    throw error
  }
}

function reply<T>(result: Result<T>, ok: (value: T) => Response): Response {
  return result.ok ? ok(result.value) : failure(result)
}
function failure(result: { status: number; code: string; message: string }): Response {
  return json(result.status, { error: result.code, message: result.message })
}
function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })
}
function query(url: URL, name: string): string {
  const value = url.searchParams.get(name)
  if (!value) throw new BadRequest(`${name} is required`)
  return value
}
function agentUid(value: string): string {
  if (!/^[a-z0-9][a-z0-9._-]{0,95}$/.test(value)) throw new BadRequest('invalid Agent UID')
  return value
}
function text(body: Record<string, unknown>, key: string): string {
  const value = body[key]
  if (typeof value !== 'string' || !value) throw new BadRequest(`${key} must be a non-empty string`)
  return value
}
async function objectBody(request: Request): Promise<Record<string, unknown>> {
  let body: unknown
  try {
    body = await request.json()
  } catch {
    throw new BadRequest('the body must be a JSON object')
  }
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new BadRequest('the body must be a JSON object')
  return body as Record<string, unknown>
}
function stringMap(value: unknown): Record<string, string> {
  if (
    !value ||
    typeof value !== 'object' ||
    Array.isArray(value) ||
    Object.values(value).some(item => typeof item !== 'string')
  ) {
    throw new BadRequest('env must be a mapping of strings')
  }
  return value as Record<string, string>
}
function instance(value: unknown): Instance {
  if (typeof value === 'string' && value) return value
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    const size = value as Record<string, unknown>
    const keys = ['diskMb', 'memoryMib', 'vcpu']
    if (
      Object.keys(size).sort().join() === keys.join() &&
      keys.every(key => typeof size[key] === 'number' && (size[key] as number) > 0)
    ) {
      return size as Instance
    }
  }
  throw new BadRequest('instance must be a name or { vcpu, memoryMib, diskMb }')
}
function backupRecord(value: unknown): DirectoryBackupRecord | null {
  if (value === null) return null
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    const record = value as Record<string, unknown>
    if (
      record.format === 'tar+zstd/1' &&
      typeof record.id === 'string' &&
      record.dir === '/workspace' &&
      typeof record.size === 'number' &&
      typeof record.sha256 === 'string'
    ) {
      return record as unknown as DirectoryBackupRecord
    }
  }
  throw new BadRequest('storage_ref must be a DirectoryBackupRecord or null')
}
