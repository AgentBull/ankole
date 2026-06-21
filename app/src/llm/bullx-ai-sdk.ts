import type { ModelMessage, ProviderOptions } from './provider-utils'
import type { LanguageModelUsage } from './types'
import {
  calculateCost,
  ZERO_USAGE,
  type AssistantMessage,
  type Message,
  type Model,
  type SimpleStreamOptions
} from './bullx'

/** Converts BullX's durable transcript format into the AI SDK wire format used by provider calls. */
export function convertBullXMessagesToModelMessages(messages: Message[]): ModelMessage[] {
  return messages.map(message => {
    if (message.role === 'user') {
      return {
        role: 'user',
        content:
          typeof message.content === 'string'
            ? message.content
            : message.content.map(block =>
                block.type === 'text'
                  ? { type: 'text' as const, text: block.text }
                  : { type: 'image' as const, image: block.data, mediaType: block.mimeType }
              )
      }
    }

    if (message.role === 'assistant') {
      return {
        role: 'assistant',
        content: message.content.map(block => {
          if (block.type === 'text') return { type: 'text' as const, text: block.text }
          if (block.type === 'thinking') return { type: 'reasoning' as const, text: block.thinking }
          return {
            type: 'tool-call' as const,
            toolCallId: block.id,
            toolName: block.name,
            input: block.arguments
          }
        })
      }
    }

    const text = message.content
      .map(block => (block.type === 'text' ? block.text : `[image:${block.mimeType}]`))
      .join('\n')
    return {
      role: 'tool',
      content: [
        {
          type: 'tool-result',
          toolCallId: message.toolCallId,
          toolName: message.toolName,
          output: message.isError
            ? { type: 'error-text' as const, value: text }
            : { type: 'text' as const, value: text }
        }
      ]
    }
  })
}

/** Builds a BullX assistant message with stable defaults for error paths and provider calls without usage data. */
export function createBullXAssistantMessage(
  model: Model<any>,
  stopReason: AssistantMessage['stopReason'],
  content: AssistantMessage['content'],
  extra: Partial<AssistantMessage> = {}
): AssistantMessage {
  return {
    role: 'assistant',
    content,
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: { ...ZERO_USAGE, cost: { ...ZERO_USAGE.cost } },
    stopReason,
    timestamp: Date.now(),
    ...extra
  }
}

/** Collapses AI SDK finish reasons into the smaller BullX stop-reason set persisted by the agent runtime. */
export function toBullXStopReason(reason: string): AssistantMessage['stopReason'] {
  if (reason === 'length') return 'length'
  if (reason === 'tool-calls') return 'toolUse'
  if (reason === 'error') return 'error'
  return 'stop'
}

/** Normalizes provider usage into BullX token buckets and computes cost in the same pass. */
export function toBullXUsage(usage: LanguageModelUsage | undefined, model: Model<any>): AssistantMessage['usage'] {
  const input = usage?.inputTokens ?? 0
  const output = usage?.outputTokens ?? 0
  const cacheRead = usage?.inputTokenDetails?.cacheReadTokens ?? 0
  const cacheWrite = usage?.inputTokenDetails?.cacheWriteTokens ?? 0
  const normalized = {
    input,
    output,
    cacheRead,
    cacheWrite,
    totalTokens: usage?.totalTokens ?? input + output,
    cost: ZERO_USAGE.cost
  }
  return {
    ...normalized,
    cost: calculateCost(model, normalized)
  }
}

/** Omits reasoning options for models that the catalog marks as non-reasoning capable. */
export function resolveBullXReasoning(
  model: Model<any>,
  options: SimpleStreamOptions
): SimpleStreamOptions['reasoning'] {
  if (!model.reasoning) return undefined
  return options.reasoning
}

/** Builds provider-specific cache controls from BullX's provider-neutral cache retention option. */
export function createBullXProviderOptions(
  model: Model<any>,
  options: SimpleStreamOptions
): ProviderOptions | undefined {
  const cacheRetention = options.cacheRetention
  if (!cacheRetention || cacheRetention === 'none') return undefined

  if (model.provider === 'openai') {
    const promptCacheKey = promptCacheKeyFromOptions(model, options)
    if (!promptCacheKey) return undefined
    return {
      openai: {
        promptCacheKey,
        promptCacheRetention: cacheRetention === 'long' ? '24h' : 'in_memory'
      }
    }
  }

  if (model.provider === 'anthropic') {
    return {
      anthropic: {
        cacheControl: {
          type: 'ephemeral',
          ttl: cacheRetention === 'long' ? '1h' : '5m'
        }
      }
    }
  }

  return undefined
}

/** Names OpenAI prompt-cache entries by installation conversation so cache reuse never crosses conversations. */
function promptCacheKeyFromOptions(model: Model<any>, options: SimpleStreamOptions): string | undefined {
  const conversationId =
    stringMetadata(options.metadata, 'conversation_id') ?? stringMetadata(options.metadata, 'cache_key')
  if (!conversationId) return undefined
  return ['bullx', model.provider, model.id, conversationId].map(sanitizeCacheKeyPart).join(':')
}

/** Reads optional string metadata without accepting blank cache keys. */
function stringMetadata(metadata: Record<string, unknown> | undefined, key: string): string | undefined {
  const value = metadata?.[key]
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : undefined
}

/** Keeps cache-key parts inside provider-safe characters and bounded length. */
function sanitizeCacheKeyPart(value: string): string {
  return value.replace(/[^a-zA-Z0-9_.:-]/g, '_').slice(0, 128)
}
