import OpenAI from 'openai'
import { recordValue, type JsonObject } from '@pleisto/active-support'
import { ResponsesWS } from 'openai/resources/responses/ws'
import { ResponsesWSBase } from 'openai/resources/responses/ws-base'
import type {
  ResponseCreateParams,
  ResponseFunctionToolCall,
  ResponseOutputItem
} from 'openai/resources/responses/responses'
import type {
  Message,
  ModelCallResult,
  ModelConfig,
  ModelTurn,
  ModelTurnCallOptions,
  ModelTurnOptions,
  ResponseWebSocketTransport,
  StatefulResponseContext,
  StopReason,
  ToolResultsRecordResult
} from './types'
import {
  aigatewayErrorFromFrame,
  arrayValue,
  parseOutputItems,
  rememberFunctionCall,
  shouldRefreshAuthorizationAfterWebSocketOpenFailure,
  stringValue,
  terminalErrorMessage,
  usageFromResponse,
  webSocketTransportError
} from './parse'
import {
  buildResponseCreateParams,
  statefulResponseParams,
  statefulToolResultsRecordParams,
  toResponseInput
} from './wire'

type ResponsesSocket = ResponsesWS | InjectedResponsesWS
type InjectedSocketFactory = NonNullable<ResponseWebSocketTransport['createWebSocket']>
type InjectedSocketLike = ReturnType<InjectedSocketFactory>

interface SdkWebSocketLike {
  readonly readyState: number
  send(data: string | ArrayBufferLike | ArrayBufferView): void
  close(code?: number, reason?: string): void
  on(event: string, listener: (...args: never[]) => void): void
  off(event: string, listener: (...args: never[]) => void): void
  once(event: string, listener: (...args: never[]) => void): void
}

type ResponsesStreamMessage =
  | { type: 'connecting' | 'open' | 'closing' | 'reconnected' }
  | { type: 'reconnecting'; reconnect: unknown }
  | { type: 'close'; code: number; reason: string; unsent: unknown[] }
  | { type: 'message'; message: unknown }
  | { type: 'raw'; data: unknown }
  | { type: 'error'; error: { message: string; error?: unknown } }

type AIGatewayToolResultsRecordedFrame = {
  type: 'response.tool_results.recorded'
  response_id?: string
  response?: { id?: string }
}

export function createModelTurn(model: ModelConfig, options: ModelTurnOptions): ModelTurn {
  return new AIGatewayResponsesTurn(model, options)
}

class AIGatewayResponsesTurn implements ModelTurn {
  private stateful: StatefulResponseContext
  private ws: ResponsesSocket | undefined
  private opening: Promise<ResponsesSocket> | undefined
  private inFlight = false
  private closed = false
  private forceRefreshAuthorization = false

  constructor(
    private readonly model: ModelConfig,
    private readonly options: ModelTurnOptions
  ) {
    this.stateful = { ...options.stateful }
  }

  async call(options: ModelTurnCallOptions): Promise<ModelCallResult> {
    const params = statefulResponseParams(buildResponseCreateParams(this.model, options), this.stateful)
    await options.beforeCall?.(params)

    const result = await this.withSingleFlight(() => this.callOverWebSocket(params))
    if (result.responseId && result.message.stopReason !== 'error') this.advanceAnchor(result.responseId)
    return result
  }

  async recordToolResults(messages: Message[]): Promise<ToolResultsRecordResult> {
    const input = toResponseInput(messages)
    const params = statefulToolResultsRecordParams(this.model, input, this.stateful)

    const result = await this.withSingleFlight(() => this.recordToolResultsOverWebSocket(params))
    this.advanceAnchor(result.responseId)
    return result
  }

  close(): void {
    this.closed = true
    this.closeSocket()
  }

  private async withSingleFlight<T>(fn: () => Promise<T>): Promise<T> {
    if (this.inFlight) {
      throw new Error('AIGateway WebSocket session already has an active request')
    }

    this.inFlight = true
    try {
      return await fn()
    } catch (error) {
      if (shouldRefreshAuthorizationAfterWebSocketOpenFailure(error)) {
        this.forceRefreshAuthorization = true
      }
      throw error
    } finally {
      this.inFlight = false
    }
  }

