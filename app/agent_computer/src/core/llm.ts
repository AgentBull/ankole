/**
 * Worker LLM wire adapter for AIGateway Responses.
 *
 * This file only adapts worker-local tool/input shapes to response.create wire
 * frames. History, anchors, stop strategy, and durable persistence belong to
 * AIGateway StatefulResponses, not the worker.
 */

import OpenAI from 'openai'
import { Buffer } from 'node:buffer'
import { z } from 'zod'
import type {
  ResponseCreateParams,
  ResponseInputMessageContentList,
  ResponseInputItem,
  ResponseOutputItem,
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
  /** Optional AIGateway WebSocket transport for stateful response.create runs. */
  responseWebSocket?: ResponseWebSocketTransport
}

export type ResponseWebSocketTransport = {
  kind: 'aigateway-websocket'
  url: string
  authorization: (options?: ResponseWebSocketAuthorizationOptions) => Promise<string> | string
  createWebSocket?: ResponseWebSocketFactory
}

export type ResponseWebSocketAuthorizationOptions = {
  forceRefresh?: boolean
}

export type ResponseWebSocketFactory = (url: string, init: { headers: Record<string, string> }) => ResponseWebSocketLike

export type ResponseWebSocketLike = {
  readyState?: number
  send(data: string): void
  close(code?: number, reason?: string): void
  addEventListener(type: 'open', listener: (event: Event) => void, options?: { once?: boolean }): void
  addEventListener(type: 'message', listener: (event: MessageEvent) => void, options?: { once?: boolean }): void
  addEventListener(type: 'error', listener: (event: Event) => void, options?: { once?: boolean }): void
  addEventListener(type: 'close', listener: (event: CloseEvent) => void, options?: { once?: boolean }): void
  removeEventListener?(type: string, listener: (event: unknown) => void): void
}

export type ResponseWebSocketSession = {
  call(params: ResponseCreateParams, options: CallModelOptions): Promise<ModelCallResult>
  recordToolResults(
    params: ResponseCreateParams,
    options: ToolResultsRecordWebSocketOptions
  ): Promise<ToolResultsRecordResult>
  close(): void
}

/**
 * Creates a ModelConfig pointed at AIGateway.
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
  responseWebSocket?: ResponseWebSocketTransport
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
    provider: opts.provider ?? 'ai-gateway',
    responseWebSocket: opts.responseWebSocket
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
  /** Responses API text controls, including structured output format. */
  text?: ResponseCreateParams['text']
  /** Abort signal. */
  abortSignal?: AbortSignal
  /** Called just before the HTTP request is sent. */
  beforeCall?: (payload: ResponseCreateParams) => void | Promise<void>
  /** Called for each streamed text delta when the transport streams events. */
  onTextDelta?: (delta: string) => void
  /** Stateful AIGateway context; stateful calls must use the WebSocket transport. */
  stateful?: StatefulResponseContext
  /** Turn-local stateful WebSocket session shared across response.create rounds. */
  responseWebSocketSession?: ResponseWebSocketSession
}

export type StatefulResponseContext = {
  actorEventId: string
  conversationId?: string
  previousResponseId?: string
  truncation?: 'auto' | 'disabled'
  metadata?: Record<string, unknown>
}

/**
 * Carries structured AIGateway WebSocket failure metadata through the normal
 * Error path.
 *
 * The agent loop only needs a retryable/non-retryable decision, but turn-error
 * details should still preserve gateway codes and transport stages.
 */
class AIGatewayWebSocketError extends Error {
  readonly code?: string
  readonly status?: number
  readonly details?: unknown

  constructor(message: string, opts: { code?: string; status?: number; details?: unknown } = {}) {
    super(message)
    this.name = 'AIGatewayWebSocketError'
    this.code = opts.code
    this.status = opts.status
    this.details = opts.details
  }
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

export interface ToolResultsRecordOptions {
  messages: Message[]
  stateful: StatefulResponseContext
  abortSignal?: AbortSignal
  responseWebSocketSession?: ResponseWebSocketSession
}

export interface ToolResultsRecordWebSocketOptions {
  abortSignal?: AbortSignal
}

export interface ToolResultsRecordResult {
  responseId: string
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
  const input = toResponseInput(options.messages)

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
    ...(options.instructions ? { instructions: options.instructions } : {}),
    ...(tools?.length ? { tools } : {}),
    ...(options.maxOutputTokens ? { max_output_tokens: options.maxOutputTokens } : {}),
    ...(options.temperature !== undefined ? { temperature: options.temperature } : {}),
    ...(options.text ? { text: options.text } : {})
  }

