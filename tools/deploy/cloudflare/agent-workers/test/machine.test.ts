import { describe, expect, it } from 'bun:test'
import { WorkerMachine } from '../src/machine'
import type { Contract } from '../src/types'
import { backupRecord, FakeBackups, FakeContainer, FakeRegistry, FakeStorage } from './fakes'

const authorization = 'Bearer worker-secret'
const input: Contract = {
  providerId: 'cf-one',
  agentUid: 'agent-1',
  generation: 'gen1',
  image: 'worker-a',
  env: {
    WORKER_ID: 'agent-1',
    ANKOLE_WORKER_TENANT_ID: 'tenant-1',
    ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY: 'worker-secret'
  },
  instance: 'standard-3',
  storageRef: null
}
function machine() {
  const storage = new FakeStorage()
  const container = new FakeContainer()
  const registry = new FakeRegistry()
  const backups = new FakeBackups()
  const now = { time: Date.parse('2026-10-07T00:00:00Z') }
  const worker = new WorkerMachine({ storage, container, registry, backups, now: () => new Date(now.time) })
  return { worker, storage, container, registry, backups, now }
}
async function settleExit(worker: WorkerMachine) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    if ((await worker.state(input.providerId)) === null) return
    await new Promise(resolve => setTimeout(resolve, 0))
  }
  throw new Error('instance did not disappear')
}
/** Gives a request that does not wait in a queue the time to start. */
async function tick() {
  for (let attempt = 0; attempt < 5; attempt += 1) await new Promise(resolve => setTimeout(resolve, 0))
}

