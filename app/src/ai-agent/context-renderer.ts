import { createCompactionSummaryMessage, type AgentMessage } from './core'
import {
  aiAgentConversationService,
  classifyRenderedRow,
  textFromContent,
  type AiAgentConversationService
} from './conversation-service'
import { numberFromPath } from '@/common/json'

export interface RenderedAiAgentContext {
  inputMessageIds: string[]
  messages: AgentMessage[]
  summaryMessageId?: string
}

export class AiAgentContextRenderer {
  constructor(private readonly conversations: AiAgentConversationService = aiAgentConversationService) {}

  async render(conversationId: string): Promise<RenderedAiAgentContext> {
    const rows = await this.conversations.renderedMessages(conversationId)
    const messages: AgentMessage[] = []
    const inputMessageIds: string[] = []
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
        continue
      }

      messages.push(row.agentMessage as unknown as AgentMessage)
      inputMessageIds.push(row.id)
    }

    return {
      messages,
      inputMessageIds,
      summaryMessageId
    }
  }
}

export const aiAgentContextRenderer = new AiAgentContextRenderer()