  private async ensureOpen(): Promise<ResponsesSocket> {
    if (this.closed) {
      throw new Error('AIGateway WebSocket session is closed')
    }

    if (this.ws && responseSocketReadyState(this.ws) === 1) return this.ws
    if (this.opening) return this.opening

    this.opening = this.openFreshSocket().finally(() => {
      this.opening = undefined
    })

    return this.opening
  }

  private async openFreshSocket(): Promise<ResponsesSocket> {
    const transport = this.model.responseWebSocket
    if (!transport) {
      throw new Error('stateful response.create requires an AIGateway WebSocket transport')
    }

    const authorization = await transport.authorization(
      this.forceRefreshAuthorization ? { forceRefresh: true } : undefined
    )
    this.forceRefreshAuthorization = false

    const ws = responsesSocket(transport, authorization)
    this.ws = ws

    const stream = ws.stream() as AsyncIterableIterator<ResponsesStreamMessage>
    try {
      for (;;) {
        const { value, done } = await stream.next()
        if (done) {
          throw webSocketTransportError('AIGateway WebSocket closed before open', 'closed_before_open', true)
        }

        if (value.type === 'open') return ws
        if (value.type === 'error') {
          throw webSocketTransportError('AIGateway WebSocket transport error', 'transport_error_before_open', true)
        }
        if (value.type === 'close') {
          const suffix = value.reason ? `: ${value.reason}` : ''
          throw webSocketTransportError(`AIGateway WebSocket closed before open${suffix}`, 'closed_before_open', true)
        }
      }
    } catch (error) {
      this.discardSocket()
      throw error
    } finally {
      await stream.return?.()
    }
  }

  private async callOverWebSocket(params: ResponseCreateParams): Promise<ModelCallResult> {
    const ws = await this.ensureOpen()
    const stream = ws.stream() as AsyncIterableIterator<ResponsesStreamMessage>
    const requestPayload = { type: 'response.create' as const, ...params }
    let textBuffer = ''
    let responseId: string | undefined
    const stableItems: ResponseOutputItem[] = []
    const functionCallsById = new Map<string, ResponseFunctionToolCall>()

    try {
      ws.send(requestPayload)

      for await (const event of abortableResponsesStream(stream, this.options.abortSignal, () =>
        webSocketTransportError('LLM provider call aborted', 'aborted', false)
      )) {
        if (event.type === 'message') {
          const frame = recordValue(event.message)
          if (!frame) continue
          this.options.onActivity?.(typeof frame.type === 'string' ? frame.type : 'response.frame')

          switch (frame.type) {
            case 'response.output_text.delta': {
              const delta = typeof frame.delta === 'string' ? frame.delta : ''
              textBuffer += delta
              this.options.onTextDelta?.(delta)
              continue
            }

            case 'response.output_item.done': {
              const item = recordValue(frame.item)
              if (item) {
                stableItems.push(item as unknown as ResponseOutputItem)
                rememberFunctionCall(functionCallsById, item)
              }
              continue
            }

            case 'response.completed':
            case 'response.failed':
            case 'response.incomplete': {
              const response = recordValue(frame.response)
              const output = arrayValue(response?.output) as ResponseOutputItem[] | undefined
              const terminalItems = output && output.length > 0 ? output : stableItems
              const responseStatus = typeof response?.status === 'string' ? response.status : undefined
              responseId = typeof response?.id === 'string' ? response.id : responseId
              const usage = usageFromResponse(recordValue(response?.usage))
              const terminal = terminalProjection(frame.type, responseStatus, response, frame)
              const result = parseOutputItems(
                terminalItems,
                this.model.name,
                usage,
                terminal.status,
                textBuffer,
                terminal.errorMessage,
                [...functionCallsById.values()]
              )
              result.responseId = responseId
              await stream.return?.()
              return result
            }

            case 'error':
              throw aigatewayErrorFromFrame(frame)

            default:
              continue
          }
        }

        if (event.type === 'error') {
          throw aigatewayErrorFromStreamError(event.error)
        }

        if (event.type === 'close') {
          const suffix = event.reason ? `: ${event.reason}` : ''
          throw webSocketTransportError(
            `AIGateway WebSocket closed before response.completed${suffix}`,
            'closed_before_terminal',
            false
          )
        }
      }

      throw webSocketTransportError(
        'AIGateway WebSocket closed before response.completed',
        'closed_before_terminal',
        false
      )
    } catch (error) {
      this.discardSocket()
      throw error
    }
  }

