import OpenAI from 'openai'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import type { z } from 'zod'
import type { CustomToolInputFormat } from 'openai/resources/shared'
import type {
  ResponseCreateParams,
  ResponseCustomToolCall,
  ResponseFunctionToolCall
} from 'openai/resources/responses/responses'
import type { TruncatedToolCall } from './partial-tool-input'

export interface TextContent {
  type: 'text'
  text: string
}

export interface ImageContent {
  type: 'image'
  image: string | URL | Uint8Array | BufferSource
  mimeType?: string
}

export type ContentPart = TextContent | ImageContent

export interface ToolCall {
  id: string
  type: 'function' | 'custom'
  name: string
  namespace?: string
  arguments: string
  caller?: ToolCaller
}

export type ToolCaller = { type: 'direct' } | { type: 'program'; caller_id: string }
export type ResponseToolCall = ResponseFunctionToolCall | ResponseCustomToolCall

export interface UserMessage {
  role: 'user'
  content: string | ContentPart[]
}

export interface AssistantMessage {
  role: 'assistant'
  content: TextContent[]
  toolCalls?: ToolCall[]
  /**
   * Calls the output-token limit discarded, present only when `stopReason` is
   * `length`. They record where the model stopped writing arguments and are
   * never executable.
   */
  truncatedToolCalls?: TruncatedToolCall[]
  usage?: ModelUsage
  stopReason?: StopReason
  model?: string
  errorMessage?: string
}

export interface ToolResultMessage {
  role: 'tool'
  toolCallID: string
  toolCallType?: ToolCall['type']
  result: string
  caller?: ToolCaller
}

export type Message = UserMessage | AssistantMessage | ToolResultMessage

export interface ModelUsage {
  inputTokens: number
  outputTokens: number
  reasoningTokens?: number
  cachedInputTokens?: number
}

export type StopReason = 'stop' | 'length' | 'toolUse' | 'error' | 'aborted'

export interface ModelConfig {
  client: OpenAI
  selector: string
  name: string
  provider: string
  providerOptions?: JSONObject
  responseWebSocket?: ResponseWebSocketTransport
}

export type ResponseWebSocketTransport = {
  kind: 'aigateway-websocket'
  url: string
  authorization: (options?: ResponseWebSocketAuthorizationOptions) => Promise<string> | string
  headers?: Record<string, string>
  /** Test seam for fake AIGateway sockets; production uses OpenAI SDK ResponsesWS. */
  createWebSocket?: (
    url: string,
    init: { headers: Record<string, string> }
  ) => {
    readyState?: number
    send(data: string): void
    close(code?: number, reason?: string): void
    addEventListener(type: 'open', listener: (event: Event) => void, options?: { once?: boolean }): void
    addEventListener(type: 'message', listener: (event: MessageEvent) => void, options?: { once?: boolean }): void
    addEventListener(type: 'error', listener: (event: Event) => void, options?: { once?: boolean }): void
    addEventListener(type: 'close', listener: (event: CloseEvent) => void, options?: { once?: boolean }): void
    removeEventListener?(type: string, listener: (event: unknown) => void): void
  }
}

export type ResponseWebSocketAuthorizationOptions = {
  forceRefresh?: boolean
}

export interface ToolDefinition<TSchema extends z.ZodType = z.ZodType> {
  name: string
  description?: string
  parameters: TSchema
  inputFormat?: CustomToolInputFormat
  jsonSchema?: Record<string, unknown>
  outputSchema?: Record<string, unknown>
  namespace?: string
  namespaceDescription?: string
  deferLoading?: boolean
  toolSearchText?: string
  allowedCallers?: Array<'direct' | 'programmatic'>
  execute?: (args: z.infer<TSchema>, opts: { toolCallID: string }) => Promise<unknown> | unknown
}

export type ToolSet = Record<string, ToolDefinition>

export type HostedTool = { type: 'image_generation' } | { type: 'web_search' }

export interface CallModelOptions {
  instructions?: string
  messages: Message[]
  tools?: ToolSet
  hostedTools?: HostedTool[]
  programmaticToolCalling?: boolean
  maxOutputTokens?: number
  temperature?: number
  text?: ResponseCreateParams['text']
  abortSignal?: AbortSignal
  beforeCall?: (payload: ResponseCreateParams) => void | Promise<void>
  onTextDelta?: (delta: string) => void
  onActivity?: (description?: string) => void
  stateful?: StatefulResponseContext
}

export type ModelTurnCallOptions = Omit<CallModelOptions, 'stateful' | 'abortSignal' | 'onActivity' | 'onTextDelta'>

export type StatefulResponseContext = {
  actorEventID: string
  conversationID?: string
  previousResponseID?: string
  truncation?: 'auto' | 'disabled'
  metadata?: JSONObject
}

export interface ModelCallResult {
  message: AssistantMessage
  toolCalls: ResponseToolCall[]
  hasToolCalls: boolean
  responseID?: string
}

export interface ToolResultsRecordResult {
  responseID: string
}

export interface ToolResultsRecordOptions {
  completeActorEventIDs?: string[]
}

export interface ModelTurn {
  call(options: ModelTurnCallOptions): Promise<ModelCallResult>
  recordToolResults(messages: Message[], options?: ToolResultsRecordOptions): Promise<ToolResultsRecordResult>
  close(): void
}

export interface ModelTurnOptions {
  stateful: StatefulResponseContext
  abortSignal?: AbortSignal
  onTextDelta?: (delta: string) => void
  onActivity?: (description?: string) => void
}
