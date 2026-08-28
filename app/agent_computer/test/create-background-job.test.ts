import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { zodToJSONSchema } from '../src/core/llm/tool-schema'
import { jsonBytes } from '../src/fabric/envelope_proto'
import {
  AgentPluginCatalogEntrySchema,
  BackgroundAgentJobResponseSchema
} from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { rpcMethods, type AgentPluginCatalogEntry, type RPCRequester } from '../src/lanes/rpc_lane'
import {
  createCreateBackgroundJobTool,
  type CreateBackgroundJobToolOptions
} from '../src/tools/background-agent-job/create-background-job'
import { turnStartForTest } from './support/llm'

describe('@ankole/agent-computer create_background_job tool', () => {
  it('accepts only title, task, and one optional workspace template', () => {
    const tool = createCreateBackgroundJobTool(toolOptions())
    const jsonSchema = zodToJSONSchema(tool.schema) as Record<string, any>

    expect(Object.keys(jsonSchema.properties).sort()).toEqual(['task', 'title', 'workspace_template_id'])
    expect(jsonSchema.required.sort()).toEqual(['task', 'title'])
    expect(jsonSchema.properties.workspace_template_id.enum).toEqual(['deep-research'])
    expect(tool.schema.safeParse({ title: 'Research', task: 'Write the report.' }).success).toBe(true)
    expect(
      tool.schema.safeParse({
        title: 'Research',
        task: 'Write the report.',
        workspace_template_id: 'deep-research'
      }).success
    ).toBe(true)

    for (const field of ['action', 'background', 'notes', 'skill_names', 'model', 'reasoning_effort', 'answers']) {
      expect(
        tool.schema.safeParse({ title: 'Research', task: 'Write the report.', [field]: 'forbidden' }).success
      ).toBe(false)
    }
  })

  it('sends the task verbatim and returns only the durable handle and status', async () => {
    const requests: Array<Record<string, unknown>> = []
    const tool = createCreateBackgroundJobTool(
      toolOptions({
        rpc: (async (method: unknown, payload: unknown) => {
          expect(method).toBe(rpcMethods.backgroundAgentJobCreate)
          requests.push(payload as Record<string, unknown>)
          return response()
        }) as RPCRequester
      })
    )

    const result = await tool.execute(
      'call-1',
      {
        title: '  Research  ',
        task: '  Preserve this task verbatim.  ',
        workspace_template_id: 'deep-research'
      },
      new AbortController().signal
    )

    expect(requests).toEqual([
      {
        sourceToolCallId: 'call-1',
        title: 'Research',
        task: '  Preserve this task verbatim.  ',
        modelProfile: '',
        workspaceTemplateId: 'deep-research'
      }
    ])
    expect(result.details).toEqual({ job_id: 1000, status: 'queued' })
  })

  it('rejects an unavailable workspace template', () => {
    const tool = createCreateBackgroundJobTool(toolOptions())

    expect(
      tool.schema.safeParse({ title: 'Research', task: 'Write the report.', workspace_template_id: 'missing' }).success
    ).toBe(false)
  })

  it('offers only projected custom model profiles and sends the selected logical name', async () => {
    const requests: Array<Record<string, unknown>> = []
    const tool = createCreateBackgroundJobTool(
      toolOptions({
        turnStart: {
          ...turnStartForTest(),
          request_context: {
            ai_agent: { max_iterations: 90 },
            custom_model_profiles: [
              { name: 'kimi', description: 'Long-context coding.' },
              { name: 'deepseek', description: 'Low-cost code review.' }
            ]
          }
        },
        rpc: (async (_method: unknown, payload: unknown) => {
          requests.push(payload as Record<string, unknown>)
          return response()
        }) as RPCRequester
      })
    )
    const jsonSchema = zodToJSONSchema(tool.schema) as Record<string, any>

    expect(jsonSchema.properties.model_profile.enum).toEqual(['deepseek', 'kimi'])
    expect(jsonSchema.required).not.toContain('model_profile')
    expect(tool.schema.safeParse({ title: 'Research', task: 'Do it.', model_profile: 'coding' }).success).toBe(false)

    await tool.execute(
      'call-custom',
      { title: 'Research', task: 'Do it.', model_profile: 'kimi' },
      new AbortController().signal
    )

    expect(requests).toEqual([
      {
        sourceToolCallId: 'call-custom',
        title: 'Research',
        task: 'Do it.',
        modelProfile: 'kimi',
        workspaceTemplateId: ''
      }
    ])
  })
})

function toolOptions(overrides: Partial<CreateBackgroundJobToolOptions> = {}): CreateBackgroundJobToolOptions {
  return {
    turnStart: turnStartForTest(),
    agentPluginCatalog: pluginCatalog(),
    rpc: (async () => response()) as RPCRequester,
    ...overrides
  }
}

function pluginCatalog(): AgentPluginCatalogEntry[] {
  return [
    create(AgentPluginCatalogEntrySchema, {
      id: 'deep-research',
      description: 'Evidence-backed research.',
      hasWorkspaceTemplate: true,
      skills: []
    })
  ]
}

function response() {
  return create(BackgroundAgentJobResponseSchema, {
    jobId: '1000',
    agentUid: 'agent-1',
    ownerSessionId: 'session-1',
    status: 'queued',
    title: 'Research',
    task: 'Write the report.',
    replyRouteJson: jsonBytes({ binding_name: 'lark', signal_channel_id: 'chat-1' }),
    attempts: 0,
    workspaceTemplateId: 'deep-research'
  })
}
