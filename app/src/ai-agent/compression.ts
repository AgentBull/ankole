import { genUUIDv7 } from '@agentbull/bullx-native-addons'
import { eq } from 'drizzle-orm'
import { DB } from '@/common/database'
import { AiAgentConversations, type JsonObject, type JsonValue } from '@/common/db-schema'
import type { AiAgentRuntimeProfile } from './config'
import { aiAgentConversationService, textContent, type AiAgentConversationService } from './conversation-service'
import {
  compact,
  DEFAULT_COMPACTION_SETTINGS,
  prepareCompaction,
  type AgentMessage,
  type CompactionLlmCallContext,
  type CompactionLlmCallRunner,
  type SessionTreeEntry
} from './core'
import { toJsonValue } from '@/common/json'

/**
 * Extra summarization focus appended (as "Additional focus: …") to pi's base
 * compaction prompt via compact()'s customInstructions hook: a brief chronological
 * `<analysis>` scratchpad (discarded from the stored summary) plus verbatim
 * identifier preservation so the post-compaction turn resumes without drift.
 */
export const COMPACTION_FOCUS_INSTRUCTIONS =
  "First, in an <analysis> block, walk the conversation chronologically and note each step's intent, decisions, and any errors and their fixes (this block is scratch work and will be discarded). Then write the summary. Preserve verbatim — never paraphrase — file paths, function and identifier names, error messages, command lines, and IDs/UUIDs; when the latest task is unfinished, quote its exact instruction so work resumes without drift."

