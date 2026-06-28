import { fixJson } from './util/fix-json'
import type { LanguageModel } from './types'
import type { ProviderOptions } from './provider-utils'
import type { z } from 'zod'

// This module is Ankole's durable LLM abstraction layer. It sits ON TOP of the
// vendored Vercel AI SDK (everything else under src/llm/) and defines the
// provider-neutral shapes the agent runtime persists to the ledger: Message,
// AssistantMessage, Usage, ToolCall, Model. The AI SDK speaks the per-call wire
// format (ModelMessage / content parts); this module speaks the format that
// survives across turns, recovery, and audit. The translation between the two
// lives in ankole-ai-sdk.ts.

/** Provider API dialect (e.g. 'openai-responses', 'anthropic-messages', 'openai-completions'); selects which AI SDK transport a model speaks. */
export type Api = string
/** Provider kind as stored in installation config (e.g. 'openai', 'anthropic', 'openrouter'). */
export type Provider = string
export type ThinkingLevel = 'minimal' | 'low' | 'medium' | 'high' | 'xhigh'
/** Per-model reasoning capability: 'off' disables it, otherwise one of the shared thinking levels. */
export type ModelThinkingLevel = 'off' | ThinkingLevel
/** Per-call reasoning request: 'none' opts out even on a reasoning-capable model. */
export type ReasoningEffort = 'none' | ThinkingLevel
/** Maps an Ankole thinking level to the provider's own reasoning token/string (null = unsupported at that level). */
export type ThinkingLevelMap = Partial<Record<ModelThinkingLevel, string | null>>
/** Provider-neutral prompt-cache request. 'short'/'long' map to per-provider TTLs in ankole-ai-sdk.ts; 'none' disables caching. */
export type CacheRetention = 'none' | 'short' | 'long'

export interface ProviderResponse {
  status: number
  headers: Record<string, string>
}

/** Caller-supplied knobs for a single Ankole LLM call, normalized away from any one provider's option names. */
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
  // Free-form trace context (e.g. conversation_id / cache_key). Drives prompt-cache key
  // derivation in ankole-ai-sdk.ts so cache reuse never leaks across conversations.
  metadata?: Record<string, unknown>
  // Escape hatch: raw AI SDK provider options from the control plane, merged with (not
  // overwritten by) Ankole's own cache controls.
  providerOptions?: ProviderOptions
}

/** StreamOptions plus a reasoning effort request; the everyday option shape callers pass to generate/stream. */
export interface SimpleStreamOptions extends StreamOptions {
  reasoning?: ReasoningEffort
}

export interface TextContent {
  type: 'text'
  text: string
  // Opaque provider signature for this text block (e.g. Anthropic's signed content),
  // round-tripped verbatim so a replayed transcript stays acceptable to the provider.
  textSignature?: string
}

export interface ThinkingContent {
  type: 'thinking'
  thinking: string
  // Opaque provider signature proving this reasoning block was emitted by the model;
  // must be preserved to send the thinking back on later turns.
  thinkingSignature?: string
  // Provider hid the reasoning text (safety-redacted); the block still occupies a slot
  // so signatures and ordering line up on replay.
  redacted?: boolean
}

export interface ImageContent {
  type: 'image'
  // Base64-encoded image bytes (not a URL); the agent computer keeps image data inline.
  data: string
  mimeType: string
}

/** A model's request to invoke an Ankole tool. `id` correlates with the matching ToolResultMessage on the next turn. */
export interface ToolCall {
  type: 'toolCall'
  id: string
  name: string
  arguments: Record<string, any>
  // Gemini-style signed-thought token attached to a tool call; preserved for replay.
  thoughtSignature?: string
}

/**
 * Token accounting for one assistant turn, in Ankole's normalized buckets.
 *
 * Providers report cache hits/misses inconsistently; Ankole flattens them to four input
 * buckets so cost is comparable across providers:
 *  - input:      prompt tokens billed at full rate (provider's reported input count)
 *  - cacheRead:  prompt tokens served from a prompt cache (cheap; e.g. Anthropic cache-read,
 *                OpenAI cached input)
 *  - cacheWrite: prompt tokens written INTO the cache this turn (a one-time premium on some
 *                providers; zero where the provider doesn't bill cache writes)
 *  - output:     completion tokens
 * `cost` mirrors those buckets in currency and is filled in by calculateCost() using the
 * model's per-token prices. `totalTokens` is the provider's grand total when given.
 */
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

/** Why a turn ended. 'toolUse' means the model wants tools run; 'aborted' means a caller signal cancelled it. */
export type StopReason = 'stop' | 'length' | 'toolUse' | 'error' | 'aborted'

export interface UserMessage {
  role: 'user'
  // Plain string for the common text-only case; the array form carries mixed text + images.
  content: string | (TextContent | ImageContent)[]
  timestamp: number
}

