/**
 * Worker LLM layer — built directly on the official `openai` npm package.
 *
 * The worker talks to AIGateway's OpenAI-compatible Responses surface.
 * This module defines the worker-local message/tool types and the single
 * entry point `callModel()` that wraps `openai.responses.create()`.
 *
 * Per plan §4.1-4.2: the worker drives the Responses loop by calling the
 * model, executing tools locally, and feeding results back — but it does
 * NOT own history expansion, compaction, or stop-strategy state. Those
 * live in AIGateway (StatefulResponses). The worker just:
 *   1. Calls response.create with current input items.
 *   2. Gets function_call items back.
 *   3. Executes tools.
 *   4. Feeds function_call_output on the next response.create.
 *   5. Stops when no function_call is returned.
 */

import OpenAI from 'openai'
import { z } from 'zod'
import type {
  ResponseCreateParams,
  ResponseInputItem,
  ResponseOutputMessage,
  ResponseFunctionToolCall,
  Response as OpenAIResponse
} from 'openai/resources/responses/responses'

// ── Worker-local message types ────────────────────────────────────

/**
 * A text content part in the worker's internal transcript.
 * Kept simple — the worker primarily deals with text.
 */
export interface TextContent {
  type: 'text'
  text: string
}

/**
 * An image content part.
 */
export interface ImageContent {
  type: 'image'
  image: string | URL | Uint8Array | BufferSource
  mimeType?: string
}

export type ContentPart = TextContent | ImageContent

/**
 * A tool call the model requested.
 */
export interface ToolCall {
  id: string
  type: 'function'
  name: string
  arguments: string
}

/**
 * A user message in the worker transcript.
 */
export interface UserMessage {
  role: 'user'
  content: string | ContentPart[]
}

/**
 * An assistant message in the worker transcript.
 */
export interface AssistantMessage {
  role: 'assistant'
  content: TextContent[]
  toolCalls?: ToolCall[]
  /** Usage from the provider. */
  usage?: ModelUsage
  /** Why the model stopped. */
  stopReason?: StopReason
  /** The model name that produced this. */
  model?: string
  /** Set when the provider returned an error. */
  errorMessage?: string
}

/**
 * A tool result message in the worker transcript.
 */
export interface ToolResultMessage {
  role: 'tool'
  toolCallId: string
  result: string
}

/**
 * Union of all transcript message types.
 */
export type Message = UserMessage | AssistantMessage | ToolResultMessage

// ── Usage and stop reason ─────────────────────────────────────────

export interface ModelUsage {
  inputTokens: number
  outputTokens: number
  reasoningTokens?: number
  cachedInputTokens?: number
}

export type StopReason = 'stop' | 'length' | 'toolUse' | 'error' | 'aborted'

export const ZERO_USAGE: ModelUsage = { inputTokens: 0, outputTokens: 0 }

// ── Model configuration ───────────────────────────────────────────

/**
 * Describes how to reach a model via AIGateway.
 * Created by `createModel()` — wraps an OpenAI client pointed at AIGateway.
 */
export interface ModelConfig {
  /** The OpenAI client configured for AIGateway. */
  client: OpenAI
  /** Model selector string (e.g. "openrouter/google/gemini-3.5-flash"). */
  selector: string
  /** Display name for telemetry. */
  name: string
  /** Provider id for logging. */
  provider: string
}

/**
 * Creates a ModelConfig that wraps an OpenAI SDK client pointed at AIGateway.
 *
 * Usage:
 * ```ts
 * const model = createModel({
 *   apiKey: apiKey.api_key,
 *   baseURL: apiKey.base_url,
 *   selector: `${modelRef.provider_id}/${modelRef.model}`,
 *   fetch: customFetch
 * })
 * ```
 */
export function createModel(opts: {
  apiKey: string
  baseURL: string
  selector: string
  name?: string
  provider?: string
  fetch?: typeof fetch
}): ModelConfig {
  const client = new OpenAI({
    apiKey: opts.apiKey,
    baseURL: opts.baseURL,
    fetch: opts.fetch as never
  })

  return {
    client,
    selector: opts.selector,
    name: opts.name ?? (opts.selector.includes('/') ? opts.selector.split('/').pop()! : opts.selector),
    provider: opts.provider ?? 'ai-gateway'
  }
}

// ── Tool definitions ──────────────────────────────────────────────

/**
 * A tool the worker can execute. The `execute` function is called when
 * the model requests this tool.
 */
export interface ToolDefinition<TSchema extends z.ZodType = z.ZodType> {
  name: string
  description?: string
  parameters: TSchema
  execute?: (args: z.infer<TSchema>, opts: { toolCallId: string }) => Promise<unknown> | unknown
}

export type ToolSet = Record<string, ToolDefinition>

