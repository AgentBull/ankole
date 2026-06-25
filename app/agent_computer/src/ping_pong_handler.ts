import type { ActorBusEnvelope, ActorTurnRef, JsonObject, TurnStart } from './actor_bus'

export type FinalProposalMessage = {
  role: string
  content_json: unknown
  metadata_json?: JsonObject
}

export type FinalProposalReply = {
  text: string
  content_json?: unknown
}

export type FinalProposalBody = {
  messages?: FinalProposalMessage[]
  reply?: FinalProposalReply | null
}

export type PingPongResult = {
  accepted: ActorBusEnvelope
  finalProposal: ActorBusEnvelope
}

/**
 * Handles the current ping-pong actor turn.
 *
 * This function models the envelope sequence expected from the full computer
 * loop: the worker first accepts the exact actor inputs, then proposes a final
 * assistant response for the control plane to commit.
 */
export function handlePingPongTurnStart(turnStart: TurnStart, opts: { correlationId?: string } = {}): PingPongResult {
  const acceptedIds = turnStart.inputs.map(input => input.actor_input_id)

  return {
    accepted: turnAcceptedEnvelope(turnStart.turn, acceptedIds, opts.correlationId),
    finalProposal: finalProposalEnvelope(turnStart.turn, 'PONG', opts.correlationId)
  }
}

/**
 * Builds the acceptance fence for all inputs in the turn.
 */
export function turnAcceptedEnvelope(
  turn: ActorTurnRef,
  acceptedIds: string[],
  correlationId?: string
): ActorBusEnvelope {
  return baseEnvelope(
    'turn-accepted',
    'LANE_TURN',
    'CONTROL_REPLAYABLE',
    {
      type: 'turn_accepted',
      turn_accepted: {
        turn,
        accepted_actor_input_ids: acceptedIds
      }
    },
    correlationId
  )
}

/**
 * Builds the worker proposal that the control plane may commit durably.
 *
 * The proposal is not durable truth by itself; it must pass activation and
 * delivery fence checks in the control plane before any transcript row is
 * written.
 */
export function finalProposalEnvelope(
  turn: ActorTurnRef,
  proposal: string | FinalProposalBody,
  correlationId?: string
): ActorBusEnvelope {
  const body = typeof proposal === 'string' ? visibleReplyProposal(proposal) : proposal

  return baseEnvelope(
    'turn-final',
    'LANE_TURN',
    'CONTROL_DURABLE',
    {
      type: 'turn_final_proposal',
      turn_final_proposal: {
        turn,
        messages: body.messages ?? [],
        ...(body.reply === null || body.reply === undefined ? {} : { reply: body.reply })
      }
    },
    correlationId
  )
}

export function visibleReplyProposal(text: string): FinalProposalBody {
  return {
    messages: [
      {
        role: 'assistant',
        content_json: [{ type: 'text', text }],
        metadata_json: { placeholder: true }
      }
    ],
    reply: {
      text,
      content_json: [{ type: 'text', text }]
    }
  }
}

/**
 * Builds a protocol envelope while preserving the turn-start correlation id.
 */
function baseEnvelope(
  messagePrefix: string,
  lane: string,
  durability: string,
  body: ActorBusEnvelope['body'],
  correlationId?: string
): ActorBusEnvelope {
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
