import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import {
  createBackgroundAgentJobTool,
  type BackgroundAgentJobToolOptions
} from '../src/tools/background-agent-job/background-agent-job-tool'
import { jsonBytes } from '../src/fabric/envelope_proto'
import {
  AgentPluginCatalogEntrySchema,
  BackgroundAgentJobListResponseSchema,
  BackgroundAgentJobResponseSchema
} from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import {
  rpcMethods,
  type BackgroundAgentJobResponse,
  type AgentPluginCatalogEntry,
  type RPCRequester
} from '../src/lanes/rpc_lane'
import { zodToJSONSchema } from '../src/core/llm/tool-schema'
import { turnStartForTest } from './support/llm'

describe('@ankole/agent-computer background agent job tool', () => {
  it('builds Plugin and standalone Skill selection from the live catalog', () => {
    const tool = createBackgroundAgentJobTool(toolOptions())
    const jsonSchema = zodToJSONSchema(tool.schema) as Record<string, any>

    expect(jsonSchema.properties.agent_plugin_ids.items.enum).toEqual(['deep-research'])
    expect(jsonSchema.properties.skill_names.items.enum).toEqual(['coding'])

    expect(
      tool.schema.safeParse({
        action: 'start',
        title: 'Research',
        task: 'Research the question and write the requested report.',
        agent_plugin_ids: ['deep-research'],
        skill_names: ['coding']
      }).success
    ).toBe(true)
    expect(
      tool.schema.safeParse({
        action: 'start',
        title: 'Invalid plugin',
        task: 'Do it.',
        agent_plugin_ids: ['missing']
      }).success
    ).toBe(false)
  })

  it('sends only the intrinsic start fields to the control plane', async () => {
    const starts: Array<Record<string, unknown>> = []
    const tool = createBackgroundAgentJobTool(
      toolOptions({
        rpc: (async (method: unknown, payload: unknown) => {
          expect(method).toBe(rpcMethods.backgroundAgentJobCreate)
          starts.push(payload as Record<string, unknown>)
          return response()
        }) as RPCRequester
      })
    )

    const result = await tool.execute(
      'call-1',
      {
        action: 'start',
        title: 'Research',
        task: '  Preserve this task verbatim.  ',
        background: 'Context.',
        notes: 'Caution.',
        agent_plugin_ids: ['deep-research'],
        skill_names: ['coding'],
        workspace_mounts: [{ id: 'source', source: '/workspace/user-files/source', access: 'read_only' }],
        model: 'gpt-5.4',
        reasoning_effort: 'high'
      },
      new AbortController().signal
    )

    expect(starts).toHaveLength(1)
    expect(starts[0]).toMatchObject({
      sourceToolCallId: 'call-1',
      title: 'Research',
      task: '  Preserve this task verbatim.  ',
      agentPluginIds: ['deep-research'],
      skillNames: ['coding'],
      model: 'gpt-5.4',
      reasoningEffort: 'high'
    })
    expect(Object.keys(starts[0]!).sort()).toEqual(
      [
        'background',
        'model',
        'notes',
        'agentPluginIds',
        'reasoningEffort',
        'skillNames',
        'sourceToolCallId',
        'task',
        'title',
        'workspaceMounts'
      ].sort()
    )
    expect(result.content[0]).toMatchObject({ type: 'text' })
  })

  it('keeps the catalog capacity separate from the sixteen-Plugin Job limit', () => {
    const catalog = Array.from(
      { length: 17 },
      (_, index): AgentPluginCatalogEntry =>
        create(AgentPluginCatalogEntrySchema, {
          id: `plugin-${index}`,
          description: `Plugin ${index}`,
          version: '1.0.0',
          contentHash: String(index).padStart(64, 'a').slice(-64),
          skills: []
        })
    )
    const tool = createBackgroundAgentJobTool(toolOptions({ agentPluginCatalog: catalog, standaloneSkillNames: [] }))

    expect(
      tool.schema.safeParse({ action: 'start', title: 'One', task: 'Do it.', agent_plugin_ids: ['plugin-16'] }).success
    ).toBe(true)
    expect(
      tool.schema.safeParse({
        action: 'start',
        title: 'Too many',
        task: 'Do it.',
        agent_plugin_ids: catalog.map(plugin => plugin.id)
      }).success
    ).toBe(false)
  })

  it('fails closed on malformed Plugin catalogs and namespaced Skill mappings', () => {
    expect(() =>
      createBackgroundAgentJobTool(
        toolOptions({ agentPluginCatalog: undefined as unknown as AgentPluginCatalogEntry[] })
      )
    ).toThrow()
    expect(() =>
      createBackgroundAgentJobTool(
        toolOptions({
          agentPluginCatalog: [
            create(AgentPluginCatalogEntrySchema, {
              ...catalogInit(),
              skills: [{ catalogName: 'deep-research', codexName: 'wrong:name' }]
            })
          ]
        })
      )
    ).toThrow('invalid namespaced Skill mapping')
  })

  it('enforces action-specific fields', () => {
    const schema = createBackgroundAgentJobTool(toolOptions()).schema
    expect(schema.safeParse({ action: 'status' }).success).toBe(false)
    expect(schema.safeParse({ action: 'status', job_id: response().jobId }).success).toBe(true)
    expect(schema.safeParse({ action: 'list', title: 'Not allowed' }).success).toBe(false)
    expect(schema.safeParse({ action: 'steer', job_id: response().jobId }).success).toBe(false)
    expect(schema.safeParse({ action: 'steer', job_id: response().jobId, text: 'Continue.' }).success).toBe(true)
  })

  it('keeps owner-visible artifact paths explicit when the bounded result body is truncated', async () => {
    const projectPath = `/workspace/user-files/background-agent-jobs/${response().jobId}/project`
    const artifactPath = `${projectPath}/handoff.txt`
    const job = create(BackgroundAgentJobResponseSchema, {
      ...response(),
      status: 'succeeded',
      resultJson: jsonBytes({
        output_text: 'x'.repeat(20_000),
        files_changed: { total_count: 1, paths: ['handoff.txt'], truncated: false },
        project_path: projectPath,
        artifacts: { total_count: 50_000, paths: [artifactPath], truncated: true },
        artifact_roots: {
          total_count: 2,
          paths: [projectPath],
          truncated: true
        }
      })
    })
    const tool = createBackgroundAgentJobTool(toolOptions({ rpc: (async () => job) as RPCRequester }))

    const result = await tool.execute(
      'call-status',
      { action: 'status', job_id: job.jobId },
      new AbortController().signal
    )
    const visible = result.content[0]?.type === 'text' ? result.content[0].text : ''

    expect(visible).toContain(`project_path: ${projectPath}`)
    expect(visible).toContain('artifact_handoff: total_count=50000 shown_count=1 truncated=true')
    expect(visible).toContain(`artifact_paths:\n- ${artifactPath}`)
    expect(visible).toContain('artifact_roots: total_count=2 shown_count=1 truncated=true')
    expect(visible).toContain('configured_workspace_root: /workspace/user-files/project')
    expect(visible).toContain('artifact_discovery: inspect artifact_roots')
    expect(visible).toContain('...[truncated]')
  })
})

