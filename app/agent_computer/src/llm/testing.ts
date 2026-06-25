import type {
  LanguageModelV4,
  LanguageModelV4Content,
  LanguageModelV4FinishReason,
  LanguageModelV4StreamPart,
  LanguageModelV4Usage
} from './provider'
import type { AssistantMessage, Model, ToolCall, Usage } from './bullx'

export type FauxResponseStep =
  | AssistantMessage
  | ((context: unknown, options: { signal?: AbortSignal }) => AssistantMessage | Promise<AssistantMessage>)

export interface FauxProviderRegistration {
  provider: string
  getModel(id: string): Model<any> | undefined
  setResponses(responses: FauxResponseStep[]): void
  unregister(): void
}

const registrations = new Set<FauxProviderRegistration>()

export function registerFauxProvider(input: {
  provider: string
  models: Array<{ id: string; contextWindow?: number; maxTokens?: number }>
}): FauxProviderRegistration {
  let responses: FauxResponseStep[] = []
  let calls = 0
  const models = new Map<string, Model<any>>()
  const nextResponse = async (context: unknown, options: { signal?: AbortSignal }) => {
    const step = responses[Math.min(calls, Math.max(0, responses.length - 1))]
    calls += 1
    if (!step) return fauxAssistantMessage('')
    return typeof step === 'function' ? await step(context, options) : step
  }

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

export function fauxToolCall(name: string, args: Record<string, unknown> = {}, id = `call_${name}`): ToolCall {
  return {
    type: 'toolCall',
    id,
    name,
    arguments: args
  }
}

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
          modelId: response.responseModel ?? response.model,
          timestamp: new Date(response.timestamp)
        },
        warnings: []
      }
    },
    async doStream(options) {
      const response = await nextResponse(options.prompt, { signal: options.abortSignal })
      return {
        stream: new ReadableStream<LanguageModelV4StreamPart>({
          start(controller) {
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

function finishReason(response: AssistantMessage): LanguageModelV4FinishReason {
  if (response.stopReason === 'length') return { unified: 'length', raw: 'length' }
  if (response.stopReason === 'toolUse') return { unified: 'tool-calls', raw: 'tool-calls' }
  if (response.stopReason === 'error') return { unified: 'error', raw: 'error' }
  return { unified: 'stop', raw: response.stopReason }
}

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
