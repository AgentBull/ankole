import type { DirectoryBackupRecord } from '@cloudflare/sandbox'
import {
  AdapterError,
  authorized,
  type ContainerControl,
  type Contract,
  type DeleteRequest,
  type HomeBackups,
  type RegistryControl,
  type StorageObservation,
  type WorkerObject,
  type WorkerStorage
} from './types'

const keepAliveMs = 6 * 60 * 60 * 1000
const pollMs = 1_000
const agentStateKeys = ['contract', 'backup', 'restored', 'starting', 'startedAt', 'reason', 'deleting']

type PendingDelete = DeleteRequest & { deadline: number }
interface Deps {
  storage: WorkerStorage
  container: ContainerControl
  registry: RegistryControl
  backups: HomeBackups
  now?: () => Date
}

/** Runs work one at a time, in call order. */
class Queue {
  pending = 0
  private tail: Promise<unknown> = Promise.resolve()

  run<T>(work: () => Promise<T>): Promise<T> {
    this.pending += 1
    const result = this.tail.then(work).finally(() => {
      this.pending -= 1
    })
    this.tail = result.catch(() => undefined)
    return result
  }
}

/** Owns one Agent's instance, latest backup, and completed generation records. */
export class WorkerMachine {
  private readonly storage: WorkerStorage
  private readonly container: ContainerControl
  private readonly registry: RegistryControl
  private readonly backups: HomeBackups
  private readonly now: () => Date
  private exit?: Promise<void>
  // RPC and alarm events can interleave during platform calls. In particular,
  // a delayed destroy must finish before the next generation can start.
  private readonly lifecycle = new Queue()
  // Restores and backups stay out of the lifecycle queue, so the alarm can
  // destroy an unresponsive container at its deadline. One waits for the
  // other, so a restore reads the latest record, also during a backup.
  private readonly home = new Queue()

  constructor(deps: Deps) {
    this.storage = deps.storage
    this.container = deps.container
    this.registry = deps.registry
    this.backups = deps.backups
    this.now = deps.now ?? (() => new Date())
  }

  create(input: Contract): Promise<WorkerObject> {
    return this.lifecycle.run(() => this.createInstance(input))
  }

  private async createInstance(input: Contract): Promise<WorkerObject> {
    const existing = await this.storage.get<Contract>('contract')
    if (existing && existing.providerId !== input.providerId) {
      throw new AdapterError(409, 'provider_conflict', 'Agent storage belongs to another provider')
    }
    const present =
      this.container.running ||
      this.exit ||
      this.home.pending > 0 ||
      (await this.storage.get('starting')) ||
      (await this.storage.get('deleting'))
    if (existing && present && existing.generation !== input.generation) {
      throw new AdapterError(
        409,
        'generation_conflict',
        `Agent ${input.agentUid} still has generation ${existing.generation}`
      )
    }
    if (existing?.generation === input.generation && present) return this.requireState(input.providerId)
    if (await this.storage.get(`finished:${input.generation}`)) {
      throw new AdapterError(422, 'generation_finished', `generation ${input.generation} has ended`)
    }
    const image = this.container.images[input.image]
    if (!image) {
      await this.storage.put(`finished:${input.generation}`, true)
      throw new AdapterError(422, 'image_not_deployed', `image ${input.image} is not deployed`)
    }

    // Store the control plane's committed pointer, never a previous uncommitted
    // record. This is also the pointer returned if the restore fails.
    await this.storage.put({
      contract: input,
      backup: input.storageRef,
      restored: false,
      starting: true,
      startedAt: this.now().toISOString(),
      reason: null
    })
    try {
      await this.registry.add(input.agentUid, input.providerId)
      this.container.start({ image, enableInternet: true, env: input.env, instance: input.instance })
      this.watchExit(input.generation)
      await this.container.setInactivityTimeout(keepAliveMs)
      await this.storage.put('starting', false)
      return await this.requireState(input.providerId)
    } catch (error) {
      await this.storage.put({ starting: false, reason: message(error) })
      throw error
    }
  }

