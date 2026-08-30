import { ms } from '@agentbull/active-support'
import { create } from '@bufbuild/protobuf'
import {
  AgentComputerWorkerCapacitySchema,
  AgentComputerWorkerHeartbeatSchema,
  AgentComputerWorkerReadySchema,
  createEnvelope,
  envelopeHeader,
  type Envelope
} from '../fabric/envelope_proto'
import { isRuntimeFabricTransportError, type EnvelopeSender } from '../fabric/fabric'
import type { WorkerConfig } from './config'
import { workerLogger } from './logging'

/** Cadence for replaceable Worker liveness evidence. */
export const heartbeatIntervalMs = ms('15s')
/** Runtime label reported as lifecycle telemetry. */
const workerRuntime = 'bun'
/** Implementation version reported as telemetry, not as a protocol version. */
const workerVersion = '0.1.0'

/**
 * Builds the first lifecycle envelope after RuntimeFabric connects.
 *
 * Runtime and product version are observability metadata. Protocol compatibility
 * is enforced by the envelope header before this worker can enter the ready pool.
 */
export function workerReadyEnvelope(config: WorkerConfig, availableTurnSlots = config.maxConcurrentTurns): Envelope {
  const available = clampAvailableSlots(config, availableTurnSlots)

  return createEnvelope({
    ...envelopeHeader(`worker-ready-${crypto.randomUUID()}`),
    body: {
      case: 'workerReady',
      value: create(AgentComputerWorkerReadySchema, {
        workerId: config.workerID,
        incarnationId: config.incarnationID,
        runtime: workerRuntime,
        version: workerVersion,
        maxTurns: config.maxConcurrentTurns,
        availableTurnSlots: available
      })
    }
  })
}

/**
 * Builds the periodic liveness envelope for the admitted worker process.
 *
 * The control plane fences heartbeats by worker id and transport route, so an
 * old process cannot keep a replaced worker projection alive.
 */
export function workerHeartbeatEnvelope(
  config: WorkerConfig,
  monotonicMs = Math.floor(performance.now()),
  activeTurns = 0
): Envelope {
  const available = clampAvailableSlots(config, config.maxConcurrentTurns - activeTurns)

  return createEnvelope({
    ...envelopeHeader(`worker-heartbeat-${crypto.randomUUID()}`),
    body: {
      case: 'workerHeartbeat',
      value: create(AgentComputerWorkerHeartbeatSchema, {
        workerId: config.workerID,
        incarnationId: config.incarnationID,
        monotonicMs: BigInt(monotonicMs),
        activeTurns,
        runtime: workerRuntime,
        version: workerVersion,
        maxTurns: config.maxConcurrentTurns,
        availableTurnSlots: available
      })
    }
  })
}

/**
 * Builds the capacity projection used by the simple worker scheduler.
 *
 * Capacity is intentionally small here: it answers whether the worker can take
 * more turns, not which actor or tool classes it supports.
 */
export function workerCapacityEnvelope(
  config: WorkerConfig,
  availableTurnSlots = config.maxConcurrentTurns,
  activeTurns = 0
): Envelope {
  const available = clampAvailableSlots(config, availableTurnSlots)

  return createEnvelope({
    ...envelopeHeader(`worker-capacity-${crypto.randomUUID()}`),
    body: {
      case: 'workerCapacity',
      value: create(AgentComputerWorkerCapacitySchema, {
        workerId: config.workerID,
        incarnationId: config.incarnationID,
        maxTurns: config.maxConcurrentTurns,
        activeTurns,
        availableTurnSlots: available
      })
    }
  })
}

/**
 * Treats heartbeat as replaceable lease evidence. Backpressure drops one
 * heartbeat; any other transport error remains fatal. Capacity,
 * acknowledgements, and RPC replies still fail normally.
 */
export async function sendWorkerHeartbeat(sendEnvelope: EnvelopeSender, heartbeat: Envelope): Promise<void> {
  try {
    await sendEnvelope(heartbeat)
  } catch (error) {
    if (!isRuntimeFabricTransportError(error, 'backpressure')) {
      throw error
    }

    workerLogger.warning('worker.heartbeat_skipped', 'worker heartbeat skipped', { reason: 'backpressure' })
  }
}

/**
 * Clamps capacity before the Worker projects it to the control plane.
 *
 * A bad local counter degrades to zero capacity instead of advertising a value
 * that the scheduler cannot safely interpret.
 */
function clampAvailableSlots(config: WorkerConfig, availableTurnSlots: number): number {
  if (!Number.isInteger(availableTurnSlots)) return 0
  return Math.max(0, Math.min(config.maxConcurrentTurns, availableTurnSlots))
}
