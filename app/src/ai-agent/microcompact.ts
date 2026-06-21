import type { AgentMessage } from './core'

/**
 * Placeholder swapped in for a cleared tool result. MUST be byte-stable (no
 * timestamps / counters / ids) so re-rendering produces identical bytes and the
 * provider prompt-cache prefix is not invalidated every turn.
 */
export const MICROCOMPACT_CLEARED_TEXT = '[Old tool output cleared to save context space]'

/**
 * Tool results safe to clear because they are cheaply re-derivable. `clarify`
 * results are user answers and are deliberately excluded — they must never be
 * cleared.
 */
export const DEFAULT_COMPACTABLE_TOOLS: ReadonlySet<string> = new Set(['web_search', 'web_extract'])

export interface MicrocompactOptions {
  /** Number of most-recent compactable tool results to keep in full. */
  keepRecent: number
  /** Tool names whose results may be cleared. Defaults to web_search / web_extract. */
  compactableTools?: ReadonlySet<string>
}

/**
 * Render-time middle tier of the compaction defense: clears the content of OLD,
 * re-derivable tool results (keeping the most recent `keepRecent`), shrinking the
 * model-bound context with no LLM call. Returns a new array; the input messages
 * are never mutated and the persisted PG trajectory (the source of truth) is left
 * untouched — only the model-bound view shrinks.
 *
 * Idempotent + monotonic: an already-cleared result is returned byte-identical, so
 * re-rendering the same history yields the same bytes and the provider prompt-cache
 * prefix stays stable.
 */
export function microcompact(messages: AgentMessage[], options: MicrocompactOptions): AgentMessage[] {
  const compactable = options.compactableTools ?? DEFAULT_COMPACTABLE_TOOLS
  const keepRecent = Math.max(0, options.keepRecent)

  // Positions of every clearable tool result, oldest-first. Clearing is by age, so the slice below keeps
  // the newest `keepRecent` and clears the rest — the recent results are the ones the model is most
  // likely still reasoning over.
  const compactableIndices: number[] = []
  for (let i = 0; i < messages.length; i++) {
    const message = messages[i]!
    if (message.role === 'toolResult' && compactable.has(message.toolName)) compactableIndices.push(i)
  }
  // Nothing old enough to clear — return the input array unchanged (referential identity preserved, see
  // the callers that compare `result === input` to detect a no-op).
  if (compactableIndices.length <= keepRecent) return messages

  const clearIndices = new Set(compactableIndices.slice(0, compactableIndices.length - keepRecent))
  let changed = false
  const out = messages.map((message, index) => {
    if (!clearIndices.has(index) || message.role !== 'toolResult') return message
    // Already the placeholder: leave the exact object in place. This is the idempotency guard that keeps
    // re-rendering byte-stable — re-stamping it (even with identical text) would still be a new object,
    // and `changed` must stay false when no real content was cleared so the original array is returned.
    if (
      message.content.length === 1 &&
      message.content[0]?.type === 'text' &&
      message.content[0].text === MICROCOMPACT_CLEARED_TEXT
    ) {
      return message
    }
    changed = true
    return { ...message, content: [{ type: 'text' as const, text: MICROCOMPACT_CLEARED_TEXT }] }
  })
  return changed ? out : messages
}
