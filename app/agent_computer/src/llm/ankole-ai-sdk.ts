import type { ModelMessage, ProviderOptions } from './provider-utils'
import type { LanguageModelUsage } from './types'
import {
  calculateCost,
  ZERO_USAGE,
  type AssistantMessage,
  type Message,
  type Model,
  type SimpleStreamOptions
} from './ankole'

// The seam between Ankole's durable transcript shapes (ankole.ts) and the vendored AI SDK's
// per-call wire shapes. Everything here is pure translation, in BOTH directions:
//  - outbound: Ankole transcript -> AI SDK request (messages, provider options, reasoning)
//  - inbound:  AI SDK result    -> Ankole assistant message (stop reason, usage, cost)

/**
 * Maps an Ankole transcript onto the AI SDK request shape. The non-obvious renames:
 *  - Ankole block `thinking` -> AI SDK `reasoning` content part.
 *  - Ankole `toolCall` (fields id/name/arguments) -> AI SDK `tool-call` (toolCallId/toolName/input).
 *  - Ankole role `toolResult` -> AI SDK role `tool`.
 * Tool results are flattened to text: image blocks become an `[image:...]` placeholder because
 * the tool-result wire slot only carries text, and `isError` selects the SDK's error-text variant.
 */
export function convertAnkoleMessagesToModelMessages(messages: Message[]): ModelMessage[] {
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
                  : // Ankole stores image bytes inline (base64) in `data`; the SDK image part wants
                    // them under `image` with the mime type as `mediaType`.
                    { type: 'image' as const, image: block.data, mediaType: block.mimeType }
              )
      }
    }

    if (message.role === 'assistant') {
      return {
        role: 'assistant',
        content: message.content.map(block => {
          if (block.type === 'text') return { type: 'text' as const, text: block.text }
          // Replaying our own prior reasoning back to the provider as a 'reasoning' part.
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

    // toolResult: join all content blocks into a single text payload (images degraded to a tag).
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

/**
 * Stamps an Ankole assistant message with model provenance and safe defaults. Used both for
 * the success path (with `extra` carrying real usage/responseId) and for error/abort paths
 * where there is no provider response at all. Usage defaults to a fresh copy of ZERO_USAGE
 * (cost included) so callers never alias the shared constant; `extra` can override any field.
 */
export function createAnkoleAssistantMessage(
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

/** Collapses AI SDK finish reasons into the smaller Ankole stop-reason set persisted by the agent runtime. */
export function toAnkoleStopReason(reason: string): AssistantMessage['stopReason'] {
  if (reason === 'length') return 'length'
  if (reason === 'tool-calls') return 'toolUse'
  if (reason === 'error') return 'error'
  // Everything else (including the SDK's 'stop', 'content-filter', 'other', 'unknown')
  // folds into 'stop'; 'aborted' is not produced here — callers set it from the abort signal.
  return 'stop'
}

/**
 * Folds the AI SDK's nested usage report into Ankole's four flat token buckets and prices it.
 *
 * Cache tokens come from `inputTokenDetails` (Anthropic cache-read/write, OpenAI cached input);
 * each missing field defaults to 0 because not every provider reports them. NOTE: `input` here
 * is the SDK's reported input count, which on cache-aware providers may already include cached
 * tokens — Ankole records cacheRead/cacheWrite as separate line items and lets the per-bucket
 * prices in the model sort out the billing, rather than trying to subtract them. `totalTokens`
 * falls back to input+output when the provider omits a grand total. Cost is computed in the same
 * pass via calculateCost so usage and cost are always consistent.
 */
export function toAnkoleUsage(usage: LanguageModelUsage | undefined, model: Model<any>): AssistantMessage['usage'] {
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
export function resolveAnkoleReasoning(
  model: Model<any>,
  options: SimpleStreamOptions
): SimpleStreamOptions['reasoning'] {
  if (!model.reasoning) return undefined
  return options.reasoning
}

/**
 * Translates Ankole's provider-neutral `cacheRetention` ('short'|'long') into each provider's
 * own prompt-cache controls. Only OpenAI and Anthropic have explicit knobs here; every other
 * provider falls through and just keeps the caller's explicit options (caching, if any, is
 * implicit). Returns `explicitOptions` untouched when caching is off so we never fabricate a
 * provider-options object the caller didn't ask for.
 */
export function createAnkoleProviderOptions(
  model: Model<any>,
  options: SimpleStreamOptions
): ProviderOptions | undefined {
  const explicitOptions = options.providerOptions
  const cacheRetention = options.cacheRetention
  if (!cacheRetention || cacheRetention === 'none') return explicitOptions

  if (model.provider === 'openai') {
    // OpenAI prompt caching keys on a caller-supplied string. Without a stable key we can't
    // safely opt in (an empty/shared key would risk cross-conversation reuse), so bail.
    const promptCacheKey = promptCacheKeyFromOptions(model, options)
    if (!promptCacheKey) return explicitOptions
    return mergeProviderOptions(explicitOptions, {
      openai: {
        promptCacheKey,
        // 'long' -> persisted 24h cache; 'short' -> in-memory (lives only for the burst).
        promptCacheRetention: cacheRetention === 'long' ? '24h' : 'in_memory'
      }
    })
  }

  if (model.provider === 'anthropic') {
    // Anthropic caches via an ephemeral cache-control breakpoint; we pick the TTL.
    // 'long' -> 1h, 'short' -> 5m (Anthropic's two supported ephemeral TTLs).
    return mergeProviderOptions(explicitOptions, {
      anthropic: {
        cacheControl: {
          type: 'ephemeral',
          ttl: cacheRetention === 'long' ? '1h' : '5m'
        }
      }
    })
  }

  return explicitOptions
}

/**
 * Deep-merges two provider-options maps one level into each provider's sub-object so
 * Ankole's cache controls (`right`) and the caller's explicit options (`left`) coexist.
 * Precedence: `right` wins on key collisions, but only within the same provider — other
 * providers' settings are preserved untouched.
 */
function mergeProviderOptions(
  left: ProviderOptions | undefined,
  right: ProviderOptions | undefined
): ProviderOptions | undefined {
  if (!left) return right
  if (!right) return left

  const merged: ProviderOptions = { ...left }
  for (const [provider, options] of Object.entries(right)) {
    merged[provider] = {
      ...left[provider],
      ...options
    }
  }
  return merged
}

/**
 * Derives a stable OpenAI prompt-cache key scoped to one conversation. Including provider +
 * model id in the key means a cache entry is never reused across a different model, and the
 * conversation id means it never bleeds between conversations (privacy + correctness). Returns
 * undefined when no conversation id is in metadata, which disables caching for that call.
 */
function promptCacheKeyFromOptions(model: Model<any>, options: SimpleStreamOptions): string | undefined {
  const conversationId =
    stringMetadata(options.metadata, 'conversation_id') ?? stringMetadata(options.metadata, 'cache_key')
  if (!conversationId) return undefined
  return ['ankole', model.provider, model.id, conversationId].map(sanitizeCacheKeyPart).join(':')
}

/** Reads optional string metadata without accepting blank cache keys. */
function stringMetadata(metadata: Record<string, unknown> | undefined, key: string): string | undefined {
  const value = metadata?.[key]
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : undefined
}

/** Keeps cache-key parts inside provider-safe characters and bounded length. */
function sanitizeCacheKeyPart(value: string): string {
  // Replace anything outside a conservative whitelist, then cap at 128 chars to stay under
  // provider key-length limits (a long conversation id won't blow the budget).
  return value.replace(/[^a-zA-Z0-9_.:-]/g, '_').slice(0, 128)
}
