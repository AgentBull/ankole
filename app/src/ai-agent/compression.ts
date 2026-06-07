import { eq } from 'drizzle-orm'
import { DB } from '@/common/database'
import { AiAgentConversations, type JsonObject } from '@/common/db-schema'
import type { AiAgentRuntimeProfile } from './config'
import { aiAgentConversationService, textContent, type AiAgentConversationService } from './conversation-service'
import { compact, DEFAULT_COMPACTION_SETTINGS, prepareCompaction } from './core'

export class AiAgentCompressionService {
  constructor(private readonly conversations: AiAgentConversationService = aiAgentConversationService) {}

  async compress(input: {
    conversationId: string
    profile: AiAgentRuntimeProfile
    trigger: 'manual_command' | 'provider_context_overflow' | 'threshold'
  }) {
    const [conversation] = await DB.select()
      .from(AiAgentConversations)
      .where(eq(AiAgentConversations.id, input.conversationId))
      .limit(1)
    if (!conversation) throw new AiAgentCompressionError(`Unknown conversation ${input.conversationId}`)

    const entries = await this.conversations.sessionEntries(input.conversationId)
    const previousSummary = [...entries].reverse().find(entry => entry.type === 'compaction')?.summary
    const inputMessageIds = entries.flatMap(entry => (entry.type === 'message' ? [entry.id] : []))

    const llmTurn = await this.conversations.startLlmTurn({
      agentUid: conversation.agentUid,
      conversationId: input.conversationId,
      kind: input.trigger === 'provider_context_overflow' ? 'overflow_retry' : 'compression',
      profile: 'light',
      provider: input.profile.lightModel.config.providerId,
      model: input.profile.lightModel.config.model,
      reasoning: input.profile.lightModel.config.reasoning,
      inputMessageIds,
      requestContext: { trigger: input.trigger, previous_summary: Boolean(previousSummary) }
    })

    try {
      const preparation = prepareCompaction(entries, {
        ...DEFAULT_COMPACTION_SETTINGS,
        enabled: input.profile.compression.enabled,
        reserveTokens: input.profile.compression.reserveTokens,
        keepRecentTokens: input.profile.compression.keepRecentTokens
      })
      if (!preparation.ok) throw preparation.error

      if (!preparation.value) {
        await this.conversations.finishLlmTurn({
          llmTurnId: llmTurn.id,
          status: 'succeeded',
          response: { noop: true, trigger: input.trigger }
        })
        return undefined
      }

      const compacted = await compact(
        preparation.value,
        input.profile.lightModel.model,
        input.profile.lightModel.options,
        undefined,
        undefined,
        input.profile.lightModel.config.reasoning
      )
      if (!compacted.ok) throw compacted.error
      const result = compacted.value

      const summary = await this.conversations.appendMessage({
        conversationId: input.conversationId,
        role: 'assistant',
        kind: 'summary',
        content: textContent(result.summary),
        metadata: {
          llm_turn_id: llmTurn.id,
          compression: {
            source: 'pi_core_fork',
            trigger: input.trigger,
            first_kept_message_id: result.firstKeptEntryId,
            tokens_before: result.tokensBefore,
            previous_summary: previousSummary ?? null,
            upstream_commit: '89a92207f1c9303d53d822fd9b0ac21578834cb4'
          }
        }
      })

      await this.conversations.finishLlmTurn({
        llmTurnId: llmTurn.id,
        status: 'succeeded',
        response: {
          summary_message_id: summary.id,
          summary: result.summary,
          trigger: input.trigger
        },
        usage: {},
        providerMetadata: { pi_provider: input.profile.lightModel.config.piProvider } as JsonObject
      })

      return { ...result, summaryMessageId: summary.id }
    } catch (error) {
      await this.conversations.finishLlmTurn({
        llmTurnId: llmTurn.id,
        status: 'failed',
        response: { error: error instanceof Error ? error.message : String(error) }
      })
      throw error
    }
  }
}

export const aiAgentCompressionService = new AiAgentCompressionService()

export class AiAgentCompressionError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'AiAgentCompressionError'
  }
}
