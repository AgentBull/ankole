import { createCompactionSummaryMessage, type AgentMessage } from './core'
import {
  aiAgentConversationService,
  classifyRenderedRow,
  textFromContent,
  type AiAgentConversationService
} from './conversation-service'
import { numberFromPath, toJsonValue } from '@/common/json'
import type { JsonValue } from '@/common/db-schema'
import { stripHistoricalMedia } from './media'
import { renderMessageWithContext } from './message-context'
import { microcompact } from './microcompact'
import { estimateContextTokensJsonAware } from './token-estimate'

export interface RenderedAiAgentContext {
  inputMessageIds: string[]
  inputMessageRefs: JsonValue[]
  messages: AgentMessage[]
  modelViewPatches: JsonValue[]
  summaryMessageId?: string
}

export class AiAgentContextRenderer {
  constructor(private readonly conversations: AiAgentConversationService = aiAgentConversationService) {}

  async render(
    conversationId: string,
    options?: { microcompact?: { keepRecent: number; triggerTokens: number } }
  ): Promise<RenderedAiAgentContext> {
    const rows = await this.conversations.renderedMessages(conversationId)
    const sourceMessages: AgentMessage[] = []
    const messages: AgentMessage[] = []
    const inputMessageIds: string[] = []
    const inputMessageRefs: JsonValue[] = []
    let summaryMessageId: string | undefined

    for (const row of rows) {
      const projection = classifyRenderedRow(row)
      if (projection === 'skip') continue
      if (projection === 'summary') {
        summaryMessageId = row.id
        const summaryMessage = createCompactionSummaryMessage(
          textFromContent(row.content),
          numberFromPath(row.metadata, ['compression', 'tokens_before']) ?? 0,
          row.createdAt.toISOString()
        )
        sourceMessages.push(summaryMessage)
        messages.push(summaryMessage)
        inputMessageIds.push(row.id)
        inputMessageRefs.push(messageRef(row))
        continue
      }

      const sourceMessage = row.agentMessage as unknown as AgentMessage
      sourceMessages.push(sourceMessage)
      messages.push(renderMessageWithContext(sourceMessage, row.metadata))
      inputMessageIds.push(row.id)
      inputMessageRefs.push(messageRef(row))
    }

    // Middle compaction tier: when the model-bound context is already large, clear
    // old re-derivable tool results (web_search/web_extract) before any LLM summary.
    // The PG rows are untouched — only this returned, model-bound view shrinks.
    const mc = options?.microcompact
    const messagesAfterMicrocompact =
      mc && estimateContextTokensJsonAware(messages) > mc.triggerTokens
        ? microcompact(messages, { keepRecent: mc.keepRecent })
        : messages
    const messagesForModel = stripHistoricalMedia(messagesAfterMicrocompact)
    const modelViewPatches = buildModelViewPatches(
      sourceMessages,
      messagesForModel,
      inputMessageRefs,
      messages,
      messagesAfterMicrocompact
    )

    return {
      messages: messagesForModel,
      inputMessageIds,
      inputMessageRefs,
      modelViewPatches,
      summaryMessageId
    }
  }
}

export const aiAgentContextRenderer = new AiAgentContextRenderer()

function messageRef(row: Awaited<ReturnType<AiAgentConversationService['renderedMessages']>>[number]): JsonValue {
  return {
    type: 'ai_agent_message',
    id: row.id,
    role: row.role,
    kind: row.kind
  }
}

function buildModelViewPatches(
  sourceMessages: AgentMessage[],
  modelMessages: AgentMessage[],
  inputMessageRefs: JsonValue[],
  messagesWithContext: AgentMessage[],
  messagesAfterMicrocompact: AgentMessage[]
): JsonValue[] {
  return modelMessages.flatMap((message, index) => {
    const source = sourceMessages[index]
    if (!source || sameJson(source, message)) return []
    const withContext = messagesWithContext[index]
    const microcompacted = messagesAfterMicrocompact[index]
    const reasons: string[] = []
    if (withContext && !sameJson(source, withContext)) reasons.push('message_context')
    if (microcompacted && withContext && !sameJson(withContext, microcompacted)) reasons.push('microcompact')
    if (microcompacted && !sameJson(microcompacted, message)) reasons.push('historical_media_strip')
    const reason = reasons.length > 0 ? reasons.join('+') : 'model_view_transform'
    return [
      {
        type: 'message_override',
        reason,
        index,
        ref: inputMessageRefs[index] ?? null,
        message: toJsonValue(message)
      }
    ]
  })
}

function sameJson(left: unknown, right: unknown): boolean {
  return JSON.stringify(toJsonValue(left)) === JSON.stringify(toJsonValue(right))
}
