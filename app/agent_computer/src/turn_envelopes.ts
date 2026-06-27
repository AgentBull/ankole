import type { ActorTurnRef } from './actor_lane'
import type { JsonObject, RuntimeFabricEnvelope } from './runtime_fabric'

export type FinalProposalMessage = {
  role: string
  content_json: unknown
  metadata_json?: JsonObject
}

export type FinalProposalReply = {
  text: string
  content_json?: unknown
  attachments?: FinalProposalAttachment[]
}

export type FinalProposalAttachment = {
  agent_computer_path: string
  user_files_relative_path: string
  name?: string
  mime_type?: string
  size?: number
  xxh3_128?: string
}

export type FinalProposalBody = {
  messages?: FinalProposalMessage[]
  reply?: FinalProposalReply | null
  silent_success?: boolean
  usage_json?: JsonObject
  provider_metadata_json?: JsonObject
  stop_reason?: string
  tool_results_json?: unknown[]
}

/**
 * Builds the acceptance fence for all inputs in the turn.
 */
export function turnAcceptedEnvelope(
  turn: ActorTurnRef,
  acceptedIds: string[],
  correlationId?: string
): RuntimeFabricEnvelope {
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
): RuntimeFabricEnvelope {
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
        ...(body.reply === null || body.reply === undefined ? {} : { reply: body.reply }),
        ...(body.silent_success ? { silent_success: body.silent_success } : {}),
        ...(body.usage_json ? { usage_json: body.usage_json } : {}),
        ...(body.provider_metadata_json ? { provider_metadata_json: body.provider_metadata_json } : {}),
        ...(body.stop_reason ? { stop_reason: body.stop_reason } : {}),
        ...(body.tool_results_json ? { tool_results_json: body.tool_results_json } : {})
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

export function workerProgressEnvelope(
  turn: ActorTurnRef,
  kind = 'checkpoint',
  summary = 'turn in progress',
  correlationId?: string,
  refs: JsonObject = {}
): RuntimeFabricEnvelope {
  return baseEnvelope(
    'worker-progress',
    'LANE_PROGRESS',
    'CONTROL_EPHEMERAL',
    {
      type: 'worker_progress',
      worker_progress: {
        turn,
        kind,
        summary,
        refs_json: refs
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
        content_json: [{ type: 'text', text }]
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