  if (options.stateful) {
    const statefulParams = statefulResponseParams(params, options.stateful)
    await options.beforeCall?.(statefulParams)
    return callModelOverWebSocket(model, statefulParams, options)
  }

  await options.beforeCall?.(params)

  const requestOptions = options.abortSignal ? { signal: options.abortSignal } : undefined
  const response = await model.client.responses.create(params as never, requestOptions)

  const result = parseResponse(response, model.name)
  result.responseId = response.id
  return result
}

/**
 * Records function_call_output items into a stateful Responses conversation.
 *
 * In stateful mode the worker should not replay the whole transcript after
 * tools run. It records only the tool outputs and continues from the response id
 * returned by AIGateway.
 */
export async function recordToolResults(
  model: ModelConfig,
  options: ToolResultsRecordOptions
): Promise<ToolResultsRecordResult> {
  const input = toResponseInput(options.messages)
  const params = statefulToolResultsRecordParams(model, input, options.stateful)
  const session = options.responseWebSocketSession ?? createResponseWebSocketSession(model)

  try {
    return await session.recordToolResults(params, { abortSignal: options.abortSignal })
  } finally {
    if (!options.responseWebSocketSession) session.close()
  }
}

// ── Helpers ───────────────────────────────────────────────────────

/**
 * Converts worker-local Message[] to OpenAI ResponseInputItem[].
 */
