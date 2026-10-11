import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { decodeCodexJobRuntimeProjection, projectWorkerEnv } from '../src/core/codex-runner/job/runtime-projection'
import { jsonBytes } from '../src/fabric/envelope_proto'
import { BackgroundAgentJobResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'

describe('BackgroundAgentJob runtime projection', () => {
  it('keeps projected plain values, resolves selected secrets again, and overlays current bindings', () => {
    const projection = decodeCodexJobRuntimeProjection(
      job({
        version: 1,
        model_ref: { provider_id: 'openrouter-main', model: 'openai/gpt-5.6-sol' },
        runtime_policy: {},
        skills: [],
        agent_plugins: [],
        native_mcp_servers: [],
        worker_env: {
          names: ['SNAPSHOT', 'SHARED', 'SECRET', 'REMOVED_SECRET'],
          plain_values: { SNAPSHOT: 'persisted', SHARED: 'persisted-shared' }
        },
        browser: { mode: 'persistent' }
      })
    )

    expect(
      projectWorkerEnv(projection, {
        vars: {},
        operatorVars: {
          SNAPSHOT: 'changed-after-dispatch',
          SHARED: 'changed-after-dispatch',
          SECRET: 'current-secret',
          NEW_OPERATOR_VAR: 'must-not-leak'
        },
        bindingVars: { SHARED: 'current-binding', CURRENT_BINDING: 'current-binding-value' }
      })
    ).toEqual({
      SNAPSHOT: 'persisted',
      SHARED: 'current-binding',
      SECRET: 'current-secret',
      CURRENT_BINDING: 'current-binding-value'
    })
  })

  it('fails closed when the projection is absent or unsupported', () => {
    expect(() => decodeCodexJobRuntimeProjection(job(undefined))).toThrow('missing its runtime projection')
    expect(() =>
      decodeCodexJobRuntimeProjection(
        job({
          version: 2,
          model_ref: {},
          runtime_policy: {},
          skills: [],
          agent_plugins: [],
          native_mcp_servers: [],
          worker_env: { names: [], plain_values: {} },
          browser: { mode: 'persistent' }
        })
      )
    ).toThrow('unsupported version or model reference')
  })
})

function job(projection: Record<string, unknown> | undefined) {
  return create(BackgroundAgentJobResponseSchema, {
    agentUid: 'agent-1',
    runtimeProjectionJson: projection ? jsonBytes(projection as never) : new Uint8Array()
  })
}
