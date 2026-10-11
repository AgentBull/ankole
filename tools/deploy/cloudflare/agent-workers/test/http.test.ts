import { describe, expect, it } from 'bun:test'
import { handle, type Backend, type WorkerApi } from '../src/http'
import type { Result, WorkerObject } from '../src/types'
import { backupRecord } from './fakes'

const body = async (response: Response): Promise<Record<string, unknown>> => response.json()
const token = 'adapter-token'
const provider = 'cf-one'
const object: WorkerObject = {
  agent_uid: 'agent-1',
  generation: 'gen1',
  phase: 'running',
  reason: null,
  started_at: '2026-10-07T00:00:00.000Z'
}
const ok = <T>(value: T): Promise<Result<T>> => Promise.resolve({ ok: true, value })
function backend(overrides: Partial<WorkerApi> = {}) {
  const calls: Array<[string, unknown[]]> = []
  const worker: WorkerApi = {
    create: (...args) => (calls.push(['create', args]), ok(object)),
    remove: (...args) => (calls.push(['remove', args]), ok(undefined)),
    state: (...args) => (calls.push(['state', args]), ok<WorkerObject | null>(object)),
    images: () => ok(['worker-a']),
    restore: (...args) => (calls.push(['restore', args]), ok(undefined)),
    backup: (...args) => (calls.push(['backup', args]), ok(backupRecord)),
    storageRef: (...args) => (
      calls.push(['storageRef', args]),
      ok({ storage_ref: backupRecord, reason: 'backup failed: R2 unavailable' })
    ),
    deleteStorage: (...args) => (calls.push(['deleteStorage', args]), ok(undefined)),
    ...overrides
  }
  const api: Backend = {
    token,
    worker: () => worker,
    list: async providerId => {
      calls.push(['list', [providerId]])
      return [{ agent_uid: 'agent-1', provider_id: provider }]
    }
  }
  return { api, calls }
}
function request(method: string, path: string, body?: unknown, auth = `Bearer ${token}`): Request {
  return new Request(`https://adapter.example${path}`, {
    method,
    headers: { authorization: auth, 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
  })
}
const createBody = {
  provider_id: provider,
  generation: 'gen1',
  image: 'worker-a',
  env: { WORKER_ID: 'agent-1' },
  instance: 'standard-3',
  storage_ref: backupRecord
}

describe('adapter HTTP API', () => {
  it('requires the adapter token for control-plane requests', async () => {
    const { api } = backend()
    for (const auth of ['Bearer wrong', '', 'Bearer worker-token']) {
      expect((await handle(request('GET', '/health', undefined, auth), api)).status).toBe(401)
    }
  })

  it('reports deployed images', async () => {
    const { api } = backend()
    expect(await body(await handle(request('GET', '/health'), api))).toEqual({ images: ['worker-a'] })
  })

  it('creates and deletes an instance without deleting its storage', async () => {
    const { api, calls } = backend()
    expect((await handle(request('PUT', '/agents/agent-1/worker', createBody), api)).status).toBe(201)
    expect(
      (
        await handle(
          request('DELETE', '/agents/agent-1/worker', {
            provider_id: provider,
            generation: 'gen1',
            mode: 'graceful',
            grace_seconds: 300
          }),
          api
        )
      ).status
    ).toBe(202)
    expect(calls).toEqual([
      [
        'create',
        [
          {
            providerId: provider,
            agentUid: 'agent-1',
            generation: 'gen1',
            image: 'worker-a',
            env: createBody.env,
            instance: 'standard-3',
            storageRef: backupRecord
          }
        ]
      ],
      ['remove', [provider, 'gen1', { mode: 'graceful', graceSeconds: 300 }]]
    ])
  })

  it('rejects malformed requests and passes platform errors through', async () => {
    const { api } = backend({
      create: () => Promise.resolve({ ok: false, status: 409, code: 'generation_conflict', message: 'gen0' })
    })
    for (const invalid of [
      { generation: '' },
      { storage_ref: {} },
      { provider_id: '' },
      { instance: { vcpu: 1, memoryMib: 4096 } }
    ]) {
      expect((await handle(request('PUT', '/agents/agent-1/worker', { ...createBody, ...invalid }), api)).status).toBe(
        400
      )
    }
    expect((await handle(request('DELETE', '/agents/agent-1/worker'), api)).status).toBe(400)
    const conflict = await handle(request('PUT', '/agents/agent-1/worker', createBody), api)
    expect(conflict.status).toBe(409)
    expect(await body(conflict)).toEqual({ error: 'generation_conflict', message: 'gen0' })
  })

  it('requires provider scope for observations and keeps absent Agents in the registry', async () => {
    const { api, calls } = backend({ state: () => ok<WorkerObject | null>(null) })
    expect((await handle(request('GET', '/workers'), api)).status).toBe(400)
    expect((await handle(request('GET', '/agents/agent-1/worker'), api)).status).toBe(400)
    expect(await body(await handle(request('GET', `/workers?provider_id=${provider}`), api))).toEqual({ workers: [] })
    expect(calls).toEqual([['list', [provider]]])
    expect((await handle(request('GET', `/agents/agent-1/worker?provider_id=${provider}`), api)).status).toBe(404)
  })

  it('does not turn an observation failure into an empty list', async () => {
    const { api, calls } = backend()
    expect(await body(await handle(request('GET', `/workers?provider_id=${provider}`), api))).toEqual({
      workers: [object]
    })
    expect(calls).toEqual([
      ['list', [provider]],
      ['state', [provider]]
    ])
    const failed = backend({
      state: async () => ({ ok: false, status: 503, code: 'unavailable', message: 'DO unavailable' })
    })
    const response = await handle(request('GET', `/workers?provider_id=${provider}`), failed.api)
    expect(response.status).toBe(503)
    expect(await body(response)).toEqual({ error: 'unavailable', message: 'DO unavailable' })
  })

  it('routes entrypoint credentials to the owning DO and reports its rejection', async () => {
    const { api, calls } = backend()
    expect(
      (await handle(request('POST', '/agents/agent-1/storage/restore', undefined, 'Bearer worker-token'), api)).status
    ).toBe(200)
    const saved = await handle(request('POST', '/agents/agent-1/storage/backup', undefined, 'Bearer worker-token'), api)
    expect(await body(saved)).toEqual({ storage_ref: backupRecord })
    expect(calls).toEqual([
      ['restore', ['Bearer worker-token']],
      ['backup', ['Bearer worker-token']]
    ])
    const rejected = backend({
      restore: async () => ({ ok: false, status: 401, code: 'unauthorized', message: 'wrong generation' })
    })
    expect(
      (await handle(request('POST', '/agents/agent-1/storage/restore', undefined, 'Bearer old'), rejected.api)).status
    ).toBe(401)
  })

  it('reads the retained storage pointer and separately deletes Agent storage', async () => {
    const { api, calls } = backend()
    const path = `/agents/agent-1/storage?provider_id=${provider}`
    expect(await body(await handle(request('GET', path), api))).toEqual({
      storage_ref: backupRecord,
      reason: 'backup failed: R2 unavailable'
    })
    expect((await handle(request('DELETE', path), api)).status).toBe(200)
    expect(calls).toEqual([
      ['storageRef', [provider]],
      ['deleteStorage', ['agent-1', provider]]
    ])
  })
})
