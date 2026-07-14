import { Buffer } from 'node:buffer'
import { createHash } from 'node:crypto'
import { match, P, type JsonObject as JSONObject } from '@pleisto/active-support'
import type {
  ResponseCreateParams,
  ResponseInputItem,
  ResponseInputMessageContentList
} from 'openai/resources/responses/responses'
import type {
  CallModelOptions,
  ContentPart,
  ImageContent,
  Message,
  ModelConfig,
  StatefulResponseContext
} from './types'
import { zodToJSONSchema } from './tool-schema'

const PROMPT_CACHE_ROUTING_PREFIX_CHARACTERS = 4_096

export function buildResponseCreateParams(model: ModelConfig, options: CallModelOptions): ResponseCreateParams {
  const input = toResponseInput(options.messages)
  const tools = options.tools
    ? Object.values(options.tools)
        .toSorted((left, right) => left.name.localeCompare(right.name))
        .map(t => ({
          type: 'function' as const,
          name: t.name,
          description: t.description,
          parameters: zodToJSONSchema(t.parameters),
          strict: false
        }))
    : undefined
  const promptCacheKey = reusablePromptCacheKey(options.instructions, tools)

  return {
    model: model.selector,
    input,
    ...(options.instructions ? { instructions: options.instructions } : {}),
    ...(tools?.length ? { tools } : {}),
    ...(promptCacheKey ? { prompt_cache_key: promptCacheKey } : {}),
    ...(options.maxOutputTokens ? { max_output_tokens: options.maxOutputTokens } : {}),
    ...(options.temperature !== undefined ? { temperature: options.temperature } : {}),
    ...(options.text ? { text: options.text } : {})
  }
}

/**
 * Routes requests that share a long leading instruction/tool prefix together.
 *
 * This is a routing hint, not the cache identity: the provider still requires
 * an exact prefix match. Hashing only the leading cacheable region lets
 * conversation-specific suffixes share a route without weakening correctness.
 * User messages stay out of the key because they are the dynamic suffix.
 */
export function reusablePromptCacheKey(
  instructions: string | undefined,
  tools: unknown[] | undefined
): string | undefined {
  if (!instructions && !tools?.length) return undefined

  const renderedPrefix = JSON.stringify({ instructions: instructions ?? '', tools: tools ?? [] })
  const routingPrefix = renderedPrefix.slice(0, PROMPT_CACHE_ROUTING_PREFIX_CHARACTERS)
  return `ankole_${createHash('sha256').update(routingPrefix).digest('hex').slice(0, 32)}`
}

export function toResponseInput(messages: Message[]): ResponseInputItem[] {
  return messages.flatMap(msg =>
    match(msg)
      .with({ role: 'user' }, msg => {
        const content = typeof msg.content === 'string' ? msg.content : responseInputContentParts(msg.content)
        return [{ role: 'user', content } as ResponseInputItem]
      })
      .with({ role: 'assistant' }, msg => {
        const text = msg.content.map(p => p.text).join('')
        const items: ResponseInputItem[] = []
        if (text) {
          items.push({ role: 'assistant', content: text } as ResponseInputItem)
        }
        if (msg.toolCalls) {
          for (const tc of msg.toolCalls) {
            items.push({
              type: 'function_call',
              call_id: tc.id,
              name: tc.name,
              arguments: tc.arguments
            } as ResponseInputItem)
          }
        }
        return items
      })
      .with({ role: 'tool' }, msg => [
        {
          type: 'function_call_output',
          call_id: msg.toolCallID,
          output: msg.result
        } as ResponseInputItem
      ])
      .exhaustive()
  )
}

export function statefulResponseParams(
  params: ResponseCreateParams,
  stateful: StatefulResponseContext
): ResponseCreateParams {
  const metadata = {
    ...stateful.metadata,
    actor_event_id: stateful.actorEventID
  }

  const request = {
    ...params,
    store: true,
    metadata
  } as ResponseCreateParams & JSONObject

  match([stateful.previousResponseID, stateful.conversationID] as const)
    .with([P.string, P._], ([previousResponseID]) => {
      request.previous_response_id = previousResponseID
    })
    .with([P._, P.string], ([, conversationID]) => {
      request.conversation = `conv_${conversationID}`
    })
    .otherwise(() => {
      throw new Error('stateful response.create requires a conversationID or previousResponseID')
    })

  if (stateful.truncation) {
    request.truncation = stateful.truncation
  }

  return request as ResponseCreateParams
}

export function statefulToolResultsRecordParams(
  model: ModelConfig,
  input: ResponseInputItem[],
  stateful: StatefulResponseContext
): ResponseCreateParams {
  if (!stateful.previousResponseID) {
    throw new Error('stateful tool result recording requires a previousResponseID')
  }

  return {
    model: model.selector,
    input,
    store: true,
    previous_response_id: stateful.previousResponseID,
    metadata: {
      ...stateful.metadata,
      actor_event_id: stateful.actorEventID
    }
  } as ResponseCreateParams
}

function responseInputContentParts(parts: ContentPart[]): ResponseInputMessageContentList {
  const content: ResponseInputMessageContentList = []
  for (const part of parts) {
    if (part.type === 'image') {
      content.push({ type: 'input_image', image_url: imageContentURL(part), detail: 'auto' })
      continue
    }
    content.push({ type: 'input_text', text: part.text })
  }
  return content
}

function imageContentURL(part: ImageContent): string {
  if (typeof part.image === 'string') return part.image
  if (part.image instanceof URL) return part.image.toString()

  return `data:${part.mimeType ?? 'image/png'};base64,${Buffer.from(imageBytes(part.image)).toString('base64')}`
}

function imageBytes(value: Uint8Array | BufferSource): Uint8Array {
  if (value instanceof Uint8Array) return value
  if (value instanceof ArrayBuffer) return new Uint8Array(value)
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
  }
  return new Uint8Array(value as ArrayBuffer)
}
