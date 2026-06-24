import type { ActorBusEnvelope, ActorTurnRef, TurnStart } from './actor_bus'

export type PingPongResult = {
  accepted: ActorBusEnvelope
  finalProposal: ActorBusEnvelope
}

export function handlePingPongTurnStart(turnStart: TurnStart, opts: { correlationId?: string } = {}): PingPongResult {
  const acceptedIds = turnStart.inputs.map(input => input.actor_input_id)

  return {
    accepted: turnAcceptedEnvelope(turnStart.turn, acceptedIds, opts.correlationId),
    finalProposal: finalProposalEnvelope(turnStart.turn, 'PONG', opts.correlationId)
  }
}

function turnAcceptedEnvelope(turn: ActorTurnRef, acceptedIds: string[], correlationId?: string): ActorBusEnvelope {
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

function finalProposalEnvelope(turn: ActorTurnRef, text: string, correlationId?: string): ActorBusEnvelope {
  return baseEnvelope(
    'turn-final',
    'LANE_TURN',
    'CONTROL_DURABLE',
    {
      type: 'turn_final_proposal',
      turn_final_proposal: {
        turn,
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
    },
    correlationId
  )
}

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