// ── Model call ────────────────────────────────────────────────────

export interface CallModelOptions {
  /** System prompt / instructions. */
  instructions?: string
  /** Previous messages in the conversation. */
  messages: Message[]
  /** Available tools. */
  tools?: ToolSet
  /** Max output tokens. */
  maxOutputTokens?: number
  /** Temperature. */
  temperature?: number
  /** Abort signal. */
  abortSignal?: AbortSignal
  /** Called just before the HTTP request is sent. */
  beforeCall?: (payload: ResponseCreateParams) => void | Promise<void>
}

/**
 * Result of a single model call (one response.create round).
 */
export interface ModelCallResult {
  /** The assistant message extracted from the response. */
  message: AssistantMessage
  /** Raw function tool calls from the response (empty if none). */
  functionCalls: ResponseFunctionToolCall[]
  /** Whether the model requested tool calls. */
  hasToolCalls: boolean
  /** The resp_{uuid} id from the response (for previous_response_id chaining). */
  responseId?: string
}

/**
 * Calls the model via `openai.responses.create()`.
 *
 * This is the single LLM entry point. It converts worker-local Message[]
 * to OpenAI ResponseInputItem[], calls the Responses API, and maps the
 * output back to an AssistantMessage + function calls.
 *
 * Per plan §4.2: the worker calls this once per loop iteration. If
 * `hasToolCalls` is true, the worker executes tools and calls again
 * with the results. If false, the worker stops.
 */
export async function callModel(model: ModelConfig, options: CallModelOptions): Promise<ModelCallResult> {
  // Build the input items from worker messages.
  const input = toResponseInput(options.messages, options.instructions)

  // Build tool definitions for the API.
  const tools = options.tools
    ? Object.values(options.tools).map(t => ({
        type: 'function' as const,
        name: t.name,
        description: t.description,
        parameters: zodToJSONSchema(t.parameters),
        strict: false
      }))
    : undefined

  const params: ResponseCreateParams = {
    model: model.selector,
    input,
    ...(tools?.length ? { tools } : {}),
    ...(options.maxOutputTokens ? { max_output_tokens: options.maxOutputTokens } : {}),
    ...(options.temperature !== undefined ? { temperature: options.temperature } : {})
  }

  await options.beforeCall?.(params)

  const response = await model.client.responses.create(params as never)

  const result = parseResponse(response, model.name)
  result.responseId = response.id
  return result
}

// ── Streaming model call ──────────────────────────────────────────

export interface StreamModelOptions extends CallModelOptions {
  /** Called for each text delta as it arrives. */
  onTextDelta?: (delta: string) => void
  /** Called for each function call as it completes. */
  onFunctionCall?: (call: ResponseFunctionToolCall) => void
}

/**
 * Streams a model response via `openai.responses.create({ stream: true })`.
 *
 * Same contract as `callModel` but with live callbacks for text/tool deltas.
 */
export async function streamModel(model: ModelConfig, options: StreamModelOptions): Promise<ModelCallResult> {
  const input = toResponseInput(options.messages, options.instructions)

  const tools = options.tools
    ? Object.values(options.tools).map(t => ({
        type: 'function' as const,
        name: t.name,
        description: t.description,
        parameters: zodToJSONSchema(t.parameters),
        strict: false
      }))
    : undefined

  const params: ResponseCreateParams = {
    model: model.selector,
    input,
    stream: true,
    ...(tools?.length ? { tools } : {}),
    ...(options.maxOutputTokens ? { max_output_tokens: options.maxOutputTokens } : {}),
    ...(options.temperature !== undefined ? { temperature: options.temperature } : {})
  }

  await options.beforeCall?.(params)

  // Use the SDK's streaming mode and iterate over events.
  // The SDK returns a Stream<ResponseStreamEvent> when stream:true.
  // We cast to a minimal event shape for processing.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stream = (await model.client.responses.create(params as never)) as any

  // Accumulate from the stream events.
  let textBuffer = ''
  const functionCalls: ResponseFunctionToolCall[] = []
  let usage: ModelUsage = { ...ZERO_USAGE }
  let responseId: string | undefined

  for await (const event of stream) {
    const evt = event as Record<string, unknown>
    switch (evt.type) {
      case 'response.output_text.delta': {
        const delta = evt.delta as string | undefined
        if (delta) {
          textBuffer += delta
          options.onTextDelta?.(delta)
        }
        break
      }
      case 'response.function_call_arguments.done': {
        const call: ResponseFunctionToolCall = {
          id: (evt.call_id as string) ?? (evt.item_id as string) ?? '',
          call_id: (evt.call_id as string) ?? '',
          type: 'function_call',
          name: (evt.name as string) ?? '',
          arguments: (evt.arguments as string) ?? '{}'
        }
        functionCalls.push(call)
        options.onFunctionCall?.(call)
        break
      }
      case 'response.completed': {
        const response = evt.response as
          | {
              id?: string
              usage?: {
                input_tokens?: number
                output_tokens?: number
                output_tokens_details?: { reasoning?: number }
                input_tokens_details?: { cached?: number }
              }
            }
          | undefined
        responseId = response?.id
        const u = response?.usage
        if (u) {
          usage = {
            inputTokens: u.input_tokens ?? 0,
            outputTokens: u.output_tokens ?? 0,
            reasoningTokens: u.output_tokens_details?.reasoning,
            cachedInputTokens: u.input_tokens_details?.cached
          }
        }
        break
      }
    }
  }

  const message: AssistantMessage = {
    role: 'assistant',
    content: textBuffer ? [{ type: 'text', text: textBuffer }] : [],
    toolCalls:
      functionCalls.length > 0
        ? functionCalls.map(fc => ({
            id: fc.call_id || fc.id || '',
            type: 'function' as const,
            name: fc.name,
            arguments: fc.arguments
          }))
        : undefined,
    usage,
    stopReason: functionCalls.length > 0 ? 'toolUse' : 'stop',
    model: model.name
  }

  return { message, functionCalls, hasToolCalls: functionCalls.length > 0, responseId }
}

