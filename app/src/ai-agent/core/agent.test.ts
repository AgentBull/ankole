// Covers the Agent run-failure path: when a lifecycle hook throws a wrapped Drizzle/Postgres error,
// `handleRunFailure` must flatten the whole cause chain — including the PG constraint/detail fields that
// never live on `.message` — into the surfaced assistant `errorMessage` so the failure is diagnosable.

import { describe, expect, it } from 'bun:test'
import type { Model } from '@/llm'
import { Agent } from './agent'

const TEST_MODEL = {
  id: 'test-model',
  name: 'Test model',
  api: 'test',
  provider: 'test',
  baseUrl: '',
  reasoning: false,
  input: ['text'],
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  contextWindow: 8_000,
  maxTokens: 1_000
} satisfies Model<any>

describe('Agent', () => {
  it('preserves nested failure causes when lifecycle listeners fail', async () => {
    const cause = Object.assign(new Error('duplicate key value violates unique constraint'), {
      code: '23505',
      constraint: 'ai_agent_llm_turns_lease_call_index',
      detail: 'Key (conversation_id, lease_id, call_index) already exists.'
    })
    const error = Object.assign(new Error('Failed query: insert into "ai_agent_llm_turns" ...'), { cause })
    // Throwing from beforeLlmCall is a convenient stand-in for any hook that breaks its no-throw
    // contract: it drives the loop into runWithLifecycle's catch, which synthesizes the assistant below.
    const agent = new Agent({
      initialState: {
        model: TEST_MODEL,
        messages: [{ role: 'user', content: [{ type: 'text', text: 'hi' }], timestamp: Date.now() }],
        thinkingLevel: 'off'
      },
      beforeLlmCall: async () => {
        throw error
      }
    })

    await agent.continue()

    // The last message is the failure assistant produced by handleRunFailure, not a model response.
    const assistant = agent.state.messages.at(-1)
    expect(assistant?.role).toBe('assistant')
    if (assistant?.role !== 'assistant') throw new Error('expected assistant message')
    expect(assistant?.stopReason).toBe('error')
    expect(assistant?.errorMessage).toContain('Failed query: insert into "ai_agent_llm_turns"')
    expect(assistant?.errorMessage).toContain('duplicate key value violates unique constraint')
    expect(assistant?.errorMessage).toContain('constraint: ai_agent_llm_turns_lease_call_index')
    expect(assistant?.errorMessage).toContain('detail: Key (conversation_id, lease_id, call_index) already exists.')
  })
})