function toolOptions(overrides: Partial<BackgroundAgentJobToolOptions> = {}): BackgroundAgentJobToolOptions {
  const job = response()
  return {
    turnStart: turnStartForTest(),
    agentPluginCatalog: pluginCatalog(),
    standaloneSkillNames: ['coding'],
    rpc: (async (method: unknown) => {
      if (method === rpcMethods.backgroundAgentJobList) {
        return create(BackgroundAgentJobListResponseSchema, { jobs: [] })
      }
      return job
    }) as RPCRequester,
    ...overrides
  }
}

function catalogInit() {
  return {
    id: 'deep-research',
    description: 'Evidence-backed research with forecast and retrospect workflows.',
    version: '1.0.0',
    contentHash: 'a'.repeat(64),
    skills: [{ catalogName: 'deep-research', codexName: 'deep-research:deep-research' }]
  }
}

function pluginCatalog(): AgentPluginCatalogEntry[] {
  return [create(AgentPluginCatalogEntrySchema, catalogInit())]
}

function response(): BackgroundAgentJobResponse {
  return create(BackgroundAgentJobResponseSchema, {
    jobId: '019f0000-0000-7000-8000-000000000001',
    agentUid: 'agent-1',
    ownerSessionId: 'session-1',
    status: 'queued',
    codexAccountId: 'aigateway',
    title: 'Research',
    task: 'Write the report.',
    replyRouteJson: jsonBytes({ binding_name: 'lark', signal_channel_id: 'chat-1' }),
    attempts: 0,
    agentPluginIds: ['deep-research'],
    skillNames: ['coding'],
    workspaceMounts: [{ id: 'workspace', source: '/workspace/user-files/project', access: 'read_write' }]
  })
}
