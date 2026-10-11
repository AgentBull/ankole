import { create } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import { AIGatewayAPIKeyResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { TurnStart } from '../src/lanes/actor_lane'
import { resolveCodexRuntimeConfig } from '../src/core/codex-runner/runtime-config'

function turnStart(modelRef: TurnStart['model_ref']): TurnStart {
  return {
    mode: 'start',
    fetch_runtime_config: { ssrfFilter: true },
    turn: {
      actor: { session_id: 'job:1000' },
      job_id: 1000,
      attempt: 1,
      actor_event_id: '00000000-0000-0000-0000-000000000001'
    },
    actor_event: {
      actor_event_id: '00000000-0000-0000-0000-000000000001',
      type: 'background_agent_job.turn',
      payload_json: {}
    },
    model_ref: modelRef
  }
}

describe('@ankole/agent-computer Codex runtime config', () => {
  it('uses the coding model resolved for the current Job turn', async () => {
    const runtime = await resolveCodexRuntimeConfig({
      turnStart: turnStart({
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
          provider_id: 'openrouter-vision',
          provider_kind: 'openrouter',
          model: 'google/gemini-3-flash-preview',
          provider_options: { serviceTier: 'priority' },
          input_modalities: ['text', 'image']
        }
      }),
      requestAIGatewayAPIKey: async () =>
        create(AIGatewayAPIKeyResponseSchema, {
          apiKey: 'agent-key',
          baseUrl: 'https://control.example.test/api/v1/ai-gateway'
        })
    })

    expect(runtime).toEqual({
      aiGatewayKey: expect.objectContaining({
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
      }
    })
  })

  it('keeps a no-reasoning Job binding visible to Codex', async () => {
    const runtime = await resolveCodexRuntimeConfig({
      turnStart: turnStart({
        provider_id: 'openai',
        provider_kind: 'openai',
        model: 'gpt-5.4',
        provider_options: { reasoningEffort: 'none' },
        supports_parallel_tool_calls: true,
        input_modalities: ['text', 'image']
      }),
      requestAIGatewayAPIKey: async () => create(AIGatewayAPIKeyResponseSchema, {})
    })

    expect(runtime.modelProfile.modelReasoningEffort).toBe('none')
    expect(runtime.modelProfile.inputModalities).toEqual(['text', 'image'])
  })

  it('accepts a resolved custom profile for one Job thread', async () => {
    const runtime = await resolveCodexRuntimeConfig({
      turnStart: turnStart({
        provider_id: 'openrouter',
        provider_kind: 'openrouter',
        model: 'moonshotai/kimi-k2.7-code',
        provider_options: { reasoningEffort: 'high' },
        supports_parallel_tool_calls: true,
        input_modalities: ['text']
      }),
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
        provider_id: 'openrouter',
        model: 'text-only',
        input_modalities: ['text'],
        vision_fallback_model_ref: {
          provider_id: 'openrouter',
          model: 'also-text-only',
          input_modalities: ['text']
        }
      }),
      requestAIGatewayAPIKey: async () => create(AIGatewayAPIKeyResponseSchema, {})
    })

    expect(runtime.modelProfile.visionFallback).toBeUndefined()
  })
})