  /** A DO restart drops its idle timeout even when its container stays alive. */
  async resume(): Promise<void> {
    const contract = await this.storage.get<Contract>('contract')
    if (!contract) return
    await this.storage.put('starting', false)
    if (this.container.running) {
      await this.container.setInactivityTimeout(keepAliveMs)
      this.watchExit(contract.generation)
    } else if (!(await this.storage.get(`finished:${contract.generation}`)) || (await this.storage.get('deleting'))) {
      // A DO can restart after the platform has already ended its container.
      // Confirm destruction before a retry can start this generation again.
      await this.finishInstance('exited')
    }
    if (await this.storage.get('deleting')) await this.storage.setAlarm(this.now().getTime())
  }

  remove(providerId: string, generation: string, request: DeleteRequest): Promise<void> {
    return this.lifecycle.run(() => this.deleteInstance(providerId, generation, request))
  }

  private async deleteInstance(providerId: string, generation: string, request: DeleteRequest): Promise<void> {
    const contract = await this.ownedContract(providerId)
    if (!contract || contract.generation !== generation) return
    const previous = await this.storage.get<PendingDelete>('deleting')
    const pending: PendingDelete = previous
      ? { ...previous, mode: request.mode === 'now' ? 'now' : previous.mode }
      : { ...request, deadline: this.now().getTime() + request.graceSeconds * 1000 }
    await this.storage.put('deleting', pending)
    await this.storage.setAlarm(this.now().getTime() + pollMs)
    if (!this.container.running) return this.destroyInstance()
    // SIGUSR1 makes the supervisor stop all writers immediately, then back up.
    // SIGKILL here would destroy the only copy of changes since the last backup.
    if (!previous || previous.mode !== pending.mode) this.container.signal(pending.mode === 'now' ? 10 : 15)
  }

  /** Never wait inside the alarm: the container must be able to call backup. */
  runDelete(): Promise<void> {
    return this.lifecycle.run(() => this.checkDelete())
  }

  private async checkDelete(): Promise<void> {
    const pending = await this.storage.get<PendingDelete>('deleting')
    if (!pending) return
    if (!this.container.running || this.now().getTime() >= pending.deadline) {
      await this.destroyInstance()
    } else {
      await this.storage.setAlarm(this.now().getTime() + pollMs)
    }
  }

  private async destroyInstance(): Promise<void> {
    const contract = await this.storage.get<Contract>('contract')
    if (contract) await this.storage.put(`finished:${contract.generation}`, true)
    try {
      await this.container.destroy()
      await this.storage.delete('deleting')
    } catch (error) {
      await this.storage.put('reason', `destroy failed: ${message(error)}`)
      throw error
    }
  }

  /**
   * The entrypoint asks for a restore when its instance disk has no restored
   * Home: at the first start, and again after a container restart replaces the
   * disk. Each request restores once. A request never shares the result of an
   * earlier one, because the earlier request can come from a disk that is gone.
   */
  async restore(authorization: string | null): Promise<void> {
    const contract = await this.workerContract(authorization)
    return this.home.run(() => this.restoreHome(contract))
  }

  private async restoreHome(contract: Contract): Promise<void> {
    try {
      // Only the reported phase uses this flag. The disk marker decides restores and backups.
      await this.storage.put('restored', false)
      // The latest record of this generation: its last backup, else the committed pointer.
      const latest = (await this.storage.get<DirectoryBackupRecord | null>('backup')) ?? null
      if (latest) await this.backups.restore(contract.agentUid, latest)
      await this.requireGeneration(contract.providerId, contract.generation)
      await this.backups.removeOthers(contract.agentUid, latest)
      await this.storage.put({ restored: true, reason: null })
    } catch (error) {
      await this.storage.put('reason', `restore failed: ${message(error)}`)
      throw error
    }
  }

  /** The entrypoint asks for a backup only from a disk that holds a restored Home. */
  async backup(authorization: string | null): Promise<DirectoryBackupRecord> {
    const contract = await this.workerContract(authorization)
    return this.home.run(() => this.backupHome(contract))
  }

  private async backupHome(contract: Contract): Promise<DirectoryBackupRecord> {
    try {
      const backup = await this.backups.backup(contract.agentUid)
      await this.requireGeneration(contract.providerId, contract.generation)
      await this.storage.put({ backup, reason: null })
      return backup
    } catch (error) {
      await this.storage.put('reason', `backup failed: ${message(error)}`)
      throw error
    }
  }

