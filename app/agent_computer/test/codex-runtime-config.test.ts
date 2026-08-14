import { create } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import { AIGatewayAPIKeyResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { TurnStart } from '../src/lanes/actor_lane'
import { resolveCodexRuntimeConfig } from '../src/core/codex-runner/runtime-config'

function turnStart(modelRef: TurnStart['model_ref'], remoteCompactionV2 = false): TurnStart {
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
    model_ref: modelRef,
    request_context: { codex: { remote_compaction_v2: remoteCompactionV2 } }
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
        context_length: 120_000,
        input_modalities: ['text'],
        vision_fallback_model_ref: {
          profile: 'vision_fallback',
          provider_id: 'openrouter-vision',
          provider_kind: 'openrouter',
          model: 'google/gemini-3-flash-preview',
          provider_options: { serviceTier: 'priority' },
          input_modalities: ['text', 'image']
        }
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
        inputModalities: ['text'],
        visionFallback: {
          selector: 'openrouter-vision/google/gemini-3-flash-preview',
          providerOptions: { serviceTier: 'priority' },
          inputModalities: ['text', 'image']
        },
        modelReasoningEffort: 'xhigh',
        contextLength: 120_000
      },
      remoteCompactionV2: false
    })
  })

  it('uses the control plane frozen Codex compaction decision', async () => {
    const runtime = await resolveCodexRuntimeConfig({
      turnStart: turnStart(
        {
          profile: 'coding',
          provider_id: 'chatgpt-subscription',
          provider_kind: 'chatgpt_subscription',
          model: 'gpt-5.6-sol',
          input_modalities: ['text']
        },
        true
      ),
      agentUID: 'agent-1',
      requestAIGatewayAPIKey: async () => create(AIGatewayAPIKeyResponseSchema, {})
    })

    expect(runtime.remoteCompactionV2).toBe(true)
  })

  it('keeps a no-reasoning Job binding visible to Codex', async () => {
    const runtime = await resolveCodexRuntimeConfig({
      turnStart: turnStart({
        profile: 'coding',
        provider_id: 'openai',
        provider_kind: 'openai',
        model: 'gpt-5.4',
        provider_options: { reasoningEffort: 'none' },
        supports_parallel_tool_calls: true,
        input_modalities: ['text', 'image']
      }),
      agentUID: 'agent-1',
      requestAIGatewayAPIKey: async () => create(AIGatewayAPIKeyResponseSchema, {})
    })

    expect(runtime.modelProfile.modelReasoningEffort).toBe('none')
    expect(runtime.modelProfile.inputModalities).toEqual(['text', 'image'])
  })

  it('accepts a resolved custom profile for one Job thread', async () => {
    const runtime = await resolveCodexRuntimeConfig({
      turnStart: turnStart({
        profile: 'kimi',
        provider_id: 'openrouter',
        provider_kind: 'openrouter',
        model: 'moonshotai/kimi-k2.7-code',
        provider_options: { reasoningEffort: 'high' },
        supports_parallel_tool_calls: true,
        input_modalities: ['text']
      }),
      agentUID: 'agent-1',
      requestAIGatewayAPIKey: async () => create(AIGatewayAPIKeyResponseSchema, {})
    })

    expect(runtime.modelProfile).toMatchObject({
      model: 'kimi-k2.7-code',
      selector: 'openrouter/moonshotai/kimi-k2.7-code',
      modelReasoningEffort: 'high',
      inputModalities: ['text']
    })
  })

  it('omits a configured fallback that is not directly vision-capable', async () => {
    const runtime = await resolveCodexRuntimeConfig({
      turnStart: turnStart({
        profile: 'coding',
        provider_id: 'openrouter',
        model: 'text-only',
        input_modalities: ['text'],
        vision_fallback_model_ref: {
          profile: 'vision_fallback',
          provider_id: 'openrouter',
          model: 'also-text-only',
          input_modalities: ['text']
        }
      }),
      agentUID: 'agent-1',
      requestAIGatewayAPIKey: async () => create(AIGatewayAPIKeyResponseSchema, {})
    })

    expect(runtime.modelProfile.visionFallback).toBeUndefined()
  })
})