// ── Helpers ───────────────────────────────────────────────────────

/**
 * Converts worker-local Message[] to OpenAI ResponseInputItem[].
 */
function toResponseInput(messages: Message[], instructions?: string): ResponseInputItem[] {
  const items: ResponseInputItem[] = []

  if (instructions) {
    items.push({ role: 'system', content: instructions } as ResponseInputItem)
  }

  for (const msg of messages) {
    if (msg.role === 'user') {
      const content =
        typeof msg.content === 'string' ? msg.content : msg.content.map(p => (p.type === 'text' ? p.text : '')).join('')
      items.push({ role: 'user', content } as ResponseInputItem)
    } else if (msg.role === 'assistant') {
      const text = msg.content.map(p => p.text).join('')
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
    } else if (msg.role === 'tool') {
      items.push({
        type: 'function_call_output',
        call_id: msg.toolCallId,
        output: msg.result
      } as ResponseInputItem)
    }
  }

  return items
}

/**
 * Parses a completed response into worker-local types.
 */
function parseResponse(response: OpenAIResponse, modelName: string): ModelCallResult {
  const output = response.output ?? []
  const functionCalls: ResponseFunctionToolCall[] = []
  const textParts: string[] = []

  for (const item of output) {
    if (item.type === 'message') {
      const msg = item as ResponseOutputMessage
      for (const part of msg.content ?? []) {
        if (part.type === 'output_text') {
          textParts.push(part.text ?? '')
        }
      }
    } else if (item.type === 'function_call') {
      functionCalls.push(item as ResponseFunctionToolCall)
    }
  }

  const usage: ModelUsage | undefined = response.usage
    ? {
        inputTokens: response.usage.input_tokens ?? 0,
        outputTokens: response.usage.output_tokens ?? 0
      }
    : undefined

  const message: AssistantMessage = {
    role: 'assistant',
    content: textParts.length > 0 ? [{ type: 'text', text: textParts.join('') }] : [],
    toolCalls:
      functionCalls.length > 0
        ? functionCalls.map(fc => ({
            id: fc.call_id || fc.id || '',
            type: 'function' as const,
            name: fc.name,
            arguments: fc.arguments
          }))
        : undefined,
    usage,
    stopReason: functionCalls.length > 0 ? 'toolUse' : response.status === 'failed' ? 'error' : 'stop',
    model: modelName
  }

  return { message, functionCalls, hasToolCalls: functionCalls.length > 0, responseId: response.id }
}

/**
 * Converts a Zod schema to a JSON Schema for OpenAI tool definitions.
 */
export function zodToJSONSchema(schema: z.ZodType): Record<string, unknown> {
  return z.toJSONSchema(schema) as Record<string, unknown>
}

/**
 * Validates tool call arguments against a Zod schema.
 */
export function validateToolArguments(args: string, schema: z.ZodType): unknown {
  try {
    return schema.parse(JSON.parse(args))
  } catch {
    return JSON.parse(args)
  }
}

/**
 * Helper to create a user message.
 */
export function userMessage(content: string): UserMessage {
  return { role: 'user', content }
}

/**
 * Helper to create a tool result message.
 */
export function toolResultMessage(toolCallId: string, result: unknown): ToolResultMessage {
  return {
    role: 'tool',
    toolCallId,
    result: typeof result === 'string' ? result : JSON.stringify(result)
  }
}
