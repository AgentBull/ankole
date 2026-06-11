import { describe, expect, it } from 'bun:test'
import { z } from 'zod'
import type { AssistantMessage, Message, Model } from '@earendil-works/pi-ai'
import { runAgentLoop } from './agent-loop'
import { convertToLlm } from './harness/messages'
import { buildTool } from '../tools/build-tool'
import type { AgentContext, AgentEvent, AgentLoopConfig, AgentMessage, StreamFn } from './types'

const USAGE = {
  input: 0,
  output: 0,
  cacheRead: 0,
  cacheWrite: 0,
  totalTokens: 0,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }
}

const MODEL = {
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
  calls: number
}

/** A streamFn that returns scripted assistant messages (last one repeats) and records each wire context. */
function scriptedStreamFn(responses: AssistantMessage[]): { streamFn: StreamFn; capture: StreamCapture } {
  const capture: StreamCapture = { contexts: [], calls: 0 }
  const streamFn = ((_model: unknown, context: { messages: Message[]; tools: unknown }) => {
    capture.contexts.push({ messages: context.messages, tools: context.tools })
    const message = responses[Math.min(capture.calls, responses.length - 1)]
    capture.calls += 1
    return {
      async *[Symbol.asyncIterator]() {
        yield { type: 'start', partial: message }
        yield { type: 'done', partial: message }
      },
      result: async () => message
    }
  }) as unknown as StreamFn
  return { streamFn, capture }
}

function makeConfig(overrides: Partial<AgentLoopConfig> = {}): AgentLoopConfig {
  return { model: MODEL, convertToLlm, ...overrides }
}

async function run(
  prompt: AgentMessage[],
  context: AgentContext,
  config: AgentLoopConfig,
  streamFn: StreamFn,
  emit: (event: AgentEvent) => Promise<void> | void = async () => {}
): Promise<AgentMessage[]> {
  return runAgentLoop(prompt, context, config, emit, undefined, streamFn)
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
  it('retries retryable provider stream creation errors before surfacing failure', async () => {
    const context: AgentContext = { systemPrompt: 'sys', messages: [], tools: [] }
    let calls = 0
    const success = scriptedStreamFn([assistant([text('recovered')])]).streamFn
    const streamFn = (async (...args: Parameters<StreamFn>) => {
      calls += 1
      if (calls === 1) {
        const error = new Error('rate limit')
        ;(error as Error & { status?: number }).status = 429
        throw error
      }
      return success(...args)
    }) as unknown as StreamFn

    const result = await run([userMessage('go')], context, makeConfig({ maxRetryDelayMs: 1 }), streamFn)

    expect(calls).toBe(2)
    expect(assistantTexts(result)).toEqual(['recovered'])
  })

  it('retries one empty pre-tool assistant error returned by the provider stream', async () => {
    const context: AgentContext = { systemPrompt: 'sys', messages: [], tools: [echoTool] }
    const { streamFn, capture } = scriptedStreamFn([
      assistant([], 'error', { errorMessage: 'Connection error.' }),
      assistant([text('recovered')])
    ])
    const events: AgentEvent[] = []

    const result = await run([userMessage('go')], context, makeConfig({ maxRetryDelayMs: 1 }), streamFn, event => {
      events.push(event)
    })

    expect(capture.calls).toBe(2)
    expect(assistantTexts(result)).toEqual(['recovered'])
    expect(result.filter(message => message.role === 'assistant')).toHaveLength(1)
    expect(events.filter(event => event.type === 'turn_end')).toHaveLength(1)
  })

  it('does not retry assistant errors after tool results have been produced', async () => {
    const context: AgentContext = { systemPrompt: 'sys', messages: [], tools: [echoTool] }
    const { streamFn, capture } = scriptedStreamFn([
      assistant([toolCall('e1', 'echo')]),
      assistant([], 'error', { errorMessage: 'Connection error.' }),
      assistant([text('should not run')])
    ])

    const result = await run([userMessage('go')], context, makeConfig({ maxRetryDelayMs: 1 }), streamFn)

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
    const { streamFn, capture } = scriptedStreamFn([assistant([text('done')])])

    await run([userMessage('go')], context, makeConfig(), streamFn)

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
    const { streamFn, capture } = scriptedStreamFn([
      assistant([toolCall('c1', 'echo')]),
      assistant([toolCall('c2', 'echo')]),
      assistant([toolCall('c3', 'echo')]),
      assistant([text('grace summary')])
    ])
    const context: AgentContext = { systemPrompt: 'sys', messages: [], tools: [echoTool] }
    const events: AgentEvent[] = []
    const result = await run([userMessage('go')], context, makeConfig({ maxTurns: 3 }), streamFn, event => {
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
    const { streamFn, capture } = scriptedStreamFn([assistant([text('answer')])])
    const context: AgentContext = { systemPrompt: 'sys', messages: [], tools: [echoTool] }
    await run([userMessage('go')], context, makeConfig(), streamFn)
    expect(capture.calls).toBe(1)
  })
})

describe('agent-loop empty-after-tools nudge', () => {
  it('nudges the model to continue once when it returns empty right after tool results', async () => {
    const { streamFn, capture } = scriptedStreamFn([
      assistant([toolCall('e1', 'echo')]),
      assistant([text('')]),
      assistant([text('final answer')])
    ])
    const context: AgentContext = { systemPrompt: 'sys', messages: [], tools: [echoTool] }
    const result = await run([userMessage('go')], context, makeConfig({ nudgeOnEmptyAfterTools: true }), streamFn)

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
    const { streamFn, capture } = scriptedStreamFn([
      assistant([toolCall('e1', 'echo')]),
      assistant([text('')]),
      assistant([text('should-not-be-requested')])
    ])
    const context: AgentContext = { systemPrompt: 'sys', messages: [], tools: [echoTool] }
    const result = await run([userMessage('go')], context, makeConfig(), streamFn)

    // Only the tool turn and the empty turn run; the third response is never requested.
    expect(capture.calls).toBe(2)
    expect(assistantTexts(result).at(-1)).toBe('')
  })
})
