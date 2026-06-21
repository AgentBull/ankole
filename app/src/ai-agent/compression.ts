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
import { COMPACTION_FOCUS_INSTRUCTIONS } from './prompts/compression-prompt'

export { COMPACTION_FOCUS_INSTRUCTIONS } from './prompts/compression-prompt'

/**
 * Strips the throwaway `<analysis>` scratchpad from a generated summary.
 *
 * The summarizer prompt asks the model to think out loud inside `<analysis>...</analysis>` before
 * writing the real summary. That scratch is for the model's own benefit, not for future context, so it
 * is removed before the summary is persisted — otherwise every checkpoint would carry the previous
 * checkpoint's reasoning forward and waste tokens.
 */
export function stripCompactionScratch(summary: string): string {
  return summary.replace(/<analysis>[\s\S]*?<\/analysis>/gi, '').trim()
}

/**
 * Database-aware driver for the LLM-summarization compaction tier (the expensive, smarter tier; the
 * cheap no-LLM tier is `microcompact.ts`). It wraps the pure planning/summarizing logic in
 * `core/harness/compaction` with the persistence this app needs: it reads the conversation tree, brackets
 * every summarizer call in an `llm_turn` row for replay/telemetry, and writes the resulting summary back
 * as a `summary` message so future renders fold the old history behind it.
 */
export class AiAgentCompressionService {
  constructor(private readonly conversations: AiAgentConversationService = aiAgentConversationService) {}

  /**
   * Compresses one conversation, persisting a summary message that replaces an old prefix of history.
   *
   * The summarizer is tried cheapest-first and never allowed to drop history outright: the light model
   * runs first, the primary model is the fallback only if the light one fails, and a deterministic raw
   * excerpt is the last resort if both fail. So a flaky summarizer degrades to coarser context, never to
   * lost context. Returns `undefined` when there is nothing worth compacting (see `prepareCompaction`).
   *
   * @param input.trigger Why compaction is running — a user `/compact` command, the preflight threshold
   *   check, or a provider context-overflow retry. Recorded on the summary and the llm_turns, and it
   *   selects the llm_turn `kind` (overflow retries are tagged separately).
   */
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
    // The newest prior summary, if any. It anchors the summary branch ids and is threaded into the
    // prompt as `previousSummary` so the model updates the existing summary instead of writing a fresh
    // one — that is how context accumulates across repeated compactions rather than being re-derived.
    const previousSummaryEntry = [...entries].reverse().find(entry => entry.type === 'compaction')
    const preparation = prepareCompaction(entries, {
      ...DEFAULT_COMPACTION_SETTINGS,
      enabled: input.profile.compression.enabled,
      reserveTokens: input.profile.compression.reserveTokens,
      keepRecentTokens: input.profile.compression.keepRecentTokens
    })
    if (!preparation.ok) throw preparation.error

    // No useful cut point (empty path, or the tail is already a summary). Nothing to do — let the caller
    // proceed with the context as-is.
    if (!preparation.value) {
      return undefined
    }

    // Each summarizer attempt may make several LLM calls (history + split-turn prefix); collect their
    // turn ids here so the persisted summary can point back at the exact calls that produced it.
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
    // Tier 1: the light (cheap/fast) model. Summarization is mostly mechanical, so the small model
    // usually suffices and saves cost/latency versus reaching for the primary model every time.
    const lightResult = await compact(
      preparation.value,
      input.profile.lightModel.model,
      input.profile.lightModel.options,
      COMPACTION_FOCUS_INSTRUCTIONS,
      undefined,
      input.profile.lightModel.config.reasoning,
      this.compactionCallRunner({ ...commonRunnerInput, leaseId: genUUIDv7(), modelProfile: input.profile.lightModel })
    )
    // Tier 2: the primary model, attempted only when the light one failed. Each tier gets its own lease
    // id so the two attempts are distinct llm_turn groups in the trajectory.
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
    // Set only when BOTH model tiers failed; carries both error messages into the deterministic fallback
    // and is recorded on the summary so an operator can see why the LLM path was abandoned.
    const fallbackReason =
      !lightResult.ok && primaryResult && !primaryResult.ok
        ? `${lightResult.error.message}; ${primaryResult.error.message}`
        : undefined
    // Tier 3: take whichever model succeeded; if neither did, fall back to a deterministic raw excerpt
    // rather than throwing — losing the turn would be worse than a coarse, un-summarized checkpoint.
    const result = lightResult.ok
      ? lightResult.value
      : primaryResult?.ok
        ? primaryResult.value
        : deterministicCompactionFallback(preparation.value, fallbackReason ?? lightResult.error.message)
    const summaryText = stripCompactionScratch(result.summary)
    // Order the recorded turn ids by call index so the persisted list reads in execution order regardless
    // of which tiers ran or how their awaits interleaved.
    const llmTurnIds = llmTurnRefs
      .slice()
      .sort((left, right) => left.callIndex - right.callIndex)
      .map(ref => ref.id)

