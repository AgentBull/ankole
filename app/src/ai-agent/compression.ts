import { genUUIDv7 } from '@agentbull/bullx-native-addons'
import { match } from '@pleisto/active-support'
import { eq } from 'drizzle-orm'
import { DB } from '@/common/database'
import { AiAgentConversations, type JsonObject, type JsonValue } from '@/common/db-schema'
import type { AiAgentRuntimeProfile } from './config'
import type { ResolvedAiAgentModelProfile } from './config'
import { aiAgentConversationService, textContent, type AiAgentConversationService } from './conversation-service'
import {
  compact,
  convertToLlm,
  DEFAULT_COMPACTION_SETTINGS,
  prepareCompaction,
  serializeConversation,
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

    const llmTurnRefs: Array<{ callIndex: number; id: string }> = []
    const commonRunnerInput = {
      agentUid: conversation.agentUid,
      conversationId: input.conversationId,
      entries,
      llmTurnRefs,
      previousSummaryMessageId: previousSummaryEntry?.id,
      profile: input.profile,
      trigger: input.trigger
    }
    const lightResult = await compact(
      preparation.value,
      input.profile.lightModel.model,
      input.profile.lightModel.options,
      COMPACTION_FOCUS_INSTRUCTIONS,
      undefined,
      input.profile.lightModel.config.reasoning,
      this.compactionCallRunner({ ...commonRunnerInput, leaseId: genUUIDv7(), modelProfile: input.profile.lightModel })
    )
    const primaryResult = lightResult.ok
      ? undefined
      : await compact(
          preparation.value,
          input.profile.primaryModel.model,
          input.profile.primaryModel.options,
          COMPACTION_FOCUS_INSTRUCTIONS,
          undefined,
          input.profile.primaryModel.config.reasoning,
          this.compactionCallRunner({
            ...commonRunnerInput,
            leaseId: genUUIDv7(),
            modelProfile: input.profile.primaryModel
          })
        )
    const fallbackReason =
      !lightResult.ok && primaryResult && !primaryResult.ok
        ? `${lightResult.error.message}; ${primaryResult.error.message}`
        : undefined
    const result = lightResult.ok
      ? lightResult.value
      : primaryResult?.ok
        ? primaryResult.value
        : deterministicCompactionFallback(preparation.value, fallbackReason ?? lightResult.error.message)
    const summaryText = stripCompactionScratch(result.summary)
    const llmTurnIds = llmTurnRefs
      .slice()
      .sort((left, right) => left.callIndex - right.callIndex)
      .map(ref => ref.id)

    const summary = await this.conversations.appendMessage({
      conversationId: input.conversationId,
      role: 'assistant',
      kind: 'summary',
      content: textContent(summaryText),
      metadata: {
        llm_turn_id: llmTurnIds.at(-1) ?? null,
        compression: {
          source: fallbackReason ? 'deterministic_fallback' : 'pi_core_fork',
          fallback_reason: fallbackReason ?? null,
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
    llmTurnRefs: Array<{ callIndex: number; id: string }>
    previousSummaryMessageId?: string
    modelProfile: ResolvedAiAgentModelProfile
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
        model: input.modelProfile.config.model,
        parentBranchId: parentBranchIdForSummary(input.conversationId, input.previousSummaryMessageId),
        profile: input.modelProfile.profile,
        provider: input.modelProfile.config.providerId,
        reasoning: input.modelProfile.config.reasoning,
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
      input.llmTurnRefs.push({ callIndex: currentCallIndex, id: llmTurn.id })
      try {
        const response = await complete()
        await this.conversations.finishLlmTurn({
          llmTurnId: llmTurn.id,
          status: assistantStatus(response),
          response: normalizedAssistantResponse(response),
          usage: response.usage as unknown as JsonObject,
          providerMetadata: {
            pi_provider: input.modelProfile.config.piProvider,
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
          providerMetadata: { pi_provider: input.modelProfile.config.piProvider }
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

function deterministicCompactionFallback(
  preparation: {
    firstKeptEntryId: string
    messagesToSummarize: AgentMessage[]
    tokensBefore: number
    turnPrefixMessages: AgentMessage[]
  },
  reason: string
): {
  details: { modifiedFiles: string[]; readFiles: string[] }
  firstKeptEntryId: string
  summary: string
  tokensBefore: number
} {
  const messages = [...preparation.messagesToSummarize, ...preparation.turnPrefixMessages]
  const excerpt = serializeConversation(convertToLlm(messages)).slice(-12000)
  return {
    firstKeptEntryId: preparation.firstKeptEntryId,
    tokensBefore: preparation.tokensBefore,
    details: { readFiles: [], modifiedFiles: [] },
    summary: [
      '## Deterministic Compaction Fallback',
      '',
      'The LLM summarizer failed twice. This checkpoint preserves a raw excerpt of the compacted conversation so the next turn can continue with explicit evidence instead of dropping history.',
      '',
      `Failure: ${reason}`,
      '',
      '## Raw Conversation Excerpt',
      '',
      excerpt || 'No serializable messages were available.'
    ].join('\n')
  }
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
  return match(message.stopReason)
    .with('aborted', () => 'cancelled' as const)
    .with('error', () => 'failed' as const)
    .otherwise(() => 'succeeded' as const)
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
