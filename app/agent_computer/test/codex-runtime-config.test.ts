import { create } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import { jsonBytes } from '../src/fabric/envelope_proto'
import {
  AIGatewayAPIKeyResponseSchema,
  BackgroundAgentJobResponseSchema
} from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { RPCRequester } from '../src/lanes/rpc_lane'
import { resolveCodexRuntimeConfig } from '../src/tools/codex/runtime-config'

const turn = {
  actor: { agent_uid: 'agent-1', session_id: 'job:1000' },
  activation_uid: 'activation-1',
  actor_epoch: 1,
  actor_event_id: '00000000-0000-0000-0000-000000000001',
  revision: 0
}

describe('@ankole/agent-computer Codex runtime config', () => {
  it('requires and preserves the AIGateway model snapshot stored at Job creation', async () => {
    const job = create(BackgroundAgentJobResponseSchema, {
      agentUid: 'agent-1',
      codexAccountId: 'aigateway',
      metadataJson: jsonBytes({
        codex_aigateway: {
          model: 'gpt-5.6-sol',
          selector: 'openrouter/openai/gpt-5.6-sol',
          provider_options: {
            reasoningEffort: 'xhigh',
            nested: { preserved: true },
            values: ['one', 2, false]
          },
          supports_parallel_tool_calls: true
        }
      })
    })

    const runtime = await resolveCodexRuntimeConfig({
      turn,
      job,
      requesters: {
        requestAIGatewayAPIKey: async () =>
          create(AIGatewayAPIKeyResponseSchema, {
            agentUid: 'agent-1',
            apiKey: 'agent-key',
            baseUrl: 'https://control.example.test/api/v1/ai-gateway'
          }),
        rpc: (async () => {
          throw new Error('official subscription RPC must not run')
        }) as RPCRequester
      }
    })

    expect(runtime).toMatchObject({
      mode: 'aigateway',
      accountID: 'aigateway',
      modelProfile: {
        model: 'gpt-5.6-sol',
        selector: 'openrouter/openai/gpt-5.6-sol',
        modelReasoningEffort: 'xhigh',
        supportsParallelToolCalls: true,
        providerOptions: {
          reasoningEffort: 'xhigh',
          nested: { preserved: true },
          values: ['one', 2, false]
        }
      }
    })
  })

  it('rejects an old unresolved AIGateway Job instead of restoring coding', async () => {
    const job = create(BackgroundAgentJobResponseSchema, {
      agentUid: 'agent-1',
      codexAccountId: 'aigateway'
    })

    expect(
      resolveCodexRuntimeConfig({
        turn,
        job,
        requesters: {
          requestAIGatewayAPIKey: async () => create(AIGatewayAPIKeyResponseSchema, {}),
          rpc: (async () => {
            throw new Error('official subscription RPC must not run')
          }) as RPCRequester
        }
      })
    ).rejects.toThrow('background_agent_job.metadata.codex_aigateway must be a JSON object')
  })
})
