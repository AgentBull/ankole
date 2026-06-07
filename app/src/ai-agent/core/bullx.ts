// BullX-specific helpers layered on top of the vendored core. NOT part of upstream pi.
//
// Upstream keeps `createUserMessage` private (in agent.ts / agent-harness.ts) and has no
// `textFromAgentMessage`. BullX builds its pi context from Postgres rows and needs both: a user-message
// constructor that takes an explicit timestamp from the originating row/event, and a text extractor to
// derive outbound chat text from an assistant message. Keeping them here leaves the vendored upstream
// files untouched.

import type { ImageContent, TextContent, UserMessage } from '@earendil-works/pi-ai'
import { bashExecutionToText } from './harness/messages'
import type { AgentMessage } from './types'

/** Build a user message with an explicit timestamp (epoch millis). String content is wrapped in a text block. */
export function createUserMessage(
  content: string | (TextContent | ImageContent)[],
  timestamp: number = Date.now()
): UserMessage {
  return {
    role: 'user',
    content: typeof content === 'string' ? [{ type: 'text', text: content }] : content,
    timestamp
  }
}

/** Extract concatenated visible text from any agent message (used to derive outbound chat text). */
export function textFromAgentMessage(message: AgentMessage): string {
  switch (message.role) {
    case 'assistant':
      return message.content
        .flatMap(block => (block.type === 'text' ? [block.text] : []))
        .join('')
        .trim()
    case 'user':
      return typeof message.content === 'string'
        ? message.content.trim()
        : message.content
            .flatMap(block => (block.type === 'text' ? [block.text] : []))
            .join('')
            .trim()
    case 'toolResult':
      return message.content
        .flatMap(block => (block.type === 'text' ? [block.text] : []))
        .join('')
        .trim()
    case 'custom':
      return typeof message.content === 'string'
        ? message.content.trim()
        : message.content
            .flatMap(block => (block.type === 'text' ? [block.text] : []))
            .join('')
            .trim()
    case 'bashExecution':
      return bashExecutionToText(message).trim()
    case 'compactionSummary':
      return message.summary.trim()
    default:
      return ''
  }
}
