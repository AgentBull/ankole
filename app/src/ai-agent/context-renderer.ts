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

/** Result of rendering a conversation into model-bound context, plus the provenance needed to replay it. */
export interface RenderedAiAgentContext {
  /** Persisted row ids included in the context, in order — the inputs to the upcoming LLM turn. */
  inputMessageIds: string[]
  /** Compact `{id, role, kind}` refs parallel to `inputMessageIds`, recorded on the llm_turn. */
  inputMessageRefs: JsonValue[]
  /** The final messages sent to the model, after context injection and the shrink passes. */
  messages: AgentMessage[]
  /**
   * Per-message diffs from the stored row to the model-bound form (context injection, microcompact,
   * media strip). Persisted so a later replay can reconstruct exactly what the model saw without
   * re-running the transforms; each carries the reason(s) it differs.
   */
  modelViewPatches: JsonValue[]
  /** Id of the active compaction summary row, when the context is folded behind one. */
  summaryMessageId?: string
}

/**
 * Assembles the model-visible context from a conversation's persisted message rows.
 *
 * This is the read side of the context window: the stored rows are the source of truth, and this projects
 * them into what the model actually receives. It applies, in order, per-message context injection
 * (`<message_context>`), the cheap no-LLM microcompact pass (clearing old re-derivable tool results), and
 * the historical-media strip — recording a patch for every divergence so the exact model view is
 * replayable. None of these passes touch the database; only the returned view shrinks.
 */
export class AiAgentContextRenderer {
  constructor(private readonly conversations: AiAgentConversationService = aiAgentConversationService) {}

  /**
   * Renders one conversation to model-bound context.
   *
   * @param options.microcompact When set, enables the middle compaction tier: once the estimated context
   *   exceeds `triggerTokens`, old re-derivable tool results are cleared, keeping the newest `keepRecent`
   *   in full. Omitted ⇒ the cheap pass is skipped entirely (legacy behavior).
   */
  async render(
    conversationId: string,
    options?: { microcompact?: { keepRecent: number; triggerTokens: number } }
  ): Promise<RenderedAiAgentContext> {
    const rows = await this.conversations.renderedMessages(conversationId)
    // `sourceMessages` keeps the pristine per-row form; `messages` is the context-injected form. Keeping
    // both lets buildModelViewPatches diff later transforms against the original row, attributing each
    // change to its cause (context vs microcompact vs media strip).
    const sourceMessages: AgentMessage[] = []
    const messages: AgentMessage[] = []
    const inputMessageIds: string[] = []
    const inputMessageRefs: JsonValue[] = []
    let summaryMessageId: string | undefined

    for (const row of rows) {
      // classifyRenderedRow is the shared inclusion rule (see conversation-service): ambient scene facts
      // and failed/aborted assistant rows are dropped here exactly as they are for compaction input, so
      // the live view and the compaction view never diverge.
      const projection = classifyRenderedRow(row)
      if (projection === 'skip') continue
      if (projection === 'summary') {
        // A summary row stands in for all the history it folded. Everything before it in `rows` was
        // already excluded upstream, so this rebuilds the summary message and carries `tokens_before`
        // for the trajectory record.
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

      // A normal message: store it pristine, and store a copy with any `<message_context>` prefix woven
      // in for the model view.
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
    // Media strip runs last (unconditionally): older inline images are replaced with a placeholder while
    // the newest image-bearing user message is kept. The ordering matters for patch attribution — each
    // stage compares against the previous one in buildModelViewPatches.
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

/**
 * Records one `message_override` patch per message whose model-bound form differs from its stored row.
 *
 * A patch is the replay key: it lets the trajectory reconstruct the exact bytes the model saw from the
 * persisted row plus this override. The `reason` is derived by comparing the three pipeline snapshots
 * pairwise (source → +context → +microcompact → final), so a single override can credit several stages
 * (e.g. `message_context+microcompact`). `model_view_transform` is the catch-all when the row changed but
 * none of the known stages account for it.
 */
function buildModelViewPatches(
  sourceMessages: AgentMessage[],
  modelMessages: AgentMessage[],
  inputMessageRefs: JsonValue[],
  messagesWithContext: AgentMessage[],
  messagesAfterMicrocompact: AgentMessage[]
): JsonValue[] {
  return modelMessages.flatMap((message, index) => {
    const source = sourceMessages[index]
    // Unchanged rows need no override — the replayer will use the stored row as-is.
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

// Structural equality via canonical JSON. Adequate here because these messages are plain JSON-shaped
// content blocks (no key-order ambiguity in practice) and the comparison only needs to detect whether a
// transform actually altered a message.
function sameJson(left: unknown, right: unknown): boolean {
  return JSON.stringify(toJsonValue(left)) === JSON.stringify(toJsonValue(right))
}