describe('WorkerMachine directory storage contract (WP 3.4)', () => {
  it('starts from the image, registers its provider, and becomes running only after restore', async () => {
    const { worker, container, registry, backups } = machine()
    expect(await worker.create({ ...input, agentUid: 'tenant-1-agent-1' })).toMatchObject({
      tenant_id: 'tenant-1',
      agent_uid: 'agent-1',
      phase: 'starting',
      started_at: '2026-10-07T00:00:00.000Z'
    })
    expect(container.starts).toEqual([
      { image: container.images['worker-a'], enableInternet: true, env: input.env, instance: 'standard-3' }
    ])
    expect(registry.entries.get('tenant-1-agent-1')).toBe('cf-one')
    await worker.restore(authorization)
    expect(await worker.state('cf-one')).toMatchObject({ phase: 'running' })
    expect(backups.restores).toEqual([])
    expect(backups.removals).toEqual([['tenant-1-agent-1', null]])
  })

  it('restores only the committed pointer and removes other backups afterwards', async () => {
    const { worker, storage, backups } = machine()
    await storage.put('backup', { ...backupRecord, id: 'uncommitted' })
    await worker.create({ ...input, storageRef: backupRecord })
    await worker.restore(authorization)
    expect(backups.restores).toEqual([['agent-1', backupRecord]])
    expect(backups.removals).toEqual([['agent-1', backupRecord]])
    expect((await worker.storageRef('cf-one')).storage_ref).toEqual(backupRecord)
  })

  it('restores again when a container restart in the same generation replaces the disk', async () => {
    const { worker, backups } = machine()
    await worker.create({ ...input, storageRef: backupRecord })
    await worker.restore(authorization)
    expect(await worker.state('cf-one')).toMatchObject({ phase: 'running' })

    // The new disk has no restore marker, so its entrypoint asks again.
    const finish = Promise.withResolvers<void>()
    backups.restore = async (uid, record) => {
      backups.restores.push([uid, record])
      await finish.promise
    }
    const restoring = worker.restore(authorization)
    await tick()
    expect(backups.restores).toEqual([
      ['agent-1', backupRecord],
      ['agent-1', backupRecord]
    ])
    expect(await worker.state('cf-one')).toMatchObject({ generation: 'gen1', phase: 'starting' })
    finish.resolve()
    await restoring
    expect(await worker.state('cf-one')).toMatchObject({ generation: 'gen1', phase: 'running' })
  })

  it('restores the latest backup of the generation after a restart and keeps only that record', async () => {
    const { worker, backups } = machine()
    const latest = { ...backupRecord, id: '019a7e50-0361-7bc0-8ef1-000000000002' }
    const next = { ...backupRecord, id: '019a7e50-0361-7bc0-8ef1-000000000003' }
    await worker.create({ ...input, storageRef: backupRecord })
    await worker.restore(authorization)
    backups.backup = async () => latest
    expect(await worker.backup(authorization)).toEqual(latest)

    // The committed pointer is older than this generation's backup.
    await worker.restore(authorization)
    expect(backups.restores.at(-1)).toEqual(['agent-1', latest])
    expect(backups.removals.at(-1)).toEqual(['agent-1', latest])

    // The restored Home changes after the restart, so the next backup is new.
    backups.backup = async () => next
    expect(await worker.backup(authorization)).toEqual(next)
    expect((await worker.storageRef('cf-one')).storage_ref).toEqual(next)
  })

  it('does not share a running restore with a later request', async () => {
    const { worker, backups } = machine()
    const started = Promise.withResolvers<void>()
    const finish = Promise.withResolvers<void>()
    let restores = 0
    backups.restore = async () => {
      restores += 1
      started.resolve()
      await finish.promise
    }
    await worker.create({ ...input, storageRef: backupRecord })
    const first = worker.restore(authorization)
    await started.promise
    // The first request can come from a disk that a restart removed.
    const second = worker.restore(authorization)
    await tick()
    expect(restores).toBe(1)
    finish.resolve()
    await Promise.all([first, second])
    expect(restores).toBe(2)
  })

  it('restores the record of a backup that is running when the restore is requested', async () => {
    const { worker, backups } = machine()
    const latest = { ...backupRecord, id: '019a7e50-0361-7bc0-8ef1-000000000002' }
    const started = Promise.withResolvers<void>()
    const finish = Promise.withResolvers<typeof latest>()
    await worker.create({ ...input, storageRef: backupRecord })
    await worker.restore(authorization)
    backups.backup = () => {
      started.resolve()
      return finish.promise
    }
    const saving = worker.backup(authorization)
    await started.promise
    const restoring = worker.restore(authorization)
    await tick()
    expect(backups.restores).toEqual([['agent-1', backupRecord]])
    finish.resolve(latest)
    await Promise.all([saving, restoring])
    expect(backups.restores.at(-1)).toEqual(['agent-1', latest])
    expect(backups.removals.at(-1)).toEqual(['agent-1', latest])
  })

  it('preserves the pointer and reports the reason after a failed restore', async () => {
    const { worker, backups } = machine()
    backups.restore = async () => {
      throw new Error('checksum mismatch')
    }
    await worker.create({ ...input, storageRef: backupRecord })
    await expect(worker.restore(authorization)).rejects.toThrow('checksum mismatch')
    expect(await worker.state('cf-one')).toMatchObject({
      phase: 'starting',
      reason: 'restore failed: checksum mismatch'
    })
    expect((await worker.storageRef('cf-one')).storage_ref).toEqual(backupRecord)
    expect(backups.backups).toEqual([])
    expect(backups.removals).toEqual([])
  })

  for (const [mode, signal] of [
    ['graceful', 15],
    ['now', 10]
  ] as const) {
    it(`${mode} signals the entrypoint and retains its completed backup after instance deletion`, async () => {
      const { worker, container, backups, registry } = machine()
      await worker.create(input)
      await worker.restore(authorization)
      await worker.remove('cf-one', 'gen1', { mode, graceSeconds: 300 })
      expect(container.signals).toEqual([signal])
      expect(container.running).toBe(true)
      expect(backups.backups).toEqual([])
      expect(await worker.state('cf-one')).toMatchObject({ phase: 'terminating' })
      // The Linux entrypoint owns stopping writers before it calls this API.
      expect(await worker.backup(authorization)).toEqual(backupRecord)
      container.exit()
      await settleExit(worker)
      expect((await worker.storageRef('cf-one')).storage_ref).toEqual(backupRecord)
      expect(registry.entries.get('agent-1')).toBe('cf-one')
      expect(container.destroyed).toBe(1)
    })
  }

  it('retains the previous pointer and backup error after the container disappears', async () => {
    const { worker, backups, container } = machine()
    const previous = { ...backupRecord, id: 'previous' }
    await worker.create({ ...input, storageRef: previous })
    await worker.restore(authorization)
    backups.backup = async () => {
      throw new Error('R2 unavailable')
    }
    await expect(worker.backup(authorization)).rejects.toThrow('R2 unavailable')
    expect(await worker.state('cf-one')).toMatchObject({ reason: 'backup failed: R2 unavailable' })
    container.exit()
    await settleExit(worker)
    expect(await worker.storageRef('cf-one')).toEqual({
      storage_ref: previous,
      reason: 'backup failed: R2 unavailable'
    })
  })

  it('keeps a generation present until its pending backup settles, even after container exit', async () => {
    const { worker, container, backups } = machine()
    const started = Promise.withResolvers<void>()
    const finish = Promise.withResolvers<typeof backupRecord>()
    backups.backup = () => {
      started.resolve()
      return finish.promise
    }
    await worker.create(input)
    await worker.restore(authorization)
    const saving = worker.backup(authorization)
    await started.promise
    container.exit()
    await expect(worker.create({ ...input, generation: 'gen2' })).rejects.toMatchObject({ code: 'generation_conflict' })
    expect(await worker.state('cf-one')).toMatchObject({ phase: 'terminating' })
    finish.resolve(backupRecord)
    await saving
    await settleExit(worker)
    await worker.create({ ...input, generation: 'gen2', storageRef: backupRecord })
    expect((await worker.storageRef('cf-one')).storage_ref).toEqual(backupRecord)
  })

  it('waits for a delayed platform destroy before a replacement can start', async () => {
    const { worker, container } = machine()
    const started = Promise.withResolvers<void>()
    const finish = Promise.withResolvers<void>()
    const destroy = container.destroy.bind(container)
    container.destroy = async () => {
      started.resolve()
      await finish.promise
      await destroy()
    }
    await worker.create(input)
    container.exit()
    await started.promise
    const replacement = worker.create({ ...input, generation: 'gen2' })
    expect(await worker.state('cf-one')).toMatchObject({ phase: 'terminating' })
    expect(container.starts).toHaveLength(1)
    finish.resolve()
    await replacement
    expect(container.starts).toHaveLength(2)
    expect(container.running).toBe(true)
    expect(await worker.state('cf-one')).toMatchObject({ generation: 'gen2', reason: null })
  })

  it('retains a deletion deadline across retries, and retries an alarm after a platform error', async () => {
    const { worker, storage, container, now } = machine()
    await worker.create(input)
    await worker.remove('cf-one', 'gen1', { mode: 'graceful', graceSeconds: 3 })
    const pending = await storage.get<{ mode: string; deadline: number; graceSeconds: number }>('deleting')
    now.time += 2000
    await worker.remove('cf-one', 'gen1', { mode: 'graceful', graceSeconds: 60 })
    expect(await storage.get<typeof pending>('deleting')).toEqual(pending)
    await worker.runDelete()
    expect(container.destroyed).toBe(0)
    now.time += 1000
    const destroy = container.destroy.bind(container)
    container.destroy = async () => {
      throw new Error('platform unavailable')
    }
    await expect(worker.runDelete()).rejects.toThrow('platform unavailable')
    expect(await worker.state('cf-one')).toMatchObject({ phase: 'terminating' })
    container.destroy = destroy
    await worker.runDelete()
    await settleExit(worker)
  })

  it('retains a failed exit cleanup for the alarm and rejects replacement until it succeeds', async () => {
    const { worker, container, storage } = machine()
    await worker.create(input)
    const destroy = container.destroy.bind(container)
    container.destroy = async () => {
      throw new Error('platform unavailable')
    }
    container.exit()
    for (let attempt = 0; attempt < 20 && storage.alarm === undefined; attempt += 1) {
      await new Promise(resolve => setTimeout(resolve, 0))
    }
    expect(storage.alarm).toBeDefined()
    expect(await worker.state('cf-one')).toMatchObject({
      phase: 'terminating',
      reason: 'destroy failed: platform unavailable'
    })
    await expect(worker.create({ ...input, generation: 'gen2' })).rejects.toMatchObject({ code: 'generation_conflict' })
    await expect(worker.deleteStorage('agent-1', 'cf-one')).rejects.toMatchObject({ code: 'instance_present' })
    container.destroy = destroy
    await worker.runDelete()
    await settleExit(worker)
    await worker.create({ ...input, generation: 'gen2' })
    expect(container.running).toBe(true)
  })

  it('reapplies the six-hour timeout and deletion alarm after DO restart', async () => {
    const { worker, container, storage, now } = machine()
    await worker.create(input)
    await worker.remove('cf-one', 'gen1', { mode: 'graceful', graceSeconds: 60 })
    storage.alarm = undefined
    await worker.resume()
    expect(container.timeouts).toEqual([21_600_000, 21_600_000])
    expect<number | undefined>(storage.alarm).toBe(now.time)
  })

  it('accepts same-generation retries, rejects another provider or generation, and ignores stale deletes', async () => {
    const { worker, container } = machine()
    await worker.create(input)
    await worker.create(input)
    expect(container.starts).toHaveLength(1)
    await expect(worker.create({ ...input, generation: 'gen2' })).rejects.toMatchObject({ code: 'generation_conflict' })
    await expect(worker.create({ ...input, providerId: 'other' })).rejects.toMatchObject({ code: 'provider_conflict' })
    await expect(worker.state('other')).rejects.toMatchObject({ code: 'worker_not_found' })
    await worker.remove('cf-one', 'gen0', { mode: 'now', graceSeconds: 1 })
    expect(container.signals).toEqual([])
    const missing = machine()
    await expect(missing.worker.create({ ...input, image: 'unknown' })).rejects.toMatchObject({
      code: 'image_not_deployed'
    })
    expect(missing.container.starts).toEqual([])
    missing.container.images.unknown = missing.container.images['worker-a']!
    await expect(missing.worker.create({ ...input, image: 'unknown' })).rejects.toMatchObject({
      code: 'generation_finished'
    })
    expect(missing.container.starts).toEqual([])
  })

  for (const after of ['exit', 'replacement', 'Agent deletion'] as const) {
    it(`rejects a delayed create of a finished generation after ${after}`, async () => {
      const { worker, container, backups } = machine()
      await worker.create(input)
      await worker.restore(authorization)
      await worker.backup(authorization)
      container.exit()
      await settleExit(worker)

      if (after === 'replacement') {
        await worker.create({ ...input, generation: 'gen2', storageRef: backupRecord })
        await worker.restore(authorization)
        await worker.backup(authorization)
        container.exit()
        await settleExit(worker)
      }
      if (after === 'Agent deletion') await worker.deleteStorage('agent-1', 'cf-one')

      const starts = container.starts.length
      const removals = [...backups.removals]
      const committed = await worker.storageRef('cf-one')
      await expect(worker.create(input)).rejects.toMatchObject({ status: 422, code: 'generation_finished' })
      expect(container.starts).toHaveLength(starts)
      expect(backups.removals).toEqual(removals)
      expect(await worker.storageRef('cf-one')).toEqual(committed)
    })
  }

  it('retains the finished generation after DO restart and permits a new generation', async () => {
    const { worker, storage, container, registry, backups } = machine()
    await worker.create(input)
    await worker.restore(authorization)
    await worker.backup(authorization)
    container.exit()
    await settleExit(worker)
    await worker.deleteStorage('agent-1', 'cf-one')
    const restarted = new WorkerMachine({ storage, container, registry, backups })
    await restarted.resume()
    await expect(restarted.create(input)).rejects.toMatchObject({ code: 'generation_finished' })
    await restarted.create({ ...input, generation: 'gen2' })
    expect(container.starts).toHaveLength(2)
    expect(await restarted.state('cf-one')).toMatchObject({ generation: 'gen2' })
  })

  it('ends the saved generation when a restarted DO finds its container gone', async () => {
    const { worker, storage, registry, backups } = machine()
    await worker.create({ ...input, storageRef: backupRecord })
    // The DO lost its monitor while it was offline; the platform then ended
    // the container. The next DO receives the same storage and no live process.
    const container = new FakeContainer()
    const restarted = new WorkerMachine({ storage, container, registry, backups })
    await restarted.resume()
    await expect(restarted.create(input)).rejects.toMatchObject({ code: 'generation_finished' })
    expect(container.starts).toEqual([])
    expect(container.destroyed).toBe(1)
    expect((await restarted.storageRef('cf-one')).storage_ref).toEqual(backupRecord)
  })

  it('does not leave a false starting instance after registration fails', async () => {
    const { worker, registry, container } = machine()
    const register = registry.add.bind(registry)
    registry.add = async () => {
      throw new Error('registry unavailable')
    }
    await expect(worker.create(input)).rejects.toThrow('registry unavailable')
    expect(await worker.state('cf-one')).toBeNull()
    expect(container.starts).toEqual([])
    registry.add = register
    await worker.create(input)
    expect(container.starts).toHaveLength(1)
  })

  it('authenticates restore and backup with the generation credential', async () => {
    const { worker, backups } = machine()
    await worker.create(input)
    for (const auth of [null, 'Bearer adapter-token', 'Bearer old-worker-secret']) {
      await expect(worker.restore(auth)).rejects.toMatchObject({ status: 401 })
      await expect(worker.backup(auth)).rejects.toMatchObject({ status: 401 })
    }
    expect(backups.restores).toEqual([])
    expect(backups.backups).toEqual([])
  })

  it('deletes all Agent backups and its registry entry only after the instance disappears', async () => {
    const { worker, container, backups, storage, registry } = machine()
    await worker.create(input)
    await expect(worker.deleteStorage('agent-1', 'cf-one')).rejects.toMatchObject({ code: 'instance_present' })
    container.exit()
    await settleExit(worker)
    await worker.deleteStorage('agent-1', 'cf-one')
    expect(backups.removals).toEqual([['agent-1', null]])
    // The receipt is needed to reject delayed creates. All Agent data and
    // credentials must be gone, with no other keys left behind.
    expect([...storage.values]).toEqual([['finished:gen1', true]])
    expect(registry.entries.has('agent-1')).toBe(false)
  })
})
