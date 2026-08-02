import { create } from '@bufbuild/protobuf'
import type { ActorTurnRef } from '../lanes/actor_lane'
import { actorTurnRefToProto } from '../lanes/actor_lane'
import {
  createEnvelope,
  ControlShutdownSchema,
  DurabilityClass,
  envelopeHeader,
  jsonBytes,
  Lane,
  TurnAcceptedSchema,
  TurnErrorSchema,
  TurnNoopCompletedSchema,
  WorkerProgressSchema,
  type Envelope
} from './envelope_proto'
import type { JsonObject as JSONObject } from '@agentbull/active-support'

/**
 * Reports that this worker has stopped accepting new turns and is draining its
 * existing tasks. The control plane keeps the route live for terminal writes.
 */
export function controlShutdownEnvelope(reason: string): Envelope {
  const messageID = `control-shutdown-${crypto.randomUUID()}`

  return createEnvelope({
    ...envelopeHeader(messageID, Lane.CONTROL, DurabilityClass.CONTROL_EPHEMERAL),
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
export function turnAcceptedEnvelope(turn: ActorTurnRef, correlationID?: string): Envelope {
  return createEnvelope({
    ...envelopeHeader(
      `turn-accepted-${crypto.randomUUID()}`,
      Lane.TURN,
      DurabilityClass.CONTROL_REPLAYABLE,
      correlationID
    ),
    body: {
      case: 'turnAccepted',
      value: create(TurnAcceptedSchema, { turn: actorTurnRefToProto(turn) })
    }
  })
}

/**
 * Builds a durable turn-error envelope for failures before or during execution.
 *
 * Details are JSON on purpose: the control plane can persist and inspect the
 * worker's classification without making every error subtype part of protobuf.
 */
export function turnErrorEnvelope(
  turn: ActorTurnRef,
  code: string,
  message: string,
  correlationID?: string,
  details: JSONObject = { runtime: 'bun' }
): Envelope {
  return createEnvelope({
    ...envelopeHeader(
      `turn-error-${crypto.randomUUID()}`,
      Lane.TURN,
      DurabilityClass.CONTROL_REPLAYABLE,
      correlationID
    ),
    body: {
      case: 'turnError',
      value: create(TurnErrorSchema, {
        turn: actorTurnRefToProto(turn),
        code,
        message,
        detailsJson: jsonBytes(details)
      })
    }
  })
}

/**
 * Builds a durable successful no-op envelope.
 *
 * This is separate from an empty text response because some inputs, such as
 * schedule-origin quiet success, intentionally complete without user-visible
 * assistant text.
 */
export function turnNoopCompletedEnvelope(
  turn: ActorTurnRef,
  reason = 'noop_completed',
  correlationID?: string
): Envelope {
  return createEnvelope({
    ...envelopeHeader(
      `turn-noop-completed-${crypto.randomUUID()}`,
      Lane.TURN,
      DurabilityClass.CONTROL_REPLAYABLE,
      correlationID
    ),
    body: {
      case: 'turnNoopCompleted',
      value: create(TurnNoopCompletedSchema, { turn: actorTurnRefToProto(turn), reason })
    }
  })
}

/**
 * Builds an ephemeral progress envelope for an already accepted turn.
 *
 * Progress messages are useful for observability but are not replayed as turn
 * truth, so they use the progress lane and ephemeral durability.
 */
export function workerProgressEnvelope(
  turn: ActorTurnRef,
  kind = 'checkpoint',
  summary = 'turn in progress',
  correlationID?: string,
  refs?: JSONObject
): Envelope {
  return createEnvelope({
    ...envelopeHeader(
      `worker-progress-${crypto.randomUUID()}`,
      Lane.PROGRESS,
      DurabilityClass.CONTROL_EPHEMERAL,
      correlationID
    ),
    body: {
      case: 'workerProgress',
      value: create(WorkerProgressSchema, {
        turn: actorTurnRefToProto(turn),
        kind,
        summary,
        refsJson: jsonBytes(refs)
      })
    }
  })
}
