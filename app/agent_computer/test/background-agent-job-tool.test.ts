import { describe, expect, it } from 'bun:test'
import {
  createBackgroundAgentJobTool,
  type BackgroundAgentJobToolOptions
} from '../src/tools/background-agent-job/background-agent-job-tool'
import {
  rpcMethods,
  type BackgroundAgentJobCreateRequest,
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
    const starts: Array<Omit<BackgroundAgentJobCreateRequest, 'request_id'>> = []
    const tool = createBackgroundAgentJobTool(
      toolOptions({
        rpc: (async (method: unknown, payload: unknown) => {
          expect(method).toBe(rpcMethods.backgroundAgentJobCreate)
          starts.push(payload as Omit<BackgroundAgentJobCreateRequest, 'request_id'>)
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
      source_tool_call_id: 'call-1',
      title: 'Research',
      task: '  Preserve this task verbatim.  ',
      agent_plugin_ids: ['deep-research'],
      skill_names: ['coding'],
      model: 'gpt-5.4',
      reasoning_effort: 'high'
    })
    expect(Object.keys(starts[0]!).sort()).toEqual(
      [
        'background',
        'model',
        'notes',
        'agent_plugin_ids',
        'reasoning_effort',
        'skill_names',
        'source_tool_call_id',
        'task',
        'title',
        'turn',
        'workspace_mounts'
      ].sort()
    )
    expect(result.content[0]).toMatchObject({ type: 'text' })
  })

  it('keeps the catalog capacity separate from the sixteen-Plugin Job limit', () => {
    const catalog = Array.from(
      { length: 17 },
      (_, index): AgentPluginCatalogEntry => ({
        id: `plugin-${index}`,
        description: `Plugin ${index}`,
        version: '1.0.0',
        content_hash: String(index).padStart(64, 'a').slice(-64),
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
            {
              ...pluginCatalog()[0]!,
              skills: [{ catalog_name: 'deep-research', codex_name: 'wrong:name' }]
            }
          ]
        })
      )
    ).toThrow('invalid namespaced Skill mapping')
  })

  it('enforces action-specific fields', () => {
    const schema = createBackgroundAgentJobTool(toolOptions()).schema
    expect(schema.safeParse({ action: 'status' }).success).toBe(false)
    expect(schema.safeParse({ action: 'status', job_id: response().job_id }).success).toBe(true)
    expect(schema.safeParse({ action: 'list', title: 'Not allowed' }).success).toBe(false)
    expect(schema.safeParse({ action: 'steer', job_id: response().job_id }).success).toBe(false)
    expect(schema.safeParse({ action: 'steer', job_id: response().job_id, text: 'Continue.' }).success).toBe(true)
  })
})

function toolOptions(overrides: Partial<BackgroundAgentJobToolOptions> = {}): BackgroundAgentJobToolOptions {
  const job = response()
  return {
    turnStart: turnStartForTest(),
    agentPluginCatalog: pluginCatalog(),
    standaloneSkillNames: ['coding'],
    rpc: (async (method: unknown) => {
      if (method === rpcMethods.backgroundAgentJobList) return { request_id: 'req-1', jobs: [] }
      return job
    }) as RPCRequester,
    ...overrides
  }
}

function pluginCatalog(): AgentPluginCatalogEntry[] {
  return [
    {
      id: 'deep-research',
      description: 'Evidence-backed research with forecast and retrospect workflows.',
      version: '1.0.0',
      content_hash: 'a'.repeat(64),
      skills: [{ catalog_name: 'deep-research', codex_name: 'deep-research:deep-research' }]
    }
  ]
}

function response(): BackgroundAgentJobResponse {
  return {
    request_id: 'background-agent-job-response-1',
    job_id: '019f0000-0000-7000-8000-000000000001',
    agent_uid: 'agent-1',
    owner_session_id: 'session-1',
    status: 'queued',
    codex_account_id: 'aigateway',
    title: 'Research',
    task: 'Write the report.',
    reply_route: { binding_name: 'lark', signal_channel_id: 'chat-1' },
    attempts: 0,
    agent_plugin_ids: ['deep-research'],
    skill_names: ['coding'],
    workspace_mounts: [{ id: 'workspace', source: '/workspace/user-files/project', access: 'read_write' }],
    result: {},
    error: {},
    metadata: {}
  }
}
