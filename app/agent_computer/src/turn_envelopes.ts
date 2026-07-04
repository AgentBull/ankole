import type { ActorTurnRef } from './actor_lane'
import type { JsonObject, RuntimeFabricEnvelope } from './runtime_fabric'

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
