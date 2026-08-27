import { Buffer } from 'node:buffer'
import { createHash } from 'node:crypto'
import { match, P, type JsonObject as JSONObject } from '@agentbull/active-support'
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
  const localTools = options.tools ? localToolSpecs(Object.values(options.tools)) : []
  const hasDeferredTools = Object.values(options.tools ?? {}).some(tool => tool.deferLoading === true)
  const tools = [
    ...localTools,
    ...(hasDeferredTools ? [{ type: 'tool_search' as const, execution: 'server' as const }] : []),
    ...(options.programmaticToolCalling ? [{ type: 'programmatic_tool_calling' as const }] : []),
    ...(options.hostedTools ?? []).map(tool => ({ type: tool.type }))
  ]
  const promptCacheKey = reusablePromptCacheKey(options.instructions, tools)

  return {
    model: model.selector,
    input,
    ...providerOptionsParam(model),
    ...(options.instructions ? { instructions: options.instructions } : {}),
    ...(tools.length ? { tools: tools as ResponseCreateParams['tools'] } : {}),
    ...(promptCacheKey ? { prompt_cache_key: promptCacheKey } : {}),
    ...(options.maxOutputTokens ? { max_output_tokens: options.maxOutputTokens } : {}),
    ...(options.temperature !== undefined ? { temperature: options.temperature } : {}),
    ...(options.text ? { text: options.text } : {})
  } as ResponseCreateParams
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

  const renderedPrefix = JSON.stringify({
    instructions: instructions ?? '',
    tools: tools ?? []
  })
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
            items.push(
              tc.type === 'custom'
                ? ({
                    type: 'custom_tool_call',
                    call_id: tc.id,
                    name: tc.name,
                    input: tc.arguments,
                    ...(tc.namespace ? { namespace: tc.namespace } : {}),
                    ...(tc.caller ? { caller: tc.caller } : {})
                  } as ResponseInputItem)
                : ({
                    type: 'function_call',
                    call_id: tc.id,
                    name: tc.name,
                    arguments: tc.arguments,
                    ...(tc.namespace ? { namespace: tc.namespace } : {}),
                    ...(tc.caller ? { caller: tc.caller } : {})
                  } as ResponseInputItem)
            )
          }
        }
        return items
      })
      .with({ role: 'tool' }, msg => [
        {
          type: msg.toolCallType === 'custom' ? 'custom_tool_call_output' : 'function_call_output',
          call_id: msg.toolCallID,
          output: msg.result,
          ...(msg.caller ? { caller: msg.caller } : {})
        } as ResponseInputItem
      ])
      .exhaustive()
  )
}

function localToolSpecs(definitions: NonNullable<CallModelOptions['tools']>[string][]): unknown[] {
  const sorted = definitions.toSorted((left, right) => {
    const leftKey = `${left.namespace ?? ''}\u0000${left.name}`
    const rightKey = `${right.namespace ?? ''}\u0000${right.name}`
    return leftKey.localeCompare(rightKey)
  })
  const rootTools = sorted.filter(tool => !tool.namespace).map(localToolSpec)
  const namespaced = Map.groupBy(
    sorted.filter(tool => tool.namespace),
    tool => tool.namespace!
  )
  const namespaceTools = [...namespaced.entries()].map(([name, tools]) => ({
    type: 'namespace' as const,
    name,
    description: tools[0]?.namespaceDescription ?? defaultNamespaceDescription(name),
    tools: tools.map(localToolSpec)
  }))

  return [...rootTools, ...namespaceTools]
}

export function defaultNamespaceDescription(namespace: string): string {
  return namespace === 'functions' ? '' : `Tools in the ${namespace} namespace.`
}

function localToolSpec(tool: NonNullable<CallModelOptions['tools']>[string]) {
  if (tool.inputFormat) {
    return {
      type: 'custom' as const,
      name: tool.name,
      description: tool.description,
      format: tool.inputFormat,
      ...(tool.deferLoading ? { defer_loading: true } : {}),
      ...(tool.toolSearchText ? { __ankole_search_text: tool.toolSearchText } : {}),
      ...(tool.allowedCallers?.length ? { allowed_callers: tool.allowedCallers } : {})
    }
  }

  return {
    type: 'function' as const,
    name: tool.name,
    description: tool.description,
    parameters: tool.jsonSchema ?? zodToJSONSchema(tool.parameters),
    ...(tool.outputSchema ? { output_schema: tool.outputSchema } : {}),
    strict: false,
    ...(tool.deferLoading ? { defer_loading: true } : {}),
    ...(tool.toolSearchText ? { __ankole_search_text: tool.toolSearchText } : {}),
    ...(tool.allowedCallers?.length ? { allowed_callers: tool.allowedCallers } : {})
  }
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

  match(stateful)
    .with({ previousResponseID: P.string }, ({ previousResponseID }) => {
      request.previous_response_id = previousResponseID
    })
    .with({ conversationID: P.string }, ({ conversationID }) => {
      request.conversation = `conv_${conversationID}`
    })
    .exhaustive()

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
  // Narrower than `response.create`: results attach to the response that asked
  // for them, so a context still anchored on its conversation cannot record any.
  if (!('previousResponseID' in stateful)) {
    throw new Error('stateful tool result recording requires a previousResponseID')
  }

  return {
    model: model.selector,
    input,
    ...providerOptionsParam(model),
    store: true,
    previous_response_id: stateful.previousResponseID,
    metadata: {
      ...stateful.metadata,
      actor_event_id: stateful.actorEventID
    }
  } as ResponseCreateParams
}

function providerOptionsParam(model: ModelConfig): JSONObject {
  if (!model.providerOptions || Object.keys(model.providerOptions).length === 0) return {}
  return { provider_options: model.providerOptions }
}

function responseInputContentParts(parts: ContentPart[]): ResponseInputMessageContentList {
  const content: ResponseInputMessageContentList = []
  for (const part of parts) {
    if (part.type === 'image') {
      content.push({
        type: 'input_image',
        image_url: imageContentURL(part),
        detail: 'auto'
      })
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
