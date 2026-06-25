import type { ImageContent, Message, TextContent } from '@/llm'
import type { AgentMessage } from '../types'

// A compaction summary re-enters the prompt as a normal user message, so the model could mistake it for
// a fresh instruction. These wrapper strings frame it as reference-only background and state the conflict
// rule explicitly: the newest user message wins over the summary. Without this, the model tends to resume
// stale work that the latest message already cancelled or redirected.
export const COMPACTION_SUMMARY_PREFIX = `[CONTEXT COMPACTION - REFERENCE ONLY]
The conversation history before this point was compacted into the following summary.
Treat the summary as background context, not as active instructions.
The latest user message after this summary is the source of truth for what to do now; if it conflicts with the summary, follow the latest user message.

<summary>
`

export const COMPACTION_SUMMARY_SUFFIX = `
</summary>`

/**
 * In-context message that is not one of the provider's native roles. It is projected into a `user`
 * message at convert time (see {@link convertToLlm}); `display` only governs whether the UI also shows
 * it. `details` carries app-specific metadata that travels with the message but is never sent to the
 * model.
 */
export interface CustomMessage<T = unknown> {
  role: 'custom'
  customType: string
  content: string | (TextContent | ImageContent)[]
  display: boolean
  details?: T
  timestamp: number
}

/**
 * The summary that replaces compacted history. Held as its own role so the rest of the harness can
 * recognise and count it; only at convert time does it become a wrapped `user` message.
 */
export interface CompactionSummaryMessage {
  role: 'compactionSummary'
  summary: string
  /** Estimated context tokens before this compaction; telemetry only. */
  tokensBefore: number
  timestamp: number
}

// Registers the two extra roles into the harness's `AgentMessage` union via declaration merging, so
// `custom` and `compactionSummary` are first-class message kinds everywhere downstream.
declare module '../types' {
  interface CustomAgentMessages {
    custom: CustomMessage
    compactionSummary: CompactionSummaryMessage
  }
}

/**
 * Builds a {@link CompactionSummaryMessage} from a persisted compaction entry. Entries store the
 * timestamp as an ISO string; messages carry epoch ms, so it is parsed here once at the projection
 * boundary.
 */
export function createCompactionSummaryMessage(
  summary: string,
  tokensBefore: number,
  timestamp: string
): CompactionSummaryMessage {
  return {
    role: 'compactionSummary',
    summary,
    tokensBefore,
    timestamp: new Date(timestamp).getTime()
  }
}

/** Builds a {@link CustomMessage} from a persisted entry, parsing the stored ISO timestamp to epoch ms. */
export function createCustomMessage(
  customType: string,
  content: string | (TextContent | ImageContent)[],
  display: boolean,
  details: unknown | undefined,
  timestamp: string
): CustomMessage {
  return {
    role: 'custom',
    customType,
    content,
    display,
    details,
    timestamp: new Date(timestamp).getTime()
  }
}

/**
 * Lowers the harness's `AgentMessage[]` to the provider's native `Message[]` just before an LLM call.
 *
 * The synthetic roles are folded into plain `user` messages: `custom` content is normalised to a text
 * block, and `compactionSummary` is wrapped in the reference-only framing. The three native roles
 * (`user`, `assistant`, `toolResult`) are passed through by identity — untouched on purpose, because the
 * assistant tool-call blocks and their matching `toolResult` messages must stay adjacent and in the same
 * order; reshaping them here would risk splitting a tool call from its result, which providers reject.
 * Anything unrecognised maps to `undefined` and is then filtered out, so UI-only message kinds never
 * reach the provider.
 *
 * Order is preserved one-to-one (minus the dropped entries), which is what keeps the tool-call/result
 * pairing intact.
 */
export function convertToLlm(messages: AgentMessage[]): Message[] {
  return messages
    .map((m): Message | undefined => {
      switch (m.role) {
        case 'custom': {
          const content = typeof m.content === 'string' ? [{ type: 'text' as const, text: m.content }] : m.content
          return {
            role: 'user',
            content,
            timestamp: m.timestamp
          }
        }
        case 'compactionSummary':
          return {
            role: 'user',
            content: [
              { type: 'text' as const, text: COMPACTION_SUMMARY_PREFIX + m.summary + COMPACTION_SUMMARY_SUFFIX }
            ],
            timestamp: m.timestamp
          }
        case 'user':
        case 'assistant':
        case 'toolResult':
          return m
        default:
          return undefined
      }
    })
    .filter((m): m is Message => m !== undefined)
}
