import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import {
  decodeCodexJobRuntimeProjection,
  projectWorkerEnv,
  selectProjectedAgentPlugins,
  selectProjectedStandaloneSkills
} from '../src/core/codex-runner/runtime-projection'
import { jsonBytes } from '../src/fabric/envelope_proto'
import {
  AgentPluginCatalogEntrySchema,
  BackgroundAgentJobResponseSchema,
  RuntimeSkillSummarySchema
} from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'

describe('BackgroundAgentJob runtime projection', () => {
  it('decodes version 1 and intersects persisted capability choices with current material', () => {
    const projection = decodeCodexJobRuntimeProjection(
      job({
        version: 1,
        model_ref: { provider_id: 'openrouter-main', model: 'openai/gpt-5.6-sol' },
        runtime_policy: {},
        skills: [
          { id: 'pdf', name: 'pdf' },
          { id: 'alpha:member-a', name: 'member-a', agent_plugin_id: 'alpha' },
          { id: 'removed-skill', name: 'removed-skill' }
        ],
        agent_plugins: [
          { id: 'alpha', skills: ['member-a'] },
          { id: 'removed-plugin', skills: ['gone'] }
        ],
        native_mcp_servers: [],
        worker_env: { names: [], plain_values: {} },
        browser: { mode: 'persistent' }
      })
    )

    const pdf = skill('pdf')
    const newStandalone = skill('new-standalone')
    const memberA = skill('member-a', 'alpha')
    const newMember = skill('member-new', 'alpha')
    const currentPlugin = create(AgentPluginCatalogEntrySchema, {
      id: 'alpha',
      description: 'Alpha Plugin',
      skills: [{ catalogName: 'member-a' }, { catalogName: 'member-new' }]
    })

    expect(selectProjectedStandaloneSkills(projection, [pdf, newStandalone, memberA])).toEqual([pdf])
    const selectedPluginMaterial = selectProjectedAgentPlugins(projection, [currentPlugin], [memberA, newMember])
    expect(selectedPluginMaterial.skills).toEqual([memberA])
    expect(selectedPluginMaterial.agentPlugins).toEqual([{ ...currentPlugin, skills: [currentPlugin.skills[0]!] }])
  })

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
    jobId: '1000',
    agentUid: 'agent-1',
    runtimeProjectionJson: projection ? jsonBytes(projection as never) : new Uint8Array()
  })
}

function skill(skillName: string, agentPluginId = '') {
  return create(RuntimeSkillSummarySchema, {
    skillName,
    sourceKind: agentPluginId ? 'agent_plugin' : 'builtin',
    agentPluginId,
    relativePath: skillName
  })
}
