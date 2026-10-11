import { create } from '@bufbuild/protobuf'
import type { JobTurnRef } from '../lanes/actor_lane'
import { jobTurnRefToProto } from '../lanes/actor_lane'
import {
  createEnvelope,
  ControlShutdownSchema,
  envelopeHeader,
  TurnAcceptedSchema,
  WorkerProgressSchema,
  type Envelope
} from './envelope_proto'

/**
 * Reports that this worker has stopped accepting new turns and is draining its
 * existing tasks. The control plane keeps the route live for terminal writes.
 */
export function controlShutdownEnvelope(reason: string): Envelope {
  const messageID = `control-shutdown-${crypto.randomUUID()}`

  return createEnvelope({
    ...envelopeHeader(messageID),
    body: {
      case: 'controlShutdown',
      value: create(ControlShutdownSchema, { reason })
    }
  })
}

/**
 * Builds the acceptance fence for a received turn revision.
 * Active mailbox updates are identified by the same turn fence plus a newer revision.
 */
export function turnAcceptedEnvelope(turn: JobTurnRef): Envelope {
  return createEnvelope({
    ...envelopeHeader(`turn-accepted-${crypto.randomUUID()}`),
    body: {
      case: 'turnAccepted',
      value: create(TurnAcceptedSchema, { turn: jobTurnRefToProto(turn) })
    }
  })
}

/** Keeps the accepted Job attempt alive. */
export function workerProgressEnvelope(turn: JobTurnRef): Envelope {
  return createEnvelope({
    ...envelopeHeader(`worker-progress-${crypto.randomUUID()}`),
    body: { case: 'workerProgress', value: create(WorkerProgressSchema, { turn: jobTurnRefToProto(turn) }) }
  })
}
