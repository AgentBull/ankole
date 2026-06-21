// Exercises the agent loop end-to-end against a fake streaming model (scriptedModel) instead of a real
// provider. Each test scripts a sequence of assistant responses and asserts on the loop's behavior:
// wire sanitization of orphan tool pairs / empty assistants, the maxTurns grace turn, the
// empty-after-tools nudge, and transient-error retry. The fake re-emits a finished AssistantMessage as
// SDK v4 stream parts (see streamParts), so the tests run the real streaming code path.

import { describe, expect, it } from 'bun:test'
import { z } from 'zod'
import type { AssistantMessage, Message, Model } from '@/llm'
import { runAgentLoop } from './agent-loop'
import { convertToLlm } from './harness/messages'
import { buildTool } from '../tools/build-tool'
import type { AgentContext, AgentEvent, AgentLoopConfig, AgentMessage } from './types'

const USAGE = {
  input: 0,
  output: 0,
  cacheRead: 0,
  cacheWrite: 0,
  totalTokens: 0,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }
}

const MODEL_BASE = {
  id: 'm',
  name: 'm',
  api: 'unknown',
  provider: 'unknown',
  baseUrl: '',
  reasoning: false,
  input: [],
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  contextWindow: 0,
  maxTokens: 0
} as unknown as Model<any>

const text = (t: string) => ({ type: 'text' as const, text: t })
const toolCall = (id: string, name: string, args: Record<string, unknown> = {}) => ({
  type: 'toolCall' as const,
  id,
  name,
  arguments: args
})

function assistant(
  content: AssistantMessage['content'],
  stopReason: AssistantMessage['stopReason'] = 'stop',
  extra: Partial<AssistantMessage> = {}
): AssistantMessage {
  return {
    role: 'assistant',
    content,
    api: 'unknown' as AssistantMessage['api'],
    provider: 'unknown' as AssistantMessage['provider'],
    model: 'm',
    usage: USAGE,
    stopReason,
    timestamp: 0,
    ...extra
  }
}

function userMessage(t: string): AgentMessage {
  return { role: 'user', content: [text(t)], timestamp: 0 }
}

const echoTool = buildTool({
  name: 'echo',
  description: 'echo',
  label: 'echo',
  schema: z.object({}),
  isReadOnly: true,
  isDestructive: false,
  execute: async () => ({ content: [text('echoed')], details: {} })
})

interface StreamCapture {
  contexts: { messages: Message[]; tools: unknown }[]
  requests: unknown[]
  calls: number
}

type ScriptedResponse = AssistantMessage | ((request: unknown) => AssistantMessage | Promise<AssistantMessage>)

/** A fake AI SDK model that returns scripted assistant messages (last one repeats). */
function scriptedModel(responses: ScriptedResponse[]): { model: Model<any>; capture: StreamCapture } {
  const capture: StreamCapture = { contexts: [], requests: [], calls: 0 }
  const sdkModel = {
    specificationVersion: 'v4',
    provider: 'test',
    modelId: 'm',
    supportedUrls: {},
    async doGenerate() {
      throw new Error('doGenerate is not used by agent-loop tests')
    },
    async doStream(request: unknown) {
      capture.requests.push(request)
      const step = responses[Math.min(capture.calls, responses.length - 1)]
      capture.calls += 1
      const message = typeof step === 'function' ? await step(request) : step
      return {
        stream: new ReadableStream({
          start(controller) {
            controller.enqueue({ type: 'stream-start', warnings: [] })
            controller.enqueue({
              type: 'response-metadata',
              id: message.responseId,
              modelId: message.responseModel ?? message.model,
              timestamp: new Date(message.timestamp)
            })
            for (const part of streamParts(message)) controller.enqueue(part)
            controller.enqueue({ type: 'finish', usage: v4Usage(message.usage), finishReason: finishReason(message) })
            controller.close()
          }
        })
      }
    }
  }
  return { model: { ...MODEL_BASE, sdkModel: sdkModel as never }, capture }
}

function streamParts(message: AssistantMessage) {
  const parts: unknown[] = []
  let index = 0
  for (const block of message.content) {
    const id = block.type === 'toolCall' ? block.id : `part_${index++}`
    if (block.type === 'text') {
      parts.push({ type: 'text-start', id }, { type: 'text-delta', id, delta: block.text }, { type: 'text-end', id })
    } else if (block.type === 'thinking') {
      parts.push(
        { type: 'reasoning-start', id },
        { type: 'reasoning-delta', id, delta: block.thinking },
        { type: 'reasoning-end', id }
      )
    } else {
      const input = JSON.stringify(block.arguments)
      parts.push(
        { type: 'tool-input-start', id: block.id, toolName: block.name },
        { type: 'tool-input-delta', id: block.id, delta: input },
        { type: 'tool-input-end', id: block.id },
        { type: 'tool-call', toolCallId: block.id, toolName: block.name, input }
      )
    }
  }
  if (message.stopReason === 'error') parts.push({ type: 'error', error: message.errorMessage ?? 'provider error' })
  return parts
}