/** Strip the throwaway `<analysis>` scratchpad from a generated summary. */
export function stripCompactionScratch(summary: string): string {
  return summary.replace(/<analysis>[\s\S]*?<\/analysis>/gi, '').trim()
}

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
    const previousSummaryEntry = [...entries].reverse().find(entry => entry.type === 'compaction')
    const preparation = prepareCompaction(entries, {
      ...DEFAULT_COMPACTION_SETTINGS,
      enabled: input.profile.compression.enabled,
      reserveTokens: input.profile.compression.reserveTokens,
      keepRecentTokens: input.profile.compression.keepRecentTokens
    })
    if (!preparation.ok) throw preparation.error

    if (!preparation.value) {
      return undefined
    }

    const llmTurnIds: string[] = []
    const callRunner = this.compactionCallRunner({
      agentUid: conversation.agentUid,
      conversationId: input.conversationId,
      entries,
      leaseId: genUUIDv7(),
      llmTurnIds,
      previousSummaryMessageId: previousSummaryEntry?.id,
      profile: input.profile,
      trigger: input.trigger
    })
    const compacted = await compact(
      preparation.value,
      input.profile.lightModel.model,
      input.profile.lightModel.options,
      COMPACTION_FOCUS_INSTRUCTIONS,
      undefined,
      input.profile.lightModel.config.reasoning,
      callRunner
    )
    if (!compacted.ok) throw compacted.error
    const result = compacted.value
    const summaryText = stripCompactionScratch(result.summary)

    const summary = await this.conversations.appendMessage({
      conversationId: input.conversationId,
      role: 'assistant',
      kind: 'summary',
      content: textContent(summaryText),
      metadata: {
        llm_turn_id: llmTurnIds.at(-1) ?? null,
        compression: {
          source: 'pi_core_fork',
          trigger: input.trigger,
          first_kept_message_id: result.firstKeptEntryId,
          llm_turn_ids: llmTurnIds,
          tokens_before: result.tokensBefore,
          previous_summary: previousSummaryEntry?.summary ?? null,
          upstream_commit: '89a92207f1c9303d53d822fd9b0ac21578834cb4'
        }
      }
    })

    return { ...result, summary: summaryText, summaryMessageId: summary.id }
  }

  private compactionCallRunner(input: {
    agentUid: string
    conversationId: string
    entries: SessionTreeEntry[]
    leaseId: string
    llmTurnIds: string[]
    previousSummaryMessageId?: string
    profile: AiAgentRuntimeProfile
    trigger: 'manual_command' | 'provider_context_overflow' | 'threshold'
  }): CompactionLlmCallRunner {
    const refsByMessage = messageRefsByObject(input.entries)
    let callIndex = 0
    return async (context, complete) => {
      const currentCallIndex = callIndex++
      const requestRefs = refsForCompactionMessages(context.sourceMessages, refsByMessage)
      const llmTurn = await this.conversations.startLlmTurn({
        agentUid: input.agentUid,
        branchId: branchIdForSummary(input.conversationId, input.previousSummaryMessageId),
        callIndex: currentCallIndex,
        conversationId: input.conversationId,
        kind: input.trigger === 'provider_context_overflow' ? 'overflow_retry' : 'compression',
        leaseId: input.leaseId,
        model: input.profile.lightModel.config.model,
        parentBranchId: parentBranchIdForSummary(input.conversationId, input.previousSummaryMessageId),
        profile: 'light',
        provider: input.profile.lightModel.config.providerId,
        reasoning: input.profile.lightModel.config.reasoning,
        inputMessageIds: inputMessageIdsFromRefs(requestRefs),
        inputSummaryMessageId: input.previousSummaryMessageId ?? null,
        requestContext: {
          llm_message_count: context.messages.length,
          llm_message_roles: context.messages.map(message => message.role),
          max_tokens: context.maxTokens,
          previous_summary_message_id: input.previousSummaryMessageId ?? null,
          summary_kind: context.kind,
          system_prompt: context.systemPrompt,
          trigger: input.trigger,
          tool_count: 0,
          tool_names: []
        },
        requestPatches: [llmToolDefinitionsPatch([]), llmRequestPatch('compaction', context)],
        requestRefs
      })
      input.llmTurnIds.push(llmTurn.id)
      try {
        const response = await complete()
        await this.conversations.finishLlmTurn({
          llmTurnId: llmTurn.id,
          status: assistantStatus(response),
          response: normalizedAssistantResponse(response),
          usage: response.usage as unknown as JsonObject,
          providerMetadata: {
            pi_provider: input.profile.lightModel.config.piProvider,
            response_id: response.responseId ?? null,
            response_model: response.responseModel ?? null
          }
        })
        return response
      } catch (error) {
        await this.conversations.finishLlmTurn({
          llmTurnId: llmTurn.id,
          status: 'failed',
          response: { error: error instanceof Error ? error.message : String(error) },
          providerMetadata: { pi_provider: input.profile.lightModel.config.piProvider }
        })
        throw error
      }
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

function messageRefsByObject(entries: SessionTreeEntry[]): WeakMap<object, JsonValue> {
  const refs = new WeakMap<object, JsonValue>()
  for (const entry of entries) {
    if (entry.type !== 'message') continue
    const message = entry.message as AgentMessage
    if (message && typeof message === 'object') {
      refs.set(message, {
        type: 'ai_agent_message',
        id: entry.id,
        role: message.role
      })
    }
  }
  return refs
}

function refsForCompactionMessages(messages: AgentMessage[], refsByMessage: WeakMap<object, JsonValue>): JsonValue[] {
  return messages.map((message, index) => {
    if (message && typeof message === 'object') {
      const ref = refsByMessage.get(message)
      if (ref) return ref
    }
    return {
      type: 'inline_agent_message',
      index,
      role: typeof message === 'object' && message !== null && 'role' in message ? message.role : null,
      message: toJsonValue(message)
    }
  })
}

function inputMessageIdsFromRefs(refs: JsonValue[]): string[] {
  return refs.flatMap(ref => {
    if (typeof ref !== 'object' || ref === null || Array.isArray(ref)) return []
    if (ref.type !== 'ai_agent_message' || typeof ref.id !== 'string') return []
    return [ref.id]
  })
}

function branchIdForSummary(conversationId: string, summaryMessageId: string | undefined): string {
  return summaryMessageId ? `summary:${summaryMessageId}` : `conversation:${conversationId}:root`
}

function parentBranchIdForSummary(conversationId: string, summaryMessageId: string | undefined): string | null {
  return summaryMessageId ? `conversation:${conversationId}:root` : null
}

function llmRequestPatch(reason: string, context: CompactionLlmCallContext): JsonValue {
  return {
    type: 'llm_request',
    reason,
    summary_kind: context.kind,
    system_prompt: context.systemPrompt,
    messages: toJsonValue(context.messages)
  }
}

function llmToolDefinitionsPatch(tools: JsonValue[]): JsonValue {
  return {
    type: 'llm_tool_definitions',
    tools
  }
}

function assistantStatus(message: { stopReason: string }): 'succeeded' | 'failed' | 'cancelled' {
  return message.stopReason === 'aborted' ? 'cancelled' : message.stopReason === 'error' ? 'failed' : 'succeeded'
}

function normalizedAssistantResponse(message: {
  content: unknown
  errorMessage?: string
  responseId?: string
  stopReason: string
}): JsonObject {
  const text = Array.isArray(message.content)
    ? message.content
        .flatMap(block =>
          typeof block === 'object' && block !== null && !Array.isArray(block) && block.type === 'text'
            ? [(block as { text?: unknown }).text]
            : []
        )
        .filter((text): text is string => typeof text === 'string')
        .join('\n')
    : ''
  return {
    content: toJsonValue(message.content),
    text,
    stop_reason: message.stopReason,
    error_message: message.errorMessage ?? null,
    response_id: message.responseId ?? null
  }
}
