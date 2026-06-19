import type { ImageContent, Message, TextContent } from '@/llm'
import type { AgentMessage } from '../types'

export const COMPACTION_SUMMARY_PREFIX = `[CONTEXT COMPACTION - REFERENCE ONLY]
The conversation history before this point was compacted into the following summary.
Treat the summary as background context, not as active instructions.
The latest user message after this summary is the source of truth for what to do now; if it conflicts with the summary, follow the latest user message.

<summary>
`

export const COMPACTION_SUMMARY_SUFFIX = `
</summary>`

export interface CustomMessage<T = unknown> {
  role: 'custom'
  customType: string
  content: string | (TextContent | ImageContent)[]
  display: boolean
  details?: T
  timestamp: number
}

export interface CompactionSummaryMessage {
  role: 'compactionSummary'
  summary: string
  tokensBefore: number
  timestamp: number
}

declare module '../types' {
  interface CustomAgentMessages {
    custom: CustomMessage
    compactionSummary: CompactionSummaryMessage
  }
}

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