function finishReason(message: AssistantMessage) {
  if (message.stopReason === 'length') return { unified: 'length', raw: 'length' }
  if (message.stopReason === 'toolUse') return { unified: 'tool-calls', raw: 'tool-calls' }
  if (message.stopReason === 'error') return { unified: 'error', raw: 'error' }
  return { unified: 'stop', raw: message.stopReason }
}

function v4Usage(usage: AssistantMessage['usage']) {
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

// Builds a loop config that taps `beforeLlmCall` to snapshot the exact wire messages/tools each turn
// (the only hook with the post-conversion, post-sanitization shape), then chains any override hook. The
// captured contexts back the "what did the provider actually see" assertions.
function makeConfig(
  model: Model<any>,
  capture: StreamCapture,
  overrides: Partial<AgentLoopConfig> = {}
): AgentLoopConfig {
  const beforeLlmCall = overrides.beforeLlmCall
  return {
    model,
    convertToLlm,
    ...overrides,
    beforeLlmCall: async (context, signal) => {
      capture.contexts.push({ messages: context.llmMessages, tools: context.llmContext.tools })
      return beforeLlmCall?.(context, signal)
    }
  }
}

async function run(
  prompt: AgentMessage[],
  context: AgentContext,
  config: AgentLoopConfig,
  emit: (event: AgentEvent) => Promise<void> | void = async () => {}
): Promise<AgentMessage[]> {
  return runAgentLoop(prompt, context, config, emit)
}

function assistantTexts(messages: AgentMessage[]): string[] {
  return messages
    .filter((m): m is AssistantMessage => m.role === 'assistant')
    .map(m =>
      m.content
        .filter(c => c.type === 'text')
        .map(c => (c as { text: string }).text)
        .join('')
    )
}

describe('agent-loop wire sanitization (orphan tool pairs + empty assistant)', () => {
  it('passes reasoning and cache policy through the AI SDK request shape', async () => {
    const { model, capture } = scriptedModel([assistant([text('ok')])])
    Object.assign(model, { provider: 'openai', id: 'gpt-5', reasoning: true })
    const context: AgentContext = { systemPrompt: 'sys', messages: [], tools: [] }

    await run(
      [userMessage('go')],
      context,
      makeConfig(model, capture, {
        reasoning: 'high',
        cacheRetention: 'long',
        metadata: { conversation_id: 'conv_1' }
      })
    )

    const request = capture.requests[0] as {
      reasoning?: unknown
      providerOptions?: Record<string, unknown>
    }
    expect(request.reasoning).toBe('high')
    expect(request.providerOptions).toEqual({
      openai: {
        promptCacheKey: 'bullx:openai:gpt-5:conv_1',
        promptCacheRetention: '24h'
      }
    })
    expect(request.providerOptions).not.toHaveProperty('bullx')
  })

  it('retries retryable provider stream creation errors before surfacing failure', async () => {
    const context: AgentContext = { systemPrompt: 'sys', messages: [], tools: [] }
    const { model, capture } = scriptedModel([
      () => {
        const error = new Error('rate limit')
        ;(error as Error & { status?: number }).status = 429
        throw error
      },
      assistant([text('recovered')])
    ])

    const result = await run([userMessage('go')], context, makeConfig(model, capture, { maxRetryDelayMs: 1 }))

    expect(capture.calls).toBe(2)
    expect(assistantTexts(result)).toEqual(['recovered'])
  })

  it('retries one empty pre-tool assistant error returned by the provider stream', async () => {
    const context: AgentContext = { systemPrompt: 'sys', messages: [], tools: [echoTool] }
    const { model, capture } = scriptedModel([
      assistant([], 'error', { errorMessage: 'Connection error.' }),
      assistant([text('recovered')])
    ])
    const events: AgentEvent[] = []

    const result = await run(
      [userMessage('go')],
      context,
      makeConfig(model, capture, { maxRetryDelayMs: 1 }),
      event => {
        events.push(event)
      }
    )

    expect(capture.calls).toBe(2)
    expect(assistantTexts(result)).toEqual(['recovered'])
    expect(result.filter(message => message.role === 'assistant')).toHaveLength(1)
    expect(events.filter(event => event.type === 'turn_end')).toHaveLength(1)
  })

  it('does not retry assistant errors after tool results have been produced', async () => {
    const context: AgentContext = { systemPrompt: 'sys', messages: [], tools: [echoTool] }
    const { model, capture } = scriptedModel([
      assistant([toolCall('e1', 'echo')]),
      assistant([], 'error', { errorMessage: 'Connection error.' }),
      assistant([text('should not run')])
    ])

    const result = await run([userMessage('go')], context, makeConfig(model, capture, { maxRetryDelayMs: 1 }))

    expect(capture.calls).toBe(2)
    expect(result.filter(message => message.role === 'assistant')).toHaveLength(2)
    expect(assistantTexts(result).at(-1)).toBe('')
  })

  it('drops orphan tool results, stubs missing results, and backfills empty assistant content', async () => {
    const callWithMissingResult = assistant([toolCall('call_a1', 'echo')])
    const orphanResult: Message = {
      role: 'toolResult',
      toolCallId: 'call_orphan',
      toolName: 'echo',
      content: [text('orphan')],
      isError: false,
      timestamp: 0
    }
    const emptyAssistant = assistant([text('   ')])
    const context: AgentContext = {
      systemPrompt: 'sys',
      messages: [userMessage('hi'), callWithMissingResult, orphanResult, emptyAssistant],
      tools: []
    }
    const { model, capture } = scriptedModel([assistant([text('done')])])

    await run([userMessage('go')], context, makeConfig(model, capture))

    const wire = capture.contexts[0]!.messages
    // Orphan result whose tool call no longer exists is dropped.
    expect(wire.some(m => m.role === 'toolResult' && m.toolCallId === 'call_orphan')).toBe(false)
    // The tool call missing its result gets a stub result, right after its assistant turn.
    const stubIndex = wire.findIndex(m => m.role === 'toolResult' && m.toolCallId === 'call_a1')
    expect(stubIndex).toBeGreaterThan(-1)
    const assistantIndex = wire.findIndex(m => m.role === 'assistant' && m.content.some(c => c.type === 'toolCall'))
    expect(stubIndex).toBe(assistantIndex + 1)
    // The empty assistant gains a non-empty text block so the provider accepts it.
    const placeholder = wire.find(
      m => m === emptyAssistant || (m.role === 'assistant' && m.content.length > emptyAssistant.content.length)
    ) as AssistantMessage | undefined
    expect(placeholder?.content.some(c => c.type === 'text' && c.text.trim().length > 0)).toBe(true)
    // Pure: source message object is untouched (placeholder is added on a clone).
    expect(emptyAssistant.content).toHaveLength(1)
  })
})

describe('agent-loop iteration budget (maxTurns + grace)', () => {
  it('runs one tool-free grace turn after the turn cap, then stops with a usable answer', async () => {
    // Every capped turn requests another tool call → runaway loop. With maxTurns=3
    // the first three calls run (c1,c2,c3) and the fourth call is the grace turn.
    const { model, capture } = scriptedModel([
      assistant([toolCall('c1', 'echo')]),
      assistant([toolCall('c2', 'echo')]),
      assistant([toolCall('c3', 'echo')]),
      assistant([text('grace summary')])
    ])
    const context: AgentContext = { systemPrompt: 'sys', messages: [], tools: [echoTool] }
    const events: AgentEvent[] = []
    const result = await run([userMessage('go')], context, makeConfig(model, capture, { maxTurns: 3 }), event => {
      events.push(event)
    })

    // 3 capped turns + 1 grace turn = 4 provider calls; the loop does not run forever.
    expect(capture.calls).toBe(4)
    // The grace turn is sent with no tools so the model must answer instead of calling more.
    expect(capture.contexts[3]!.tools).toBeUndefined()
    // The final message is the grace summary, not a truncated tool call.
    expect(assistantTexts(result).at(-1)).toBe('grace summary')
    expect(
      events.some(event => event.type === 'max_turns_reached' && event.maxTurns === 3 && event.turnCount === 3)
    ).toBe(true)
  })

  it('does not cap when maxTurns is unset (historical behavior)', async () => {
    const { model, capture } = scriptedModel([assistant([text('answer')])])
    const context: AgentContext = { systemPrompt: 'sys', messages: [], tools: [echoTool] }
    await run([userMessage('go')], context, makeConfig(model, capture))
    expect(capture.calls).toBe(1)
  })
})

describe('agent-loop empty-after-tools nudge', () => {
  it('nudges the model to continue once when it returns empty right after tool results', async () => {
    const { model, capture } = scriptedModel([
      assistant([toolCall('e1', 'echo')]),
      assistant([text('')]),
      assistant([text('final answer')])
    ])
    const context: AgentContext = { systemPrompt: 'sys', messages: [], tools: [echoTool] }
    const result = await run([userMessage('go')], context, makeConfig(model, capture, { nudgeOnEmptyAfterTools: true }))

    // tool turn + empty turn + (nudge) continuation = 3 provider calls.
    expect(capture.calls).toBe(3)
    // A user nudge was injected after the empty assistant.
    const hasNudge = result.some(
      m =>
        m.role === 'user' &&
        Array.isArray(m.content) &&
        m.content.some(c => c.type === 'text' && /empty response/i.test(c.text))
    )
    expect(hasNudge).toBe(true)
    // The run continued to a real answer instead of ending on the empty turn.
    expect(assistantTexts(result).at(-1)).toBe('final answer')
  })

  it('ends on the empty turn when the nudge is disabled', async () => {
    const { model, capture } = scriptedModel([
      assistant([toolCall('e1', 'echo')]),
      assistant([text('')]),
      assistant([text('should-not-be-requested')])
    ])
    const context: AgentContext = { systemPrompt: 'sys', messages: [], tools: [echoTool] }
    const result = await run([userMessage('go')], context, makeConfig(model, capture))

    // Only the tool turn and the empty turn run; the third response is never requested.
    expect(capture.calls).toBe(2)
    expect(assistantTexts(result).at(-1)).toBe('')
  })
})
