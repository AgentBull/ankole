import type {
  LanguageModelV4,
  LanguageModelV4Content,
  LanguageModelV4FinishReason,
  LanguageModelV4StreamPart,
  LanguageModelV4Usage
} from './provider'
import type { AssistantMessage, Model, ToolCall, Usage } from './bullx'

// In-process FAKE LLM provider for tests. It lets a test script a sequence of canned
// AssistantMessages and exposes them through a real AI SDK LanguageModelV4 instance, so the
// whole BullX -> AI SDK -> BullX round trip (including streaming) can be exercised with zero
// network calls. The model's `api`/`provider` are the literal string 'faux'.

/** One scripted turn: either a fixed AssistantMessage, or a function that can inspect the prompt/signal and decide. */
export type FauxResponseStep =
  | AssistantMessage
  | ((context: unknown, options: { signal?: AbortSignal }) => AssistantMessage | Promise<AssistantMessage>)

/** Handle returned to a test for driving one fake provider: swap its scripted responses, look up its models, or tear it down. */
export interface FauxProviderRegistration {
  provider: string
  getModel(id: string): Model<any> | undefined
  setResponses(responses: FauxResponseStep[]): void
  unregister(): void
}

// Module-level registry of live fake providers. Currently a bookkeeping set so unregister()
// has somewhere to remove from; tests hold their own registration handle for lookups.
const registrations = new Set<FauxProviderRegistration>()

/**
 * Spins up a fake provider with the given models. Each model gets a working `sdkModel` wired
 * to a shared response queue. The queue advances one step per call and, once exhausted, keeps
 * replaying the LAST scripted response (so a test that scripts N turns but the agent loops more
 * doesn't fall off the end). With no script at all, it answers with an empty assistant message.
 */
export function registerFauxProvider(input: {
  provider: string
  models: Array<{ id: string; contextWindow?: number; maxTokens?: number }>
}): FauxProviderRegistration {
  let responses: FauxResponseStep[] = []
  let calls = 0
  const models = new Map<string, Model<any>>()
  const nextResponse = async (context: unknown, options: { signal?: AbortSignal }) => {
    // Clamp the index so calls past the end stick to the final scripted step (or index 0 when empty).
    const step = responses[Math.min(calls, Math.max(0, responses.length - 1))]
    calls += 1
    if (!step) return fauxAssistantMessage('')
    return typeof step === 'function' ? await step(context, options) : step
  }

  // Build a ready-to-call Model per id, mirroring the real catalog shape so code under test
  // can't tell a fake model from a real one. All share the same nextResponse queue.
  for (const item of input.models) {
    models.set(item.id, {
      id: item.id,
      name: item.id,
      api: 'faux',
      provider: input.provider,
      baseUrl: 'faux://local',
      reasoning: true,
      input: ['text', 'image'],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: item.contextWindow ?? 128000,
      maxTokens: item.maxTokens ?? 8192,
      sdkModel: createFauxSdkModel(input.provider, item.id, nextResponse)
    })
  }

  const registration: FauxProviderRegistration = {
    provider: input.provider,
    getModel: id => models.get(id),
    // Re-script and rewind: a test calls this to set the next run's responses from call 0.
    setResponses(next) {
      responses = [...next]
      calls = 0
    },
    unregister() {
      registrations.delete(registration)
    }
  }
  registrations.add(registration)
  return registration
}

/** Convenience for scripting a tool-call block in a faux response; id defaults to a stable `call_<name>`. */
export function fauxToolCall(name: string, args: Record<string, unknown> = {}, id = `call_${name}`): ToolCall {
  return {
    type: 'toolCall',
    id,
    name,
    arguments: args
  }
}

/**
 * Builds a faux AssistantMessage from either a plain string (one text block; empty string -> no
 * blocks) or explicit content blocks. The stop reason is inferred: a response containing any
 * tool call is 'toolUse', otherwise 'stop' — matching how a real provider would finish those
 * turns. `extra` overrides any field (e.g. set stopReason 'error' + errorMessage to script a failure).
 */
export function fauxAssistantMessage(
  content: string | AssistantMessage['content'],
  extra: Partial<AssistantMessage> = {}
): AssistantMessage {
  const blocks = typeof content === 'string' ? (content ? [{ type: 'text' as const, text: content }] : []) : content
  const stopReason = blocks.some(block => block.type === 'toolCall') ? 'toolUse' : 'stop'
  return {
    role: 'assistant',
    content: blocks,
    api: 'faux',
    provider: 'faux',
    model: 'faux',
    usage: zeroUsage(),
    stopReason,
    timestamp: Date.now(),
    ...extra
  }
}

/**
 * Implements the AI SDK's LanguageModelV4 interface against the scripted response queue.
 * Both entry points pull the next scripted AssistantMessage and re-encode it into the SDK's
 * wire shape: doGenerate returns it whole; doStream replays it as a sequence of stream parts.
 * The prompt the SDK built is forwarded to the script as `context`, and the abort signal is
 * passed through so a script can assert on cancellation.
 */
