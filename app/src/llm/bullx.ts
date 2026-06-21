import { fixJson } from './util/fix-json'
import type { LanguageModel } from './types'
import type { z } from 'zod'

export type Api = string
export type Provider = string
export type ThinkingLevel = 'minimal' | 'low' | 'medium' | 'high' | 'xhigh'
export type ModelThinkingLevel = 'off' | ThinkingLevel
export type ReasoningEffort = 'none' | ThinkingLevel
export type ThinkingLevelMap = Partial<Record<ModelThinkingLevel, string | null>>
export type CacheRetention = 'none' | 'short' | 'long'

export interface ProviderResponse {
  status: number
  headers: Record<string, string>
}

export interface StreamOptions {
  temperature?: number
  maxTokens?: number
  signal?: AbortSignal
  apiKey?: string
  cacheRetention?: CacheRetention
  onPayload?: (payload: unknown, model: Model<Api>) => unknown | undefined | Promise<unknown | undefined>
  onResponse?: (response: ProviderResponse, model: Model<Api>) => void | Promise<void>
  headers?: Record<string, string>
  timeoutMs?: number
  maxRetries?: number
  maxRetryDelayMs?: number
  metadata?: Record<string, unknown>
}

export interface SimpleStreamOptions extends StreamOptions {
  reasoning?: ReasoningEffort
}

export interface TextContent {
  type: 'text'
  text: string
  textSignature?: string
}

export interface ThinkingContent {
  type: 'thinking'
  thinking: string
  thinkingSignature?: string
  redacted?: boolean
}

export interface ImageContent {
  type: 'image'
  data: string
  mimeType: string
}

export interface ToolCall {
  type: 'toolCall'
  id: string
  name: string
  arguments: Record<string, any>
  thoughtSignature?: string
}

export interface Usage {
  input: number
  output: number
  cacheRead: number
  cacheWrite: number
  totalTokens: number
  cost: {
    input: number
    output: number
    cacheRead: number
    cacheWrite: number
    total: number
  }
}

export type StopReason = 'stop' | 'length' | 'toolUse' | 'error' | 'aborted'

export interface UserMessage {
  role: 'user'
  content: string | (TextContent | ImageContent)[]
  timestamp: number
}

export interface AssistantMessage {
  role: 'assistant'
  content: (TextContent | ThinkingContent | ToolCall)[]
  api: Api
  provider: Provider
  model: string
  responseModel?: string
  responseId?: string
  diagnostics?: unknown[]
  usage: Usage
  stopReason: StopReason
  errorMessage?: string
  timestamp: number
}

export interface ToolResultMessage<TDetails = any> {
  role: 'toolResult'
  toolCallId: string
  toolName: string
  content: (TextContent | ImageContent)[]
  details?: TDetails
  isError: boolean
  timestamp: number
}

export type Message = UserMessage | AssistantMessage | ToolResultMessage

export interface BullXTool<TParameters extends z.ZodType = z.ZodType> {
  name: string
  description: string
  schema: TParameters
}

export interface Context {
  systemPrompt?: string
  messages: Message[]
  tools?: BullXTool[]
}

export type AssistantMessageEvent =
  | { type: 'start'; partial: AssistantMessage }
  | { type: 'text_start'; contentIndex: number; partial: AssistantMessage }
  | { type: 'text_delta'; contentIndex: number; delta: string; partial: AssistantMessage }
  | { type: 'text_end'; contentIndex: number; content: string; partial: AssistantMessage }
  | { type: 'thinking_start'; contentIndex: number; partial: AssistantMessage }
  | { type: 'thinking_delta'; contentIndex: number; delta: string; partial: AssistantMessage }
  | { type: 'thinking_end'; contentIndex: number; content: string; partial: AssistantMessage }
  | { type: 'toolcall_start'; contentIndex: number; partial: AssistantMessage }
  | { type: 'toolcall_delta'; contentIndex: number; delta: string; partial: AssistantMessage }
  | { type: 'toolcall_end'; contentIndex: number; toolCall: ToolCall; partial: AssistantMessage }
  | { type: 'done'; reason: Extract<StopReason, 'stop' | 'length' | 'toolUse'>; message: AssistantMessage }
  | { type: 'error'; reason: Extract<StopReason, 'aborted' | 'error'>; error: AssistantMessage }

export interface Model<TApi extends Api = Api> {
  id: string
  name: string
  api: TApi
  provider: Provider
  baseUrl: string
  reasoning: boolean
  thinkingLevelMap?: ThinkingLevelMap
  input: ('text' | 'image')[]
  cost: {
    input: number
    output: number
    cacheRead: number
    cacheWrite: number
  }
  contextWindow: number
  maxTokens: number
  headers?: Record<string, string>
  compat?: Record<string, unknown>
  sdkModel?: LanguageModel
}

export const ZERO_USAGE: Usage = {
  input: 0,
  output: 0,
  cacheRead: 0,
  cacheWrite: 0,
  totalTokens: 0,
  cost: {
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
    total: 0
  }
}

/** Calculates the normalized cost fields from model metadata after provider usage has been mapped to BullX tokens. */
export function calculateCost(model: Model<any>, usage: Usage): Usage['cost'] {
  return {
    input: usage.input * model.cost.input,
    output: usage.output * model.cost.output,
    cacheRead: usage.cacheRead * model.cost.cacheRead,
    cacheWrite: usage.cacheWrite * model.cost.cacheWrite,
    total:
      usage.input * model.cost.input +
      usage.output * model.cost.output +
      usage.cacheRead * model.cost.cacheRead +
      usage.cacheWrite * model.cost.cacheWrite
  }
}

/** Parses model tool-call arguments with the tool schema before the agent loop executes side effects. */
export function validateToolArguments(
  tool: {
    schema?: { parse?: (value: unknown) => unknown }
  },
  toolCall: ToolCall
): any {
  if (typeof tool.schema?.parse === 'function') return tool.schema.parse(toolCall.arguments)
  return toolCall.arguments
}

/** Repairs common malformed JSON from lightweight LLM calls before falling back to strict parsing. */
export function parseJsonWithRepair<T>(json: string): T {
  const fixed = fixJson(json)
  if (fixed === undefined) return JSON.parse(json) as T
  return JSON.parse(fixed) as T
}

const OVERFLOW_PATTERNS = [
  /context (?:window|length)/i,
  /maximum context/i,
  /prompt is too long/i,
  /input token count exceeds/i,
  /maximum prompt length/i,
  /reduce the length/i,
  /request_too_large/i,
  /too large for model/i,
  /exceeds the available context/i,
  /greater than the context length/i,
  /exceeded model token limit/i
]

/** Detects context overflow across providers that report it either as text errors, length stops, or usage counts. */
export function isContextOverflow(message: AssistantMessage, contextWindow?: number): boolean {
  if (message.stopReason === 'error' && message.errorMessage) {
    return OVERFLOW_PATTERNS.some(pattern => pattern.test(message.errorMessage!))
  }
  if (contextWindow && contextWindow > 0 && message.usage.input > contextWindow) return true
  if (contextWindow && contextWindow > 0 && message.stopReason === 'length' && message.usage.input >= contextWindow) {
    return message.usage.output === 0
  }
  return false
}