function toResponseInput(messages: Message[]): ResponseInputItem[] {
  const items: ResponseInputItem[] = []

  for (const msg of messages) {
    if (msg.role === 'user') {
      const content = typeof msg.content === 'string' ? msg.content : responseInputContentParts(msg.content)
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
 * Converts worker content parts to the Responses input content wire shape.
 */
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

/**
 * Produces an image URL acceptable to Responses input_image content.
 *
 * Binary in-memory images become data URLs because the worker has no public URL
 * for transient screenshots or attachment bytes.
 */
function imageContentUrl(part: ImageContent): string {
  if (typeof part.image === 'string') return part.image
  if (part.image instanceof URL) return part.image.toString()

  return `data:${part.mimeType ?? 'image/png'};base64,${Buffer.from(imageBytes(part.image)).toString('base64')}`
}

/**
 * Normalizes the few BufferSource variants accepted by worker tools.
 */
function imageBytes(value: Uint8Array | BufferSource): Uint8Array {
  if (value instanceof Uint8Array) return value
  if (value instanceof ArrayBuffer) return new Uint8Array(value)
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
  }
  return new Uint8Array(value as ArrayBuffer)
}

/**
 * Parses a completed response into worker-local types.
 */
function parseResponse(response: OpenAIResponse, modelName: string): ModelCallResult {
  const output = response.output ?? []
  const usage = usageFromResponse(response.usage)
  const result = parseOutputItems(output, modelName, usage, response.status === 'failed' ? 'error' : undefined)
  result.responseId = response.id
  return result
}

/**
 * Adds AIGateway stateful fields to a response.create payload.
 *
 * The first stateful round anchors by conversation id; later rounds anchor by
 * previous_response_id so AIGateway owns replay and truncation.
 */
function statefulResponseParams(params: ResponseCreateParams, stateful: StatefulResponseContext): ResponseCreateParams {
  const metadata = {
    ...stateful.metadata,
    actor_event_id: stateful.actorEventId
  }

  const request = {
    ...params,
    store: true,
    metadata
  } as ResponseCreateParams & Record<string, unknown>

  if (stateful.previousResponseId) {
    request.previous_response_id = stateful.previousResponseId
  } else if (stateful.conversationId) {
    request.conversation = `conv_${stateful.conversationId}`
  } else {
    throw new Error('stateful response.create requires a conversationId or previousResponseId')
  }

  if (stateful.truncation) {
    request.truncation = stateful.truncation
  }

  return request as ResponseCreateParams
}

/**
 * Builds the payload for recording tool outputs after a stateful model round.
 */
function statefulToolResultsRecordParams(
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

/**
 * Calls stateful response.create over a reusable WebSocket session.
 */
async function callModelOverWebSocket(
  model: ModelConfig,
  params: ResponseCreateParams,
  options: CallModelOptions
): Promise<ModelCallResult> {
  const session = options.responseWebSocketSession ?? createResponseWebSocketSession(model)

  try {
    return await session.call(params, options)
  } finally {
    if (!options.responseWebSocketSession) session.close()
  }
}

/**
 * Creates the default stateful Responses WebSocket session.
 */
export function createResponseWebSocketSession(model: ModelConfig): ResponseWebSocketSession {
  return new DefaultResponseWebSocketSession(model)
}

/**
 * Reuses one AIGateway WebSocket for sequential stateful Responses requests.
 *
 * The class forbids concurrent requests because response.create and
 * tool_results.record acknowledgements share one event stream and must be
 * matched to one in-flight operation at a time.
 */
class DefaultResponseWebSocketSession implements ResponseWebSocketSession {
  private socket: ResponseWebSocketLike | undefined
  private opening: Promise<ResponseWebSocketLike> | undefined
  private opened = false
  private closed = false
  private inFlight = false
  private forceRefreshAuthorization = false

  constructor(private readonly model: ModelConfig) {}

  /**
   * Sends one response.create request over the open session.
   */
  async call(params: ResponseCreateParams, options: CallModelOptions): Promise<ModelCallResult> {
    if (this.inFlight) {
      throw new Error('AIGateway WebSocket session already has an active response.create')
    }

    this.inFlight = true

    try {
      const socket = await this.ensureOpen()
      return await responseCreateOverOpenWebSocket(this.model, socket, params, options, () => this.discardSocket())
    } catch (error) {
      if (shouldRefreshAuthorizationAfterWebSocketOpenFailure(error)) {
        this.forceRefreshAuthorization = true
      }
      throw error
    } finally {
      this.inFlight = false
    }
  }

  /**
   * Records tool results over the open session.
   */
  async recordToolResults(
    params: ResponseCreateParams,
    options: ToolResultsRecordWebSocketOptions
  ): Promise<ToolResultsRecordResult> {
    if (this.inFlight) {
      throw new Error('AIGateway WebSocket session already has an active request')
    }

    this.inFlight = true

    try {
      const socket = await this.ensureOpen()
      return await recordToolResultsOverOpenWebSocket(socket, params, options, () => this.discardSocket())
    } catch (error) {
      if (shouldRefreshAuthorizationAfterWebSocketOpenFailure(error)) {
        this.forceRefreshAuthorization = true
      }
      throw error
    } finally {
      this.inFlight = false
    }
  }

  /**
   * Closes the session and prevents future requests.
   */
  close(): void {
    this.closed = true
    this.closeSocket()
  }

  /**
   * Returns an open socket, opening exactly one socket even when callers race.
   */
  private async ensureOpen(): Promise<ResponseWebSocketLike> {
    if (this.closed) {
      throw new Error('AIGateway WebSocket session is closed')
    }

    if (this.socket && this.opened && this.socket.readyState !== 3) {
      return this.socket
    }

    if (this.opening) return this.opening

    this.opening = this.openFreshSocket().finally(() => {
      this.opening = undefined
    })

    return this.opening
  }

  /**
   * Opens a fresh socket and waits for the WebSocket open event.
   *
   * Failures before open are locally retryable because no request was sent yet.
   */
  private async openFreshSocket(): Promise<ResponseWebSocketLike> {
    const transport = this.model.responseWebSocket
    if (!transport) {
      throw new Error('stateful response.create requires an AIGateway WebSocket transport')
    }

    const authorization = await transport.authorization(
      this.forceRefreshAuthorization ? { forceRefresh: true } : undefined
    )
    this.forceRefreshAuthorization = false
    const socket = createResponseWebSocket(transport, authorization)
    this.socket = socket
    this.opened = false

    return await new Promise<ResponseWebSocketLike>((resolve, reject) => {
      let settled = false

      const cleanup = () => {
        socket.removeEventListener?.('open', onOpen as (event: unknown) => void)
        socket.removeEventListener?.('error', onError as (event: unknown) => void)
        socket.removeEventListener?.('close', onClose as (event: unknown) => void)
      }

      const fail = (error: Error) => {
        if (settled) return
        settled = true
        cleanup()
        this.discardSocket()
        reject(error)
      }

      const onOpen = () => {
        if (settled) return
        settled = true
        this.opened = true
        cleanup()
        resolve(socket)
      }

      const onError = () =>
        fail(webSocketTransportError('AIGateway WebSocket transport error', 'transport_error_before_open', true))

      const onClose = (event: CloseEvent) => {
        const suffix = event.reason ? `: ${event.reason}` : ''
        fail(webSocketTransportError(`AIGateway WebSocket closed before open${suffix}`, 'closed_before_open', true))
      }

      socket.addEventListener('open', onOpen, { once: true })
      socket.addEventListener('error', onError, { once: true })
      socket.addEventListener('close', onClose, { once: true })
    })
  }

  /**
   * Closes and forgets the current socket after a transport failure.
   */
  private discardSocket(): void {
    this.closeSocket()
    this.socket = undefined
    this.opened = false
  }

  /**
   * Closes the socket while tolerating close races from terminal frames.
   */
  private closeSocket(): void {
    if (!this.socket) return

    try {
      this.socket.close()
    } catch {
      // ignore close races after terminal frames or failures
    }
  }
}

/**
 * Sends one response.create payload over an already-open WebSocket and parses
 * the streaming event frames into the same result shape as HTTP Responses.
 *
 * Some terminal frames may omit full output, so completed output_item frames are
 * kept as a fallback until the terminal response arrives.
 */
async function responseCreateOverOpenWebSocket(
  model: ModelConfig,
  socket: ResponseWebSocketLike,
  params: ResponseCreateParams,
  options: CallModelOptions,
  discardSocket: () => void
): Promise<ModelCallResult> {
  const requestPayload = JSON.stringify({ type: 'response.create', ...params })

  return await new Promise<ModelCallResult>((resolve, reject) => {
    let settled = false
    let textBuffer = ''
    let responseId: string | undefined
    let usage: ModelUsage | undefined
    let terminalStatus: StopReason | undefined
    let terminalErrorText: string | undefined
    const stableItems: ResponseOutputItem[] = []
    const functionCallsById = new Map<string, ResponseFunctionToolCall>()

    const cleanup = () => {
      options.abortSignal?.removeEventListener('abort', onAbort)
      socket.removeEventListener?.('message', onMessage as (event: unknown) => void)
      socket.removeEventListener?.('error', onError as (event: unknown) => void)
      socket.removeEventListener?.('close', onClose as (event: unknown) => void)
    }

    const finish = (result: ModelCallResult) => {
      if (settled) return
      settled = true
      cleanup()
      resolve(result)
    }

    const fail = (error: Error) => {
      if (settled) return
      settled = true
      cleanup()
      discardSocket()
      reject(error)
    }

    const onAbort = () => fail(webSocketTransportError('LLM provider call aborted', 'aborted', false))

    const onMessage = (event: MessageEvent) => {
      const frameText = webSocketFrameText(event.data)
      let frame: Record<string, unknown>
      try {
        frame = JSON.parse(frameText) as Record<string, unknown>
      } catch {
        return
      }

      switch (frame.type) {
        case 'response.output_text.delta': {
          const delta = typeof frame.delta === 'string' ? frame.delta : ''
          textBuffer += delta
          options.onTextDelta?.(delta)
          return
        }

        case 'response.output_item.done': {
          const item = recordValue(frame.item)
          if (item) {
            stableItems.push(item as unknown as ResponseOutputItem)
            rememberFunctionCall(functionCallsById, item)
          }
          return
        }

        case 'response.completed':
        case 'response.failed':
        case 'response.incomplete': {
          const response = recordValue(frame.response)
          const output = arrayValue(response?.output) as ResponseOutputItem[] | undefined
          const terminalItems = output && output.length > 0 ? output : stableItems
          const responseStatus = typeof response?.status === 'string' ? response.status : undefined
          responseId = typeof response?.id === 'string' ? response.id : responseId
          usage = usageFromResponse(recordValue(response?.usage))
          terminalStatus = frame.type === 'response.completed' && responseStatus !== 'failed' ? undefined : 'error'
          terminalErrorText = terminalErrorMessage(response, frame)

          // AIGateway can send output_item.done before the terminal response and
          // then finish with an empty response.output. Keeping stableItems avoids
          // losing tool calls or final text in that edge case.
          const result = parseOutputItems(
            terminalItems,
            model.name,
            usage,
            terminalStatus,
            textBuffer,
            terminalErrorText,
            [...functionCallsById.values()]
          )
          result.responseId = responseId
          finish(result)
          return
        }

        case 'error': {
          fail(aigatewayErrorFromFrame(frame))
          return
        }

        default:
          return
      }
    }

    const onError = () =>
      fail(webSocketTransportError('AIGateway WebSocket transport error', 'transport_error_after_open', false))

    const onClose = (event: CloseEvent) => {
      if (settled) return
      const suffix = event.reason ? `: ${event.reason}` : ''
      fail(
        webSocketTransportError(
          `AIGateway WebSocket closed before response.completed${suffix}`,
          'closed_before_terminal',
          false
        )
      )
    }

    options.abortSignal?.addEventListener('abort', onAbort, { once: true })
    if (options.abortSignal?.aborted) {
      onAbort()
      return
    }

    socket.addEventListener('message', onMessage)
    socket.addEventListener('error', onError, { once: true })
    socket.addEventListener('close', onClose, { once: true })

    try {
      socket.send(requestPayload)
    } catch (error) {
      fail(webSocketTransportError(errorMessage(error), 'send_failed', false))
    }
  })
}

/**
 * Sends one response.tool_results.record payload and waits for the recorded
 * response id that becomes the next stateful anchor.
 */
async function recordToolResultsOverOpenWebSocket(
  socket: ResponseWebSocketLike,
  params: ResponseCreateParams,
  options: ToolResultsRecordWebSocketOptions,
  discardSocket: () => void
): Promise<ToolResultsRecordResult> {
  const requestPayload = JSON.stringify({ type: 'response.tool_results.record', ...params })

  return await new Promise<ToolResultsRecordResult>((resolve, reject) => {
    let settled = false

    const cleanup = () => {
      options.abortSignal?.removeEventListener('abort', onAbort)
      socket.removeEventListener?.('message', onMessage as (event: unknown) => void)
      socket.removeEventListener?.('error', onError as (event: unknown) => void)
      socket.removeEventListener?.('close', onClose as (event: unknown) => void)
    }

    const finish = (result: ToolResultsRecordResult) => {
      if (settled) return
      settled = true
      cleanup()
      resolve(result)
    }

    const fail = (error: Error, discard = true) => {
      if (settled) return
      settled = true
      cleanup()
      if (discard) discardSocket()
      reject(error)
    }

    const onAbort = () => fail(webSocketTransportError('Tool result recording aborted', 'aborted', false))

    const onMessage = (event: MessageEvent) => {
      const frameText = webSocketFrameText(event.data)
      let frame: Record<string, unknown>
      try {
        frame = JSON.parse(frameText) as Record<string, unknown>
      } catch {
        return
      }

      switch (frame.type) {
        case 'response.tool_results.recorded': {
          const response = recordValue(frame.response)
          const responseId = stringValue(response?.id) ?? stringValue(frame.response_id)
          if (!responseId) {
            fail(
              new AIGatewayWebSocketError('AIGateway tool result record ack did not include response.id', {
                code: 'missing_recorded_response_id'
              }),
              false
            )
            return
          }
          finish({ responseId })
          return
        }

        case 'error': {
          fail(aigatewayErrorFromFrame(frame), false)
          return
        }

        default:
          return
      }
    }

    const onError = () =>
      fail(webSocketTransportError('AIGateway WebSocket transport error', 'tool_results_record_transport_error', true))

    const onClose = (event: CloseEvent) => {
      if (settled) return
      const suffix = event.reason ? `: ${event.reason}` : ''
      fail(
        webSocketTransportError(
          `AIGateway WebSocket closed before response.tool_results.recorded${suffix}`,
          'tool_results_record_closed_before_ack',
          true
        )
      )
    }

    options.abortSignal?.addEventListener('abort', onAbort, { once: true })
    if (options.abortSignal?.aborted) {
      onAbort()
      return
    }

    socket.addEventListener('message', onMessage)
    socket.addEventListener('error', onError, { once: true })
    socket.addEventListener('close', onClose, { once: true })

    try {
      socket.send(requestPayload)
    } catch (error) {
      fail(webSocketTransportError(errorMessage(error), 'tool_results_record_send_failed', true))
    }
  })
}

/**
 * Creates the WebSocket object, using an injected factory in tests.
 */
function createResponseWebSocket(transport: ResponseWebSocketTransport, authorization: string): ResponseWebSocketLike {
  const init = { headers: { authorization } }
  if (transport.createWebSocket) return transport.createWebSocket(transport.url, init)
  return new WebSocket(transport.url, init as never) as ResponseWebSocketLike
}

/**
 * Creates a structured transport error with retry hints for the agent loop.
 */
function webSocketTransportError(message: string, stage: string, localRetryable: boolean): AIGatewayWebSocketError {
  return new AIGatewayWebSocketError(message, {
    code: `aigateway_websocket_${stage}`,
    details: {
      stage,
      retryable: true,
      local_retryable: localRetryable
    }
  })
}

/**
 * Decides whether the next WebSocket open should force-refresh authorization.
 *
 * Only pre-open failures are eligible; after a request is sent, local retry
 * could duplicate response.create work.
 */
function shouldRefreshAuthorizationAfterWebSocketOpenFailure(error: unknown): boolean {
  if (!(error instanceof AIGatewayWebSocketError)) return false
  const details = recordValue(error.details)
  const stage = stringValue(details?.stage)
  return details?.local_retryable === true && stage !== undefined && stage.endsWith('_before_open')
}

/**
 * Normalizes Responses output items into the worker assistant-message shape.
 *
 * `textFallback` and `fallbackFunctionCalls` handle streaming transports that
 * deliver useful deltas or item events before a sparse terminal frame.
 */
function parseOutputItems(
  output: ResponseOutputItem[],
  modelName: string,
  usage: ModelUsage | undefined,
  terminalStatus?: StopReason,
  textFallback = '',
  errorMessage?: string,
  fallbackFunctionCalls: ResponseFunctionToolCall[] = []
): ModelCallResult {
  const functionCalls: ResponseFunctionToolCall[] = [...fallbackFunctionCalls]
  const seenFunctionCallIds = new Set(functionCalls.map(responseFunctionCallKey).filter(Boolean))
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
      const call = item as ResponseFunctionToolCall
      const id = responseFunctionCallKey(call)
      if (id && !seenFunctionCallIds.has(id)) {
        functionCalls.push(call)
        seenFunctionCallIds.add(id)
      }
    }
  }

  const text = textParts.join('') || textFallback
  const stopReason = terminalStatus ?? (functionCalls.length > 0 ? 'toolUse' : 'stop')
  const message: AssistantMessage = {
    role: 'assistant',
    content: text ? [{ type: 'text', text }] : [],
    toolCalls:
      functionCalls.length > 0
        ? functionCalls.map(fc => ({
            id: responseFunctionCallKey(fc) || '',
            type: 'function' as const,
            name: fc.name,
            arguments: fc.arguments
          }))
        : undefined,
    usage,
    stopReason,
    model: modelName,
    ...(errorMessage ? { errorMessage } : {})
  }

  return { message, functionCalls, hasToolCalls: functionCalls.length > 0 }
}

/**
 * Remembers a function_call output item by its stable call id.
 */
function rememberFunctionCall(calls: Map<string, ResponseFunctionToolCall>, item: Record<string, unknown>): void {
  if (item.type !== 'function_call') return
  const call = item as unknown as ResponseFunctionToolCall
  const callId = responseFunctionCallKey(call)
  if (callId) calls.set(callId, call)
}

/**
 * Reads the stable key used by Responses for a function call.
 */
function responseFunctionCallKey(call: Pick<ResponseFunctionToolCall, 'call_id' | 'id'>): string | undefined {
  return call.call_id || call.id
}

/**
 * Converts OpenAI/AIGateway usage objects to the small worker usage shape.
 */
function usageFromResponse(usage: unknown): ModelUsage | undefined {
  const value = recordValue(usage)
  if (!value) return undefined

  const outputDetails = recordValue(value.output_tokens_details)
  const inputDetails = recordValue(value.input_tokens_details)

  return {
    inputTokens: numberValue(value.input_tokens) ?? 0,
    outputTokens: numberValue(value.output_tokens) ?? 0,
    reasoningTokens: numberValue(outputDetails?.reasoning),
    cachedInputTokens: numberValue(inputDetails?.cached)
  }
}

/**
 * Extracts a useful terminal error message from failed or incomplete Responses
 * frames without depending on one exact gateway error schema.
 */
function terminalErrorMessage(
  response: Record<string, unknown> | undefined,
  frame: Record<string, unknown>
): string | undefined {
  const error = recordValue(response?.error) ?? recordValue(frame.error)
  const status =
    numberValue(error?.status) ??
    numberValue(error?.status_code) ??
    numberValue(error?.http_status) ??
    numberValue(frame.status)
  const code = stringValue(error?.code) ?? stringValue(frame.code)
  const message = stringValue(error?.message)

  if (status !== undefined || code || message) {
    return [
      'AIGateway response failed',
      status !== undefined ? `status=${status}` : undefined,
      code ? `code=${code}` : undefined,
      message
    ]
      .filter(Boolean)
      .join(' ')
  }

  const incomplete = recordValue(response?.incomplete_details)
  if (typeof incomplete?.reason === 'string') return incomplete.reason
  return undefined
}

/**
 * Converts an AIGateway error event frame into a structured Error object.
 */
function aigatewayErrorFromFrame(frame: Record<string, unknown>): AIGatewayWebSocketError {
  const error = recordValue(frame.error)

  return new AIGatewayWebSocketError(errorFrameMessage(frame), {
    code: stringValue(error?.code) ?? stringValue(frame.code),
    status: numberValue(frame.status) ?? numberValue(error?.status),
    details:
      recordValue(error?.details_json) ??
      recordValue(error?.details) ??
      recordValue(frame.details_json) ??
      recordValue(frame.details)
  })
}

/**
 * Extracts the most readable message from an error frame.
 */
function errorFrameMessage(frame: Record<string, unknown>): string {
  const error = recordValue(frame.error)
  if (typeof error?.message === 'string') return error.message
  if (typeof frame.message === 'string') return frame.message
  return 'AIGateway WebSocket returned an error frame'
}

/**
 * Converts WebSocket frame data into text before JSON parsing.
 */
function webSocketFrameText(data: unknown): string {
  if (typeof data === 'string') return data
  if (data instanceof Uint8Array) return new TextDecoder().decode(data)
  if (data instanceof ArrayBuffer) return new TextDecoder().decode(data)
  return String(data)
}

/**
 * Narrows unknown values to non-array records.
 */
function recordValue(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined
}

/**
 * Narrows unknown values to arrays.
 */
function arrayValue(value: unknown): unknown[] | undefined {
  return Array.isArray(value) ? value : undefined
}

/**
 * Narrows unknown values to numbers.
 */
function numberValue(value: unknown): number | undefined {
  return typeof value === 'number' ? value : undefined
}

/**
 * Narrows unknown values to strings.
 */
function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined
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
  let decoded: unknown
  try {
    decoded = JSON.parse(args)
  } catch (error) {
    throw new Error(`tool arguments must be valid JSON: ${errorMessage(error)}`)
  }

  return schema.parse(decoded)
}

/**
 * Converts unknown thrown values into readable text.
 */
function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/**
 * Helper to create a user message.
 */
export function userMessage(content: string | ContentPart[]): UserMessage {
  return { role: 'user', content }
}

/**
 * Reads assistant text as a single trimmed string for turn-result decisions.
 */
export function assistantText(message: AssistantMessage | undefined): string {
  if (!message) return ''
  return message.content
    .map(block => block.text)
    .join('\n')
    .trim()
}