  async storageRef(providerId: string): Promise<StorageObservation> {
    await this.ownedContract(providerId)
    return {
      storage_ref: (await this.storage.get<DirectoryBackupRecord | null>('backup')) ?? null,
      reason: (await this.storage.get<string>('reason')) ?? null
    }
  }

  deleteStorage(agentUid: string, providerId: string): Promise<void> {
    return this.lifecycle.run(() => this.removeStorage(agentUid, providerId))
  }

  private async removeStorage(agentUid: string, providerId: string): Promise<void> {
    await this.ownedContract(providerId)
    if (
      this.container.running ||
      this.exit ||
      this.home.pending > 0 ||
      (await this.storage.get('starting')) ||
      (await this.storage.get('deleting'))
    ) {
      throw new AdapterError(409, 'instance_present', 'delete the instance before Agent storage')
    }
    await this.backups.removeOthers(agentUid, null)
    await this.storage.deleteAlarm()
    // Keep only idempotency receipts. Delayed requests have no expiry and must
    // not restore an old backup.
    for (const key of agentStateKeys) await this.storage.delete(key)
    await this.registry.remove(agentUid, providerId)
  }

  async state(providerId: string): Promise<WorkerObject | null> {
    const contract = await this.ownedContract(providerId)
    const deleting = await this.storage.get('deleting')
    const finishing = this.exit || this.home.pending > 0 || this.lifecycle.pending > 0
    if (!contract || (!this.container.running && !finishing && !deleting && !(await this.storage.get('starting')))) {
      return null
    }
    return {
      tenant_id: contract.env.ANKOLE_WORKER_TENANT_ID!,
      agent_uid: contract.env.WORKER_ID!,
      generation: contract.generation,
      phase:
        (!this.container.running && finishing) || deleting
          ? 'terminating'
          : (await this.storage.get('restored'))
            ? 'running'
            : 'starting',
      reason: (await this.storage.get<string>('reason')) ?? null,
      started_at: (await this.storage.get<string>('startedAt'))!
    }
  }

  images(): string[] {
    return Object.keys(this.container.images)
  }

  private async ownedContract(providerId: string): Promise<Contract | undefined> {
    const contract = await this.storage.get<Contract>('contract')
    if (contract && contract.providerId !== providerId) {
      throw new AdapterError(404, 'worker_not_found', 'the Agent does not belong to this provider')
    }
    return contract
  }

  private async workerContract(authorization: string | null): Promise<Contract> {
    const contract = await this.storage.get<Contract>('contract')
    if (!contract || !authorized(authorization, contract.env.ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY!)) {
      throw new AdapterError(401, 'unauthorized', 'a valid Worker credential is required')
    }
    return contract
  }

  private async requireGeneration(providerId: string, generation: string): Promise<Contract> {
    const contract = await this.ownedContract(providerId)
    if (!contract || contract.generation !== generation) {
      throw new AdapterError(409, 'generation_conflict', 'the Worker generation changed')
    }
    return contract
  }

  private async requireState(providerId: string): Promise<WorkerObject> {
    const state = await this.state(providerId)
    if (!state) throw new AdapterError(404, 'worker_not_found', 'the Worker instance is absent')
    return state
  }

  private watchExit(generation: string): void {
    if (this.exit) return
    const exit = this.container
      .monitor()
      .then(
        () => 'exited',
        error => `exited with error: ${message(error)}`
      )
      .then(reason =>
        this.lifecycle.run(async () => {
          const contract = await this.storage.get<Contract>('contract')
          if (contract?.generation !== generation || this.exit !== exit) return
          try {
            await this.finishInstance(reason)
          } finally {
            this.exit = undefined
          }
        })
      )
    this.exit = exit
  }

  private async finishInstance(reason: string): Promise<void> {
    if (!(await this.storage.get('reason'))) await this.storage.put('reason', reason)
    await this.storage.put('deleting', { mode: 'now', graceSeconds: 1, deadline: this.now().getTime() })
    try {
      await this.destroyInstance()
    } catch {
      // Keep the generation visible until destruction succeeds. The alarm also
      // retries after a DO restart; the error remains in storageRef and state.
      await this.storage.setAlarm(this.now().getTime() + pollMs)
    }
  }
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
