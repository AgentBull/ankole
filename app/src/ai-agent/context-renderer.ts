import { createCompactionSummaryMessage, type AgentMessage } from './core'
import {
  aiAgentConversationService,
  classifyRenderedRow,
  textFromContent,
  type AiAgentConversationService
} from './conversation-service'
import { numberFromPath, toJsonValue } from '@/common/json'
import type { JsonValue } from '@/common/db-schema'
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
    const messages: AgentMessage[] = []
    const inputMessageIds: string[] = []
    const inputMessageRefs: JsonValue[] = []
    let summaryMessageId: string | undefined

    for (const row of rows) {
      const projection = classifyRenderedRow(row)
      if (projection === 'skip') continue
      if (projection === 'summary') {
        summaryMessageId = row.id
        messages.push(
          createCompactionSummaryMessage(
            textFromContent(row.content),
            numberFromPath(row.metadata, ['compression', 'tokens_before']) ?? 0,
            row.createdAt.toISOString()
          )
        )
        inputMessageIds.push(row.id)
        inputMessageRefs.push(messageRef(row))
        continue
      }

      messages.push(row.agentMessage as unknown as AgentMessage)
      inputMessageIds.push(row.id)
      inputMessageRefs.push(messageRef(row))
    }

    // Middle compaction tier: when the model-bound context is already large, clear
    // old re-derivable tool results (web_search/web_extract) before any LLM summary.
    // The PG rows are untouched — only this returned, model-bound view shrinks.
    const mc = options?.microcompact
    const messagesForModel =
      mc && estimateContextTokensJsonAware(messages) > mc.triggerTokens
        ? microcompact(messages, { keepRecent: mc.keepRecent })
        : messages
    const modelViewPatches = buildModelViewPatches(messages, messagesForModel, inputMessageRefs)

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
  inputMessageRefs: JsonValue[]
): JsonValue[] {
  return modelMessages.flatMap((message, index) => {
    const source = sourceMessages[index]
    if (!source || sameJson(source, message)) return []
    return [
      {
        type: 'message_override',
        reason: 'microcompact',
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
