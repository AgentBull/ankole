import { create } from '@bufbuild/protobuf'
import type { ActorTurnRef } from '../lanes/actor_lane'
import { actorTurnRefToProto } from '../lanes/actor_lane'
import {
  createEnvelope,
  DurabilityClass,
  envelopeHeader,
  jsonBytes,
  Lane,
  TurnAcceptedSchema,
  TurnCompletedSchema,
  TurnCompletionOutcome,
  TurnErrorSchema,
  TurnNoopCompletedSchema,
  WorkerProgressSchema,
  type Envelope
} from './envelope_proto'
import type { JsonObject as JSONObject } from '@pleisto/active-support'

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
 * Reports the final response selected by the worker-owned Agent loop.
 *
 * A completed model response is not itself an Actor turn terminal. Only the
 * loop driver can emit this envelope after it has decided no further model or
 * tool iteration is needed.
 */
export function turnCompletedEnvelope(
  turn: ActorTurnRef,
  finalResponseID: string,
  outcome: 'loop_finished' | 'iteration_exhausted',
  correlationID?: string
): Envelope {
  return createEnvelope({
    ...envelopeHeader(
      `turn-completed-${crypto.randomUUID()}`,
      Lane.TURN,
      DurabilityClass.CONTROL_REPLAYABLE,
      correlationID
    ),
    body: {
      case: 'turnCompleted',
      value: create(TurnCompletedSchema, {
        turn: actorTurnRefToProto(turn),
        finalResponseId: finalResponseID,
        outcome:
          outcome === 'loop_finished' ? TurnCompletionOutcome.LOOP_FINISHED : TurnCompletionOutcome.ITERATION_EXHAUSTED
      })
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
