import type { JsonObject, TurnStart } from '../../actor_lane'
import type { AgentEvent, AgentMessage } from '../types'
import type { AssistantMessage, Model } from '../../llm/ankole'
import type { LlmProviderCredentialResponse } from '../../rpc_lane'
import type { ReplyAttachmentStore } from '../../tools/computer/reply-attachment-tool'
import { visibleReplyProposal, type FinalProposalBody } from '../../turn_envelopes'
import { isRecord, jsonObject, jsonValue } from '../../common/json-utils'

export type TurnTelemetry = {
  usage?: JsonObject
  stopReason?: string
  providerMetadata: JsonObject
  toolResults: unknown[]
}

export function createTurnTelemetry(credential: LlmProviderCredentialResponse, model: Model): TurnTelemetry {
  return {
    providerMetadata: {
      provider_id: credential.provider_id,
      provider_source: credential.provider_source,
      profile: credential.profile,
      model: credential.model,
      runtime_provider: model.provider
    },
    toolResults: []
  }
}

export function observeAgentEvent(telemetry: TurnTelemetry): (event: AgentEvent) => void {
  return event => {
    switch (event.type) {
      case 'turn_end':
        if (isAssistantMessage(event.message)) {
          applyAssistantTelemetry(telemetry, event.message)
        }
        break

      case 'tool_execution_end':
        telemetry.toolResults.push({
          tool_call_id: event.toolCallId,
          tool_name: event.toolName,
          args: jsonValue(event.args),
          result: jsonValue(event.result),
          is_error: event.isError
        })
        break
    }
  }
}

export function finalProposalWithTelemetry(
  text: string,
  telemetry: TurnTelemetry,
  replyAttachmentStore?: ReplyAttachmentStore
): FinalProposalBody {
  const attachments = replyAttachmentStore?.attachments ?? []

  return {
    ...visibleReplyProposal(text),
    ...(attachments.length > 0
      ? {
          reply: {
            text,
            content_json: [{ type: 'text', text }],
            attachments
          }
        }
      : {}),
    ...(telemetry.usage ? { usage_json: telemetry.usage } : {}),
    provider_metadata_json: telemetry.providerMetadata,
    ...(telemetry.stopReason ? { stop_reason: telemetry.stopReason } : {}),
    tool_results_json: telemetry.toolResults
  }
}

export function silentSuccessProposalWithTelemetry(telemetry: TurnTelemetry): FinalProposalBody {
  return {
    messages: [],
    reply: null,
    silent_success: true,
    ...(telemetry.usage ? { usage_json: telemetry.usage } : {}),
    provider_metadata_json: telemetry.providerMetadata,
    ...(telemetry.stopReason ? { stop_reason: telemetry.stopReason } : {}),
    tool_results_json: telemetry.toolResults
  }
}

export function scheduleSilentSuccessRequested(text: string): boolean {
  return text.trim().toLowerCase() === '<silent_success/>'
}

export function scheduleSilentSuccessAllowed(turnStart: TurnStart): boolean {
  return turnStart.request_context?.silent_success_allowed === true
}

function applyAssistantTelemetry(telemetry: TurnTelemetry, message: AssistantMessage): void {
  telemetry.usage = jsonObject(message.usage)
  telemetry.stopReason = message.stopReason
  telemetry.providerMetadata = {
    ...telemetry.providerMetadata,
    ...(message.responseId ? { response_id: message.responseId } : {}),
    ...(message.responseModel ? { response_model: message.responseModel } : {})
  }
}

function isAssistantMessage(message: AgentMessage): message is AssistantMessage {
  return isRecord(message) && message.role === 'assistant'
}
