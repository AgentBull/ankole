import { ms } from '@agentbull/active-support'
import { create } from '@bufbuild/protobuf'
import { WorkerHeartbeatSchema, createEnvelope, envelopeHeader, type Envelope } from '../fabric/envelope_proto'
import { errorMessage } from '../common/errors'
import { isRuntimeFabricTransportError, type EnvelopeSender } from '../fabric/fabric'
import type { WorkerConfig } from './config'
import { workerLogger } from './logging'
import type { WorkerDrainState } from './drain'

export const heartbeatIntervalMs = ms('15s')

/** Owns capacity shared by Job turns and environment workspaces. */
export class Slots {
  private count = 0
  constructor(
    private readonly config: WorkerConfig,
    private readonly drain: WorkerDrainState,
    private readonly send: EnvelopeSender
  ) {}
  used(): number {
    return this.count
  }
  available(): number {
    return Math.max(this.config.maxConcurrentSlots - this.count, 0)
  }
  reserve(): boolean {
    if (this.count >= this.config.maxConcurrentSlots) return false
    this.count += 1
    return true
  }
  release(): void {
    this.count -= 1
  }
  heartbeat(): Envelope {
    const load = this.drain.load
    return createEnvelope({
      ...envelopeHeader(`worker-heartbeat-${crypto.randomUUID()}`),
      body: {
        case: 'workerHeartbeat',
        value: create(WorkerHeartbeatSchema, {
          incarnationId: this.config.incarnationID,
          activeSlots: this.count,
          maxSlots: this.config.maxConcurrentSlots,
          availableSlots: this.available(),
          activeTasks: load.activeTasks,
          idleForMs: BigInt(load.idleForMs)
        })
      }
    })
  }
  async publish(): Promise<void> {
    try {
      await this.send(this.heartbeat())
    } catch (error) {
      workerLogger.warning('worker.capacity_send_failed', 'Capacity will be reported on the next heartbeat', {
        error: errorMessage(error)
      })
    }
  }
}

/** A heartbeat is replaceable lease evidence; the next one renews a lost send. */
export async function sendWorkerHeartbeat(sendEnvelope: EnvelopeSender, heartbeat: Envelope): Promise<void> {
  try {
    await sendEnvelope(heartbeat)
  } catch (error) {
    if (!isRuntimeFabricTransportError(error, 'socket_closed') && !isRuntimeFabricTransportError(error, 'timeout')) {
      throw error
    }
    workerLogger.warning('worker.heartbeat_skipped', 'worker heartbeat skipped', { reason: error.code })
  }
}
