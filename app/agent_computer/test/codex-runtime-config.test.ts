import { create } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import { AIGatewayAPIKeyResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { TurnStart } from '../src/lanes/actor_lane'
import { resolveCodexRuntimeConfig } from '../src/tools/codex/runtime-config'

function turnStart(modelRef: TurnStart['model_ref']): TurnStart {
  return {
    workspace_id: 10_000,
    turn: {
      actor: { agent_uid: 'agent-1', session_id: 'job:1000' },
      activation_uid: 'activation-1',
      actor_epoch: 1,
      actor_event_id: '00000000-0000-0000-0000-000000000001',
      revision: 0
    },
    actor_event: {
      actor_event_id: '00000000-0000-0000-0000-000000000001',
      queue_sequence: 1,
      type: 'background_agent_job.turn',
      source_event_id: 'background-agent-job-1000',
      payload_json: {}
    },
    model_ref: modelRef
  }
}

describe('@ankole/agent-computer Codex runtime config', () => {
  it('uses the coding model resolved for the current Job turn', async () => {
    const runtime = await resolveCodexRuntimeConfig({
      turnStart: turnStart({
        profile: 'coding',
        provider_id: 'openrouter',
        provider_kind: 'openrouter',
        model: 'openai/gpt-5.6-sol',
        provider_options: {
          reasoningEffort: 'xhigh',
          serviceTier: 'priority',
          nested: { preserved: true }
        },
        supports_parallel_tool_calls: true,
        context_length: 120_000
      }),
      agentUID: 'agent-1',
      requestAIGatewayAPIKey: async () =>
        create(AIGatewayAPIKeyResponseSchema, {
          agentUid: 'agent-1',
          apiKey: 'agent-key',
          baseUrl: 'https://control.example.test/api/v1/ai-gateway'
        })
    })

    expect(runtime).toEqual({
      aiGatewayKey: expect.objectContaining({
        agentUid: 'agent-1',
        apiKey: 'agent-key'
      }),
      modelProfile: {
        model: 'gpt-5.6-sol',
        selector: 'openrouter/openai/gpt-5.6-sol',
        providerOptions: {
          reasoningEffort: 'xhigh',
          serviceTier: 'priority',
          nested: { preserved: true }
        },
        supportsParallelToolCalls: true,
        modelReasoningEffort: 'xhigh',
        contextLength: 120_000
      }
    })
  })

  it('keeps a no-reasoning Job binding visible to Codex', async () => {
    const runtime = await resolveCodexRuntimeConfig({
      turnStart: turnStart({
        profile: 'coding',
        provider_id: 'openai',
        provider_kind: 'openai',
        model: 'gpt-5.4',
        provider_options: { reasoningEffort: 'none' },
        supports_parallel_tool_calls: true
      }),
      agentUID: 'agent-1',
      requestAIGatewayAPIKey: async () => create(AIGatewayAPIKeyResponseSchema, {})
    })

    expect(runtime.modelProfile.modelReasoningEffort).toBe('none')
  })

  it('accepts a resolved custom profile for one Job thread', async () => {
    const runtime = await resolveCodexRuntimeConfig({
      turnStart: turnStart({
        profile: 'kimi',
        provider_id: 'openrouter',
        provider_kind: 'openrouter',
        model: 'moonshotai/kimi-k2.7-code',
        provider_options: { reasoningEffort: 'high' },
        supports_parallel_tool_calls: true
      }),
      agentUID: 'agent-1',
      requestAIGatewayAPIKey: async () => create(AIGatewayAPIKeyResponseSchema, {})
    })

    expect(runtime.modelProfile).toMatchObject({
      model: 'kimi-k2.7-code',
      selector: 'openrouter/moonshotai/kimi-k2.7-code',
      modelReasoningEffort: 'high'
    })
  })
})
