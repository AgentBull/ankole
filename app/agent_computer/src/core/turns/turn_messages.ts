import type { AgentMessage } from '../types'
import type { AssistantMessage, Message, Model } from '../../ai-gateway-client/ankole'
import { TOOL_RESULT_MAX_CHARS } from './turn_config'
import { isRecord, safeJsonStringify } from '../../common/json-utils'

export function userMessage(text: string): Message {
  return {
    role: 'user',
    content: [{ type: 'text', text }],
    timestamp: Date.now()
  }
}

export function assistantMessage(model: Model | undefined, text: string): AssistantMessage {
  return {
    role: 'assistant',
    content: [{ type: 'text', text }],
    api: model?.api ?? 'unknown',
    provider: model?.provider ?? 'unknown',
    model: model?.id ?? 'unknown',
    usage: {
      input: 0,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }
    },
    stopReason: 'stop',
    timestamp: Date.now()
  }
}

export function isLlmMessage(message: AgentMessage): message is Message {
  return isRecord(message) && (message.role === 'user' || message.role === 'assistant' || message.role === 'toolResult')
}

export function latestAssistantMessage(messages: AgentMessage[]): AssistantMessage | undefined {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index]
    if (isRecord(message) && message.role === 'assistant') {
      return message as AssistantMessage
    }
  }
}

export function assistantText(message: AssistantMessage | undefined): string {
  if (!message) return ''
  return message.content
    .map(block => (block.type === 'text' ? block.text : undefined))
    .filter((text): text is string => typeof text === 'string')
    .join('\n')
    .trim()
}

export function stripCompactionScratch(summary: string): string {
  return summary.replace(/<analysis>[\s\S]*?<\/analysis>/gi, '').trim()
}

export function serializeConversationForCompression(messages: AgentMessage[]): string {
  const parts: string[] = []

  for (const message of messages) {
    if (!isLlmMessage(message)) continue

    if (message.role === 'user') {
      const content = messageContentText(message.content)
      if (content) parts.push(`[User]: ${content}`)
      continue
    }

    if (message.role === 'assistant') {
      const textParts: string[] = []
      const thinkingParts: string[] = []
      const toolCalls: string[] = []

      for (const block of message.content) {
        if (block.type === 'text') {
          textParts.push(block.text)
        } else if (block.type === 'thinking') {
          thinkingParts.push(block.thinking)
        } else if (block.type === 'toolCall') {
          const args = Object.entries(block.arguments as Record<string, unknown>)
            .map(([key, value]) => `${key}=${safeJsonStringify(value)}`)
            .join(', ')
          toolCalls.push(`${block.name}(${args})`)
        }
      }

      if (thinkingParts.length > 0) parts.push(`[Assistant thinking]: ${thinkingParts.join('\n')}`)
      if (textParts.length > 0) parts.push(`[Assistant]: ${textParts.join('\n')}`)
      if (toolCalls.length > 0) parts.push(`[Assistant tool calls]: ${toolCalls.join('; ')}`)
      continue
    }

    if (message.role === 'toolResult') {
      const content = messageContentText(message.content)
      if (content) parts.push(`[Tool result]: ${truncateForSummary(content, TOOL_RESULT_MAX_CHARS)}`)
    }
  }

  return parts.join('\n\n')
}

export function estimateCompressionTokens(message: AgentMessage): number {
  if (!isLlmMessage(message)) return 0

  if (message.role === 'assistant') {
    let chars = 0
    for (const block of message.content) {
      if (block.type === 'text') {
        chars += block.text.length
      } else if (block.type === 'thinking') {
        continue
      } else if (block.type === 'toolCall') {
        chars += block.name.length + safeJsonStringify(block.arguments).length
      }
    }
    return Math.ceil(chars / 4)
  }

  return Math.ceil(messageContentText(message.content).length / 4)
}

export function messageContentText(content: Message['content']): string {
  if (typeof content === 'string') return content
  return content
    .map(block => (block.type === 'text' ? block.text : undefined))
    .filter((text): text is string => typeof text === 'string')
    .join('\n')
}

export function summarizeAgentMessages(messages: AgentMessage[]): string {
  return messages
    .map(message => {
      if (!isRecord(message)) return 'unknown'
      if (message.role === 'assistant') {
        const blocks = Array.isArray(message.content)
          ? message.content
              .map(block => {
                if (!isRecord(block)) return 'block'
                if (block.type === 'text') return `text:${String(block.text ?? '').slice(0, 80)}`
                if (block.type === 'toolCall') return `toolCall:${String(block.name ?? '')}`
                return String(block.type ?? 'block')
              })
              .join(',')
          : 'no-content'
        return `assistant(${String(message.stopReason ?? 'unknown')} ${blocks})`
      }
      if (message.role === 'toolResult') {
        return `toolResult(${String(message.toolName ?? 'unknown')} error=${String(message.isError ?? false)})`
      }
      if (message.role === 'user') {
        return 'user'
      }
      return String(message.role ?? 'unknown')
    })
    .join(' -> ')
}

export function storedContentText(content: unknown): string {
  if (typeof content === 'string') return content
  if (Array.isArray(content)) {
    return content
      .map(part => {
        if (typeof part === 'string') return part
        if (isRecord(part) && typeof part.text === 'string') return part.text
        return undefined
      })
      .filter((part): part is string => part !== undefined)
      .join('\n')
  }
  return ''
}

function truncateForSummary(text: string, maxChars: number): string {
  if (text.length <= maxChars) return text
  const truncatedChars = text.length - maxChars
  return `${text.slice(0, maxChars)}\n\n[... ${truncatedChars} more characters truncated]`
}