    // Persist the summary as a `summary` message. From here on, renders fold everything up to
    // `first_kept_message_id` behind this row; `tokens_before` and the turn ids are kept for auditing how
    // much the checkpoint saved and exactly which calls produced it.
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
          // Pins the upstream pi-harness commit the summarization logic was forked from, so a future
          // re-sync can diff against the exact source revision.
          upstream_commit: '89a92207f1c9303d53d822fd9b0ac21578834cb4'
        }
      }
    })

    return { ...result, summary: summaryText, summaryMessageId: summary.id }
  }

  /**
   * Builds the {@link CompactionLlmCallRunner} that the pure `compact` routine calls for each summarizer
   * LLM call. The harness stays database-agnostic; this closure is where each call is wrapped in a started
   * → finished `llm_turn` row so the summarization is replayable and observable like any other turn.
   *
   * The `complete` thunk is the bare model call. It is bracketed: start the turn, run it, finish it with
   * status/usage on success, and finish it as `failed` on a thrown error before re-raising — so a row is
   * never left dangling in the `started` state.
   */
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
    // Identity map from each live message object to its stable row ref, computed once. The summarizer may
    // be handed the same objects across its history/turn-prefix calls; this lets each call record which
    // persisted messages it consumed (by id) instead of re-snapshotting their content.
    const refsByMessage = messageRefsByObject(input.entries)
    let callIndex = 0
    return async (context, complete) => {
      // Monotonic per-runner index so the turns of this compaction sort into call order even though they
      // share a lease. Captured before any await so concurrent calls cannot collide on it.
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
            llm_provider: input.modelProfile.config.llmProvider,
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
          providerMetadata: { llm_provider: input.modelProfile.config.llmProvider }
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

/**
 * Builds an identity map from each entry's live message object to a compact `{id, role}` ref.
 *
 * Keyed by object identity (a {@link WeakMap}) rather than content so that, later, a message the
 * summarizer was given can be matched back to its persisted row without comparing or re-serializing
 * bodies. Entries that are not messages have no row to point at and are skipped.
 */
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

/**
 * Resolves each message the summarizer saw to a provenance ref for the llm_turn record.
 *
 * A message that came straight from a persisted entry resolves to its `{id, role}` ref. Anything else —
 * a summary or turn-prefix message that the harness synthesized in memory and never stored — has no row,
 * so it is inlined verbatim (`inline_agent_message`) so replay still has its full content.
 */
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

/** Pulls just the persisted-message ids out of a ref list, dropping inlined (un-stored) messages. */
function inputMessageIdsFromRefs(refs: JsonValue[]): string[] {
  return refs.flatMap(ref => {
    if (typeof ref !== 'object' || ref === null || Array.isArray(ref)) return []
    if (ref.type !== 'ai_agent_message' || typeof ref.id !== 'string') return []
    return [ref.id]
  })
}

/**
 * Last-resort summary used when both model tiers fail. Instead of dropping the folded history, it keeps a
 * raw tail excerpt of it so the next turn continues from explicit evidence rather than a blank gap.
 *
 * The excerpt is the LAST 12000 characters of the serialized to-be-folded messages — the most recent
 * context is the most relevant to what comes next, and the cap bounds how much room this checkpoint
 * itself costs. The failure reason is embedded so the degraded state is visible in the transcript.
 */
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

// Branch ids place each compaction on the conversation's replay tree. A first-ever summary branches off
// the conversation root; a re-compaction branches off the prior summary, so the chain of summaries is
// walkable. The parent helper records the other end of that edge (null for the root case).
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

/** Maps a model stop reason to the llm_turn lifecycle status: abort is a cancel, error is a failure. */
function assistantStatus(message: { stopReason: string }): 'succeeded' | 'failed' | 'cancelled' {
  return match(message.stopReason)
    .with('aborted', () => 'cancelled' as const)
    .with('error', () => 'failed' as const)
    .otherwise(() => 'succeeded' as const)
}

/**
 * Flattens a summarizer response into the JSON stored on the llm_turn. Alongside the raw content it
 * precomputes a plain-text join of the text blocks, so consumers reading the turn (replay, debugging)
 * have the summary text directly without re-walking the content block array.
 */
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
