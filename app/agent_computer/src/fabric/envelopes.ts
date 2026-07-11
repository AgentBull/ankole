import type { ActorTurnRef } from '../lanes/actor_lane'
import type { RuntimeFabricEnvelope } from './fabric'
import type { JsonObject } from '@pleisto/active-support'

/**
 * Builds the acceptance fence for a received turn revision.
 * Active mailbox updates are identified by the same turn fence plus a newer revision.
 */
export function turnAcceptedEnvelope(turn: ActorTurnRef, correlationId?: string): RuntimeFabricEnvelope {
  return baseEnvelope(
    'turn-accepted',
    'LANE_TURN',
    'CONTROL_REPLAYABLE',
    {
      type: 'turn_accepted',
      turn_accepted: {
        turn
      }
    },
    correlationId
  )
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
  correlationId?: string,
  details: JsonObject = { runtime: 'bun' }
): RuntimeFabricEnvelope {
  return baseEnvelope(
    'turn-error',
    'LANE_TURN',
    'CONTROL_REPLAYABLE',
    {
      type: 'turn_error',
      turn_error: {
        turn,
        code,
        message,
        details_json: details
      }
    },
    correlationId
  )
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
  correlationId?: string
): RuntimeFabricEnvelope {
  return baseEnvelope(
    'turn-noop-completed',
    'LANE_TURN',
    'CONTROL_REPLAYABLE',
    {
      type: 'turn_noop_completed',
      turn_noop_completed: {
        turn,
        reason
      }
    },
    correlationId
  )
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
  finalResponseId: string,
  outcome: 'loop_finished' | 'iteration_exhausted',
  correlationId?: string
): RuntimeFabricEnvelope {
  return baseEnvelope(
    'turn-completed',
    'LANE_TURN',
    'CONTROL_REPLAYABLE',
    {
      type: 'turn_completed',
      turn_completed: {
        turn,
        final_response_id: finalResponseId,
        outcome
      }
    },
    correlationId
  )
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
  correlationId?: string,
  refs?: JsonObject
): RuntimeFabricEnvelope {
  const workerProgress: JsonObject = {
    turn,
    kind,
    summary
  }
  if (refs) workerProgress.refs_json = refs

  return baseEnvelope(
    'worker-progress',
    'LANE_PROGRESS',
    'CONTROL_EPHEMERAL',
    {
      type: 'worker_progress',
      worker_progress: workerProgress
    },
    correlationId
  )
}

/**
 * Builds a protocol envelope while preserving the turn-start correlation id.
 */
function baseEnvelope(
  messagePrefix: string,
  lane: string,
  durability: string,
  body: RuntimeFabricEnvelope['body'],
  correlationId?: string
): RuntimeFabricEnvelope {
  const messageId = `${messagePrefix}-${crypto.randomUUID()}`

  return {
    protocol_version: 1,
    message_id: messageId,
    correlation_id: correlationId ?? messageId,
    lane,
    durability,
    body
  }
}