function createFauxSdkModel(
  provider: string,
  modelId: string,
  nextResponse: (context: unknown, options: { signal?: AbortSignal }) => Promise<AssistantMessage>
): LanguageModelV4 {
  return {
    specificationVersion: 'v4',
    provider,
    modelId,
    supportedUrls: {},
    async doGenerate(options) {
      const response = await nextResponse(options.prompt, { signal: options.abortSignal })
      return {
        content: responseContent(response),
        finishReason: finishReason(response),
        usage: v4Usage(response.usage),
        response: {
          id: response.responseId,
          // Prefer the scripted served-model id, else fall back to the requested model id.
          modelId: response.responseModel ?? response.model,
          timestamp: new Date(response.timestamp)
        },
        warnings: []
      }
    },
    async doStream(options) {
      // Resolve the whole response up front, THEN emit it as a stream — there is no real
      // incremental generation, so streaming is a deterministic replay of a known message.
      const response = await nextResponse(options.prompt, { signal: options.abortSignal })
      return {
        stream: new ReadableStream<LanguageModelV4StreamPart>({
          start(controller) {
            // Frame the stream exactly as a real provider would: start, metadata, the body
            // parts, then a single finish carrying final usage + finish reason.
            controller.enqueue({ type: 'stream-start', warnings: [] })
            controller.enqueue({
              type: 'response-metadata',
              id: response.responseId,
              modelId: response.responseModel ?? response.model,
              timestamp: new Date(response.timestamp)
            })
            for (const part of streamParts(response)) controller.enqueue(part)
            controller.enqueue({
              type: 'finish',
              usage: v4Usage(response.usage),
              finishReason: finishReason(response)
            })
            controller.close()
          }
        })
      }
    }
  }
}

/** Maps BullX content blocks to AI SDK content parts for the non-streaming path (thinking -> reasoning, toolCall -> tool-call with JSON-stringified args). */
function responseContent(response: AssistantMessage): LanguageModelV4Content[] {
  return response.content.map(part => {
    if (part.type === 'text') return { type: 'text', text: part.text }
    if (part.type === 'thinking') return { type: 'reasoning', text: part.thinking }
    return {
      type: 'tool-call',
      toolCallId: part.id,
      toolName: part.name,
      input: JSON.stringify(part.arguments)
    }
  })
}

/**
 * Expands a finished AssistantMessage into the start/delta/end stream parts a real provider
 * would emit. Each block becomes the whole delta in ONE chunk (no token-by-token splitting) —
 * enough to exercise the SDK's streaming state machine deterministically. Tool calls emit the
 * input-streaming parts AND a final consolidated `tool-call`. Non-tool blocks get a synthetic
 * `part_<n>` id since only tool calls carry their own id; an 'error' stop appends an error part.
 */
function streamParts(response: AssistantMessage): LanguageModelV4StreamPart[] {
  const parts: LanguageModelV4StreamPart[] = []
  let index = 0
  for (const part of response.content) {
    const id = part.type === 'toolCall' ? part.id : `part_${index++}`
    if (part.type === 'text') {
      parts.push({ type: 'text-start', id }, { type: 'text-delta', id, delta: part.text }, { type: 'text-end', id })
    } else if (part.type === 'thinking') {
      parts.push(
        { type: 'reasoning-start', id },
        { type: 'reasoning-delta', id, delta: part.thinking },
        { type: 'reasoning-end', id }
      )
    } else {
      const input = JSON.stringify(part.arguments)
      parts.push(
        { type: 'tool-input-start', id: part.id, toolName: part.name },
        { type: 'tool-input-delta', id: part.id, delta: input },
        { type: 'tool-input-end', id: part.id },
        { type: 'tool-call', toolCallId: part.id, toolName: part.name, input }
      )
    }
  }
  if (response.stopReason === 'error') parts.push({ type: 'error', error: response.errorMessage ?? 'faux error' })
  return parts
}

/** Inverse of toBullXStopReason: turns a BullX stop reason back into the SDK's finish-reason shape for the fake. */
function finishReason(response: AssistantMessage): LanguageModelV4FinishReason {
  if (response.stopReason === 'length') return { unified: 'length', raw: 'length' }
  if (response.stopReason === 'toolUse') return { unified: 'tool-calls', raw: 'tool-calls' }
  if (response.stopReason === 'error') return { unified: 'error', raw: 'error' }
  return { unified: 'stop', raw: response.stopReason }
}

/**
 * Re-expands BullX's flat Usage into the SDK's nested usage shape. BullX's `input` is the full
 * input count, so the SDK's `noCache` is derived by subtracting the cache buckets back out
 * (floored at 0). This is the mirror image of toBullXUsage, which flattens the SDK shape down.
 */
function v4Usage(usage: Usage): LanguageModelV4Usage {
  return {
    inputTokens: {
      total: usage.input,
      noCache: Math.max(0, usage.input - usage.cacheRead - usage.cacheWrite),
      cacheRead: usage.cacheRead,
      cacheWrite: usage.cacheWrite
    },
    outputTokens: {
      total: usage.output,
      text: usage.output,
      reasoning: undefined
    }
  }
}

/** Fresh zeroed Usage for faux messages (local copy of ZERO_USAGE so the shared constant is never aliased). */
function zeroUsage(): Usage {
  return {
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
    totalTokens: 0,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }
  }
}
