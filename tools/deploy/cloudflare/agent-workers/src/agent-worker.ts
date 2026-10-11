import { DirectoryBackup, type DirectoryBackupGatewayBinding, type DirectoryBackupRecord } from '@cloudflare/sandbox'
import { DurableObject } from 'cloudflare:workers'
import { registryName, type Env } from './env'
import { WorkerMachine } from './machine'
import {
  AdapterError,
  type ContainerControl,
  type Contract,
  type DeleteRequest,
  type Result,
  type StorageObservation,
  type WorkerObject,
  type WorkerStorage
} from './types'

/** The DO id is the Agent UID; a generation uses the same DO and R2 prefix. */
export class AgentWorker extends DurableObject<Env> {
  private worker?: WorkerMachine

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    void ctx.blockConcurrencyWhile(() => this.machine().resume())
  }

  create(input: Contract): Promise<Result<WorkerObject>> {
    return this.run(machine => machine.create(input))
  }
  remove(providerId: string, generation: string, request: DeleteRequest): Promise<Result<void>> {
    return this.run(machine => machine.remove(providerId, generation, request))
  }
  state(providerId: string): Promise<Result<WorkerObject | null>> {
    return this.run(machine => machine.state(providerId))
  }
  images(): Promise<Result<string[]>> {
    return this.run(async machine => machine.images())
  }
  restore(authorization: string | null): Promise<Result<void>> {
    return this.run(machine => machine.restore(authorization))
  }
  backup(authorization: string | null): Promise<Result<DirectoryBackupRecord>> {
    return this.run(machine => machine.backup(authorization))
  }
  storageRef(providerId: string): Promise<Result<StorageObservation>> {
    return this.run(machine => machine.storageRef(providerId))
  }
  deleteStorage(agentUid: string, providerId: string): Promise<Result<void>> {
    return this.run(machine => machine.deleteStorage(agentUid, providerId))
  }
  override async alarm(): Promise<void> {
    await this.machine().runDelete()
  }

  private machine(): WorkerMachine {
    if (this.worker) return this.worker
    const container = this.ctx.container
    if (!container) throw new Error('the AgentWorker Durable Object has no container')
    const registry = this.env.REGISTRY.get(this.env.REGISTRY.idFromName(registryName))
    const directory = (agentUid: string) =>
      new DirectoryBackup(container, this.ctx.exports.DirectoryBackupGateway as DirectoryBackupGatewayBinding, {
        binding: 'BACKUPS',
        prefix: `agents/${agentUid}/`
      })
    this.worker = new WorkerMachine({
      storage: this.ctx.storage as WorkerStorage,
      container: container as ContainerControl,
      registry: {
        add: (uid, providerId) => registry.add(uid, providerId),
        remove: (uid, providerId) => registry.remove(uid, providerId)
      },
      backups: {
        restore: (uid, record) => directory(uid).restore(record, { dir: '/workspace' }),
        backup: uid => directory(uid).backup({ dir: '/workspace' }),
        removeOthers: (uid, keep) => this.removeBackups(uid, keep)
      }
    })
    return this.worker
  }

  private async removeBackups(agentUid: string, keep: DirectoryBackupRecord | null): Promise<void> {
    const prefix = `agents/${agentUid}/`
    const keepKey = keep ? `${prefix}${keep.id}.tar.zst` : null
    let cursor: string | undefined
    do {
      const page = await this.env.BACKUPS.list({ prefix, cursor })
      const keys = page.objects.filter(object => object.key !== keepKey).map(object => object.key)
      if (keys.length) await this.env.BACKUPS.delete(keys)
      cursor = page.truncated ? page.cursor : undefined
    } while (cursor)
  }

  private async run<T>(work: (machine: WorkerMachine) => Promise<T>): Promise<Result<T>> {
    try {
      return { ok: true, value: await work(this.machine()) }
    } catch (error) {
      if (error instanceof AdapterError) {
        return { ok: false, status: error.status, code: error.code, message: error.message }
      }
      throw error
    }
  }
}
