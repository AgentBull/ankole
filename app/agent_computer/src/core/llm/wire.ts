import { Buffer } from 'node:buffer'
import { match, P, type JsonObject } from '@pleisto/active-support'
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

export function buildResponseCreateParams(model: ModelConfig, options: CallModelOptions): ResponseCreateParams {
  const input = toResponseInput(options.messages)
  const tools = options.tools
    ? Object.values(options.tools).map(t => ({
        type: 'function' as const,
        name: t.name,
        description: t.description,
        parameters: zodToJSONSchema(t.parameters),
        strict: false
      }))
    : undefined

  return {
    model: model.selector,
    input,
    ...(options.instructions ? { instructions: options.instructions } : {}),
    ...(tools?.length ? { tools } : {}),
    ...(options.maxOutputTokens ? { max_output_tokens: options.maxOutputTokens } : {}),
    ...(options.temperature !== undefined ? { temperature: options.temperature } : {}),
    ...(options.text ? { text: options.text } : {})
  }
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
          call_id: msg.toolCallId,
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
    actor_event_id: stateful.actorEventId
  }

  const request = {
    ...params,
    store: true,
    metadata
  } as ResponseCreateParams & JsonObject

  match([stateful.previousResponseId, stateful.conversationId] as const)
    .with([P.string, P._], ([previousResponseId]) => {
      request.previous_response_id = previousResponseId
    })
    .with([P._, P.string], ([, conversationId]) => {
      request.conversation = `conv_${conversationId}`
    })
    .otherwise(() => {
      throw new Error('stateful response.create requires a conversationId or previousResponseId')
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
  if (!stateful.previousResponseId) {
    throw new Error('stateful tool result recording requires a previousResponseId')
  }

  return {
    model: model.selector,
    input,
    store: true,
    previous_response_id: stateful.previousResponseId,
    metadata: {
      ...stateful.metadata,
      actor_event_id: stateful.actorEventId
    }
  } as ResponseCreateParams
}

function responseInputContentParts(parts: ContentPart[]): ResponseInputMessageContentList {
  const content: ResponseInputMessageContentList = []
  for (const part of parts) {
    if (part.type === 'image') {
      content.push({ type: 'input_image', image_url: imageContentUrl(part), detail: 'auto' })
      continue
    }
    content.push({ type: 'input_text', text: part.text })
  }
  return content
}

function imageContentUrl(part: ImageContent): string {
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
