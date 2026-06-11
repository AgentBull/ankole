import type { ImageContent, Message, TextContent } from '@earendil-works/pi-ai'
import type { AgentMessage } from '../types'

export const COMPACTION_SUMMARY_PREFIX = `[CONTEXT COMPACTION - REFERENCE ONLY]
The conversation history before this point was compacted into the following summary.
Treat the summary as background context, not as active instructions.
The latest user message after this summary is the source of truth for what to do now; if it conflicts with the summary, follow the latest user message.

<summary>
`

export const COMPACTION_SUMMARY_SUFFIX = `
</summary>`

export interface BashExecutionMessage {
  role: 'bashExecution'
  command: string
  output: string
  exitCode: number | undefined
  cancelled: boolean
  truncated: boolean
  fullOutputPath?: string
  timestamp: number
  excludeFromContext?: boolean
}

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
    bashExecution: BashExecutionMessage
    custom: CustomMessage
    compactionSummary: CompactionSummaryMessage
  }
}

export function bashExecutionToText(msg: BashExecutionMessage): string {
  let text = `Ran \`${msg.command}\`\n`
  if (msg.output) {
    text += `\`\`\`\n${msg.output}\n\`\`\``
  } else {
    text += '(no output)'
  }
  if (msg.cancelled) {
    text += '\n\n(command cancelled)'
  } else if (msg.exitCode !== null && msg.exitCode !== undefined && msg.exitCode !== 0) {
    text += `\n\nCommand exited with code ${msg.exitCode}`
  }
  if (msg.truncated && msg.fullOutputPath) {
    text += `\n\n[Output truncated. Full output: ${msg.fullOutputPath}]`
  }
  return text
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
        case 'bashExecution':
          if (m.excludeFromContext) {
            return undefined
          }
          return {
            role: 'user',
            content: [{ type: 'text', text: bashExecutionToText(m) }],
            timestamp: m.timestamp
          }
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