  private async recordToolResultsOverWebSocket(params: ResponseCreateParams): Promise<ToolResultsRecordResult> {
    const ws = await this.ensureOpen()
    const stream = ws.stream() as AsyncIterableIterator<ResponsesStreamMessage>
    const requestPayload = JSON.stringify({ type: 'response.tool_results.record', ...params })

    try {
      ws.sendRaw(requestPayload)

      for await (const event of abortableResponsesStream(stream, this.options.abortSignal, () =>
        webSocketTransportError('Tool result recording aborted', 'aborted', false)
      )) {
        if (event.type === 'message') {
          const frame = recordValue(event.message)
          if (!frame) continue
          this.options.onActivity?.(typeof frame.type === 'string' ? frame.type : 'response.tool_results.frame')

          switch (frame.type) {
            case 'response.tool_results.recorded': {
              const response = recordValue(frame.response)
              const responseId = stringValue(response?.id) ?? stringValue(frame.response_id)
              if (!responseId) {
                throw new Error('AIGateway tool result record ack did not include response.id')
              }
              await stream.return?.()
              return { responseId }
            }

            case 'error':
              throw aigatewayErrorFromFrame(frame)

            default:
              continue
          }
        }

        if (event.type === 'error') {
          throw aigatewayErrorFromStreamError(event.error)
        }

        if (event.type === 'close') {
          const suffix = event.reason ? `: ${event.reason}` : ''
          throw webSocketTransportError(
            `AIGateway WebSocket closed before response.tool_results.recorded${suffix}`,
            'tool_results_record_closed_before_ack',
            true
          )
        }
      }

      throw webSocketTransportError(
        'AIGateway WebSocket closed before response.tool_results.recorded',
        'tool_results_record_closed_before_ack',
        true
      )
    } catch (error) {
      this.discardSocket()
      throw error
    }
  }

  private advanceAnchor(responseId: string): void {
    this.stateful = {
      ...this.stateful,
      conversationId: undefined,
      previousResponseId: responseId
    }
  }

  private discardSocket(): void {
    this.closeSocket()
    this.ws = undefined
  }

  private closeSocket(): void {
    if (!this.ws) return

    try {
      this.ws.close({ code: 1000, reason: 'OK' })
    } catch {
      // ignore close races after terminal frames or failures
    }
  }
}

function responsesSocket(transport: ResponseWebSocketTransport, authorization: string): ResponsesSocket {
  const client = openAIClientForWebSocket(transport.url)
  if (transport.createWebSocket) {
    return new InjectedResponsesWS(client, transport.createWebSocket, { authorization })
  }

  return new ResponsesWS(client, {
    reconnect: null,
    headers: { Authorization: authorization }
  } as never)
}

function openAIClientForWebSocket(webSocketUrl: string): OpenAI {
  return new OpenAI({
    apiKey: 'unused',
    baseURL: httpBaseUrlFromWebSocketUrl(webSocketUrl)
  })
}

function httpBaseUrlFromWebSocketUrl(webSocketUrl: string): string {
  const url = new URL(webSocketUrl)
  url.protocol = url.protocol === 'ws:' ? 'http:' : 'https:'
  url.pathname = url.pathname.replace(/\/responses\/?$/, '')
  return url.toString().replace(/\/+$/, '')
}

function responseSocketReadyState(ws: ResponsesSocket): number | undefined {
  return (ws as unknown as { socket?: { readyState?: number } }).socket?.readyState
}

function terminalProjection(
  frameType: string | undefined,
  responseStatus: string | undefined,
  response: JsonObject | undefined,
  frame: JsonObject
): { status?: StopReason; errorMessage?: string } {
  if (frameType === 'response.completed' && responseStatus !== 'failed') return {}

  if (frameType === 'response.incomplete') {
    const reason = incompleteReason(response)
    if (reason === 'max_output_tokens') return { status: 'length' }

    return {
      status: 'error',
      errorMessage: `AIGateway response incomplete reason=${reason || 'unknown'}`
    }
  }

  return {
    status: 'error',
    errorMessage: terminalErrorMessage(response, frame)
  }
}