/**
 * A persisted assistant turn. This is the durable record Ankole writes to the ledger, so it
 * keeps provenance the wire format discards: which model/provider/api produced it, the
 * provider's response id (for support/debugging), token usage+cost, and why it stopped.
 * `model` is the requested model id; `responseModel` is what the provider actually served
 * (they differ when a provider aliases or upgrades a model).
 */
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
  // Set only when stopReason is 'error'/'aborted'; carries the raw provider/SDK error text
  // (also matched against OVERFLOW_PATTERNS below to detect context overflow).
  errorMessage?: string
  timestamp: number
}

/**
 * The outcome of running one tool, fed back to the model on the next turn. `toolCallId`
 * must equal the originating ToolCall.id so the provider can pair them. `details` is an
 * Ankole-side typed payload kept out of the model-visible `content` (for UI/audit, not sent
 * to the LLM).
 */
export interface ToolResultMessage<TDetails = any> {
  role: 'toolResult'
  toolCallId: string
  toolName: string
  content: (TextContent | ImageContent)[]
  details?: TDetails
  isError: boolean
  timestamp: number
}

/** One entry in a durable Ankole transcript. Note: Ankole's role is 'toolResult'; the AI SDK wire role is 'tool'. */
export type Message = UserMessage | AssistantMessage | ToolResultMessage

/** A tool offered to the model: name + description for the prompt, plus a Zod schema used to validate the model's arguments. */
export interface AnkoleTool<TParameters extends z.ZodType = z.ZodType> {
  name: string
  description: string
  schema: TParameters
}

/** Everything needed to make one Ankole call: the system prompt, the transcript so far, and the tools in scope. */
export interface Context {
  systemPrompt?: string
  messages: Message[]
  tools?: AnkoleTool[]
}

/**
 * The streaming protocol Ankole emits while an assistant turn is being produced.
 * Every event carries `partial`: the assistant message accumulated so far (so a consumer
 * can render or checkpoint mid-stream). `contentIndex` is the slot in `partial.content`
 * the event applies to, letting interleaved text/thinking/tool-call blocks be tracked
 * independently. The stream ends with exactly one terminal event: `done` on success or
 * `error` on abort/failure.
 */
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

/**
 * Resolved metadata for one model Ankole can call. Built from the catalog (see catalog.ts)
 * and then enriched at request time once provider config is known.
 *
 * `cost` is per-token price in the same four buckets as Usage, so calculateCost() is a
 * straight multiply. `sdkModel` is the concrete AI SDK LanguageModel instance, attached
 * only after API key / base URL are resolved (catalog entries leave it undefined). A model
 * with no `sdkModel` cannot be called — generate/stream short-circuit to an error.
 */
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
  // Provider-specific compatibility flags (e.g. quirks for OpenAI-compatible endpoints).
  compat?: Record<string, unknown>
  sdkModel?: LanguageModel
}

/**
 * Canonical empty Usage, used as the baseline for turns that produced no measurable usage
 * (error paths, providers that return no usage block). Treat it as immutable: callers that
 * need a mutable copy spread BOTH `usage` and the nested `cost` (e.g.
 * `{ ...ZERO_USAGE, cost: { ...ZERO_USAGE.cost } }`) so the shared `cost` object isn't aliased.
 */
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

/**
 * Multiplies each token bucket by the model's per-token price to fill in `usage.cost`.
 * Runs after provider usage has been mapped into Ankole's four buckets (see toAnkoleUsage).
 * `total` is the plain sum of the four — cache reads/writes are already separate line items,
 * so it does NOT double-count them with `input`.
 */
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
  // Duck-typed on `.parse` rather than instanceof ZodType so it tolerates tools whose schema
  // is absent or non-Zod; in that case the raw arguments pass through unvalidated.
  if (typeof tool.schema?.parse === 'function') return tool.schema.parse(toolCall.arguments)
  return toolCall.arguments
}

/**
 * Tolerant JSON parse for model output that may be truncated or slightly malformed.
 * `fixJson` returns undefined when it can't repair the input — in that case we fall back to
 * strict JSON.parse so the caller still gets a real SyntaxError rather than a silent null.
 */
export function parseJsonWithRepair<T>(json: string): T {
  const fixed = fixJson(json)
  if (fixed === undefined) return JSON.parse(json) as T
  return JSON.parse(fixed) as T
}

// No provider exposes a machine-readable "context overflow" code, so we sniff their error
// strings. This list is deliberately broad to cover OpenAI/Anthropic/Google/compatible
// wordings; the agent loop uses a positive match to trigger context compaction/summarization.
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
  // Path 1: provider rejected the request outright — match its error text.
  if (message.stopReason === 'error' && message.errorMessage) {
    return OVERFLOW_PATTERNS.some(pattern => pattern.test(message.errorMessage!))
  }
  // Path 2: provider accepted but billed more input than the window holds.
  if (contextWindow && contextWindow > 0 && message.usage.input > contextWindow) return true
  // Path 3: a 'length' stop at exactly the window with ZERO output means the prompt itself
  // filled the window (true overflow), as opposed to a normal turn that simply hit maxTokens
  // while generating (output > 0) — which is NOT overflow.
  if (contextWindow && contextWindow > 0 && message.stopReason === 'length' && message.usage.input >= contextWindow) {
    return message.usage.output === 0
  }
  return false
}
