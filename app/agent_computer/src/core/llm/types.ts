import OpenAI from 'openai'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import type { z } from 'zod'
import type { CustomToolInputFormat } from 'openai/resources/shared'
import type {
  ResponseCreateParams,
  ResponseCustomToolCall,
  ResponseFunctionToolCall
} from 'openai/resources/responses/responses'

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
   * `length`. Their `arguments` hold the raw partial text as it arrived; they
   * are never executable and exist only so the failed attempt can re-enter
   * the thread as a call/error-result pair.
   */
  truncatedToolCalls?: ToolCall[]
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
  strict?: boolean
  namespace?: string
  namespaceDescription?: string
  deferLoading?: boolean
  toolSearchText?: string
  allowedCallers?: Array<'direct' | 'programmatic'>
  execute?: (args: z.infer<TSchema>, opts: { toolCallID: string }) => Promise<unknown> | unknown
}

export type ToolSet = Record<string, ToolDefinition>

export const BRAIN_OPERATIONS = [
  'remember',
  'learn_source',
  'recall',
  'get_page',
  'forget',
  'entity',
  'whoknows',
  'synthesize',
  'delta'
] as const

export type BrainOperation = (typeof BRAIN_OPERATIONS)[number]

/** Read-only Brain operations offered to Background Agent Jobs and workflow tasks. */
export const BRAIN_JOB_OPERATIONS: BrainOperation[] = ['recall', 'get_page']

export type HostedTool =
  | { type: 'image_generation' }
  | { type: 'web_search' }
  | { type: 'brain'; operations?: BrainOperation[]; inject?: boolean }

/** A hosted Brain item observed on the Responses stream. */
export type HostedBrainItemEvent = {
  callID: string
  operation: string
  phase: 'running' | 'completed' | 'failed'
}

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
}

export type ModelTurnCallOptions = Omit<CallModelOptions, 'abortSignal'>

// A stateful call continues exactly one anchor: the conversation it opens in,
// or the response it continues from. The union makes both illegal combinations
// unrepresentable — no anchor at all, and two competing anchors — so no caller
// has to clear one field while setting the other.
export type StatefulResponseAnchor = { conversationID: string } | { previousResponseID: string }

export type StatefulResponseContext = StatefulResponseAnchor & {
  actorEventID: string
  truncation?: 'auto' | 'disabled'
  metadata?: JSONObject
}

export interface ModelCallResult {
  message: AssistantMessage
  toolCalls: ResponseToolCall[]
  responseID?: string
  errorRetryable?: boolean
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
  /** AIGateway executed a hosted Brain operation inside this response. */
  onHostedBrainItem?: (event: HostedBrainItemEvent) => void
}