function incompleteReason(response: JsonObject | undefined): string | undefined {
  return stringValue(recordValue(response?.incomplete_details)?.reason)
}

function aigatewayErrorFromStreamError(error: { message: string; error?: unknown }): Error {
  const frame = recordValue(error.error)
  if (frame) return aigatewayErrorFromFrame(frame)
  return webSocketTransportError(
    error.message || 'AIGateway WebSocket transport error',
    'transport_error_after_open',
    false
  )
}

async function* abortableResponsesStream(
  stream: AsyncIterableIterator<ResponsesStreamMessage>,
  signal: AbortSignal | undefined,
  abortError: () => Error
): AsyncIterable<ResponsesStreamMessage> {
  if (!signal) {
    yield* stream
    return
  }

  let abortListener: (() => void) | undefined
  const aborted = new Promise<never>((_, reject) => {
    abortListener = () => reject(abortError())
    signal.addEventListener('abort', abortListener, { once: true })
  })

  try {
    if (signal.aborted) throw abortError()

    for (;;) {
      const next = await Promise.race([stream.next(), aborted])
      if (next.done) return
      yield next.value
    }
  } finally {
    if (abortListener) signal.removeEventListener('abort', abortListener)
  }
}

export type { AIGatewayToolResultsRecordedFrame }

class InjectedResponsesWS extends ResponsesWSBase<InjectedWebSocketAdapter> {
  constructor(
    client: OpenAI,
    private readonly factory: InjectedSocketFactory,
    private readonly headers: Record<string, string>
  ) {
    super(client, { reconnect: null })
    this._connectInitial()
  }

  protected _createSocket(url: URL, authHeaders: Record<string, string>): InjectedWebSocketAdapter {
    return new InjectedWebSocketAdapter(
      this.factory(url.toString(), {
        headers: {
          ...authHeaders,
          ...this.headers
        }
      })
    )
  }
}

class InjectedWebSocketAdapter implements SdkWebSocketLike {
  private listeners = new Map<string, Map<(...args: never[]) => void, (event: unknown) => void>>()

  constructor(private readonly socket: InjectedSocketLike) {}

  get readyState(): number {
    return this.socket.readyState ?? 0
  }

  send(data: string | ArrayBufferLike | ArrayBufferView): void {
    this.socket.send(typeof data === 'string' ? data : String(data))
  }

  close(code?: number, reason?: string): void {
    this.socket.close(code, reason)
  }

  on(event: string, listener: (...args: never[]) => void): void {
    const wrapped = this.wrapListener(event, listener, false)
    const listeners = this.listeners.get(event) ?? new Map()
    listeners.set(listener, wrapped)
    this.listeners.set(event, listeners)
    this.socket.addEventListener(event as never, wrapped as never)
  }

  once(event: string, listener: (...args: never[]) => void): void {
    const wrapped = this.wrapListener(event, listener, true)
    const listeners = this.listeners.get(event) ?? new Map()
    listeners.set(listener, wrapped)
    this.listeners.set(event, listeners)
    this.socket.addEventListener(event as never, wrapped as never, { once: true })
  }

  off(event: string, listener: (...args: never[]) => void): void {
    const wrapped = this.listeners.get(event)?.get(listener)
    if (!wrapped) return
    this.socket.removeEventListener?.(event, wrapped)
    this.listeners.get(event)?.delete(listener)
  }

  private wrapListener(event: string, listener: (...args: never[]) => void, once: boolean): (event: unknown) => void {
    return rawEvent => {
      if (once) this.off(event, listener)

      if (event === 'message') {
        const message = rawEvent as MessageEvent
        listener(message.data as never, (typeof message.data !== 'string') as never)
        return
      }

      if (event === 'close') {
        const close = rawEvent as CloseEvent
        listener((close.code ?? 1006) as never, (close.reason ?? '') as never)
        return
      }

      if (event === 'error') {
        listener(new Error('AIGateway WebSocket transport error') as never)
        return
      }

      listener()
    }
  }
}
