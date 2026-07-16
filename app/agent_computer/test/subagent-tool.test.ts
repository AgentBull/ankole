import { describe, expect, it } from 'bun:test'
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createSubagentTool } from '../src/tools/subagent/subagent-tool'
import { materializeCodexConfig } from '../src/tools/codex/config'
import type {
  SubagentDelegationCreateRequest,
  SubagentDelegationGetRequest,
  SubagentDelegationResponse,
  SubagentDelegationSteerRequest
} from '../src/lanes/rpc_lane'
import { turnStartForTest } from './support/llm'
import { actorEventText } from '../src/core/turns/actor_event_text'
import { zodToJSONSchema } from '../src/core/llm/tool-schema'

describe('@ankole/agent-computer subagent tool', () => {
  it('validates the Deep Research start contract before any RPC call', () => {
    const tool = createSubagentTool({ turnStart: turnStartForTest() })

    expect(
      tool.schema.safeParse({
        action: 'start',
        title: 'Retrospect',
        task: 'Review the forecast.',
        runtime: 'deep_research',
        mode: 'retrospect'
      }).success
    ).toBe(false)
    expect(
      tool.schema.safeParse({
        action: 'start',
        title: 'Ordinary task',
        task: 'Do the task.',
        runtime: 'task_worker',
        mode: 'forecast'
      }).success
    ).toBe(false)
    expect(
      tool.schema.safeParse({
        action: 'start',
        title: 'Forecast',
        task: 'Produce a forecast.',
        runtime: 'deep_research',
        mode: 'forecast'
      }).success
    ).toBe(true)
    expect(
      tool.schema.safeParse({
        action: 'status',
        delegation_id: '019f0000-0000-7000-8000-000000000001',
        output_schema: { type: 'object' }
      }).success
    ).toBe(false)

    for (const params of [
      { action: 'start', title: 'Task', task: 'Do it.' },
      { action: 'list' },
      { action: 'steer', delegation_id: '019f0000-0000-7000-8000-000000000001', text: 'Continue.' },
      { action: 'stop', delegation_id: '019f0000-0000-7000-8000-000000000001' }
    ] as const) {
      expect(tool.schema.safeParse({ ...params, trajectory_limit: 1 }).success).toBe(false)
      expect(tool.schema.safeParse({ ...params, trajectory_cursor: 'older' }).success).toBe(false)
    }
  })

  it('rejects task_worker output schemas that Codex strict output cannot accept', () => {
    const tool = createSubagentTool({ turnStart: turnStartForTest() })
    const productionSchema = {
      type: 'object',
      properties: {
        pdf_path: { type: 'string' },
        pages: { type: 'integer' },
        limitations: { type: 'array', items: { type: 'string' } }
      },
      required: ['pdf_path']
    }
    const invalid = tool.schema.safeParse({
      action: 'start',
      title: 'Produce a PDF',
      task: 'Produce and validate the PDF.',
      runtime: 'task_worker',
      output_schema: productionSchema
    })

    expect(invalid.success).toBe(false)
    if (!invalid.success) {
      expect(invalid.error.issues.map(issue => issue.message)).toEqual(
        expect.arrayContaining([
          'every object output_schema must set additionalProperties to false',
          'every object output_schema must require every property; missing: pages, limitations'
        ])
      )
    }

    expect(
      tool.schema.safeParse({
        action: 'start',
        title: 'Produce a PDF',
        task: 'Produce and validate the PDF.',
        runtime: 'task_worker',
        output_schema: {
          type: 'object',
          properties: {
            result: {
              type: 'object',
              properties: {
                pdf_path: { type: 'string' },
                limitations: { type: ['array', 'null'], items: { type: 'string' } }
              },
              required: ['pdf_path', 'limitations'],
              additionalProperties: false
            }
          },
          required: ['result'],
          additionalProperties: false
        }
      }).success
    ).toBe(true)

    expect(
      tool.schema.safeParse({
        action: 'start',
        title: 'Research a PDF',
        task: 'Research and produce the PDF.',
        runtime: 'deep_research',
        output_schema: productionSchema
      }).success
    ).toBe(true)
  })

  it('is a pure asynchronous five-action RPC surface', async () => {
    const starts: SubagentDelegationCreateRequest[] = []
    const steers: SubagentDelegationSteerRequest[] = []
    const delegation = response()
    const tool = createSubagentTool({
      turnStart: turnStartForTest(),
      createSubagentDelegation: async request => {
        starts.push(request)
        return delegation
      },
      listSubagentDelegations: async request => ({
        request_id: request.request_id,
        delegations: [delegation]
      }),
      getSubagentDelegation: async () => ({
        ...delegation,
        status: 'succeeded',
        result: { summary: 'Launch brief written and verified.', marker: 'DELEGATE_DONE' }
      }),
      steerSubagentDelegation: async request => {
        steers.push(request)
        return { ...delegation, status: 'running' }
      },
      stopSubagentDelegation: async () => ({ ...delegation, status: 'stopped' })
    })

    expect(tool.name).toBe('subagent')
    expect(tool.description).toContain('immediate-response work and follow-up work')
    expect(tool.description).toContain('next assistant reply contains the completed result')
    expect(tool.description).toContain('deliver the completed result in a later reply')
    expect(tool.description).toContain('Several tool calls may still be direct')
    expect(tool.description).toContain('enabled long-running Skills')
    expect(`${tool.description}\n${JSON.stringify(zodToJSONSchema(tool.schema))}`).not.toContain('Codex')
    expect(tool.description).toContain('start returns immediately')

    const verbatimTask = '\n  Write the brief, run checks, and report in Chinese.  \n'
    const started = await tool.execute('tool-call-1', {
      action: 'start',
      title: 'Launch brief',
      task: verbatimTask,
      background: 'The audience is the operations team.',
      notes: 'Keep the deliverable concise.',
      workdir: delegation.workdir
    })
    expect('status' in started.details ? started.details.status : undefined).toBe('queued')
    expect(starts).toHaveLength(1)
    expect(starts[0]?.turn).toEqual(turnStartForTest().turn)
    expect(starts[0]?.title).toBe('Launch brief')
    expect(starts[0]?.task).toBe(verbatimTask)
    expect(starts[0]?.background).toBe('The audience is the operations team.')
    expect(starts[0]?.notes).toBe('Keep the deliverable concise.')
    expect(starts[0]?.workdir).toBe(delegation.workdir)

    const listed = await tool.execute('tool-call-2', { action: 'list' })
    const listedText = listed.content[0]?.type === 'text' ? listed.content[0].text : ''
    expect(listedText).toContain(delegation.delegation_id)
    expect(listedText).toContain('queued')
    expect(listedText).toContain('Launch brief')

    const status = await tool.execute('tool-call-status', {
      action: 'status',
      delegation_id: delegation.delegation_id
    })
    expect(status.content[0]).toMatchObject({ type: 'text' })
    const statusText = status.content[0]?.type === 'text' ? status.content[0].text : ''
    expect(statusText).toContain('task_excerpt: Write the brief.')
    expect(statusText).toContain('DELEGATE_DONE')

    await tool.execute('tool-call-3', {
      action: 'steer',
      delegation_id: delegation.delegation_id,
      answers: { audience: 'Operators' }
    })
    expect(steers[0]?.answers).toEqual({ audience: 'Operators' })

    const stopped = await tool.execute('tool-call-4', {
      action: 'stop',
      delegation_id: delegation.delegation_id,
      text: 'Priorities changed'
    })
    expect('status' in stopped.details ? stopped.details.status : undefined).toBe('stopped')
  })

  it('forwards status pagination and preserves the complete bounded trajectory page', async () => {
    const requests: SubagentDelegationGetRequest[] = []
    const delegation = response()
    const pageEnd = 'PAGE_END_MARKER'
    const executionEnd = 'EXECUTION_END_MARKER'
    const tool = createSubagentTool({
      turnStart: turnStartForTest(),
      getSubagentDelegation: async request => {
        requests.push(request)
        return {
          ...delegation,
          status: 'running',
          attempts: 1,
          execution: {
            attempt: 1,
            current: { runtime_turn_id: 'turn-1', kind: 'agent', status: 'in_progress' },
            lead_turn_number: 1,
            threads: { total: 1, child: 0 },
            turns: { lead: 1, child: 0, compaction: 0, active: 1 },
            progress: {
              completed_items: 1,
              tool_calls: 0,
              tools_used: [],
              files_changed: [`${'y'.repeat(20_000)}${executionEnd}`],
              active_items: []
            },
            trajectory_page: {
              format: 'ankole_chatml',
              version: 1,
              messages: [{ role: 'assistant', content: `${'x'.repeat(20_000)}${pageEnd}` }],
              next_cursor: 'cursor-older'
            },
            updated_at: new Date(0).toISOString()
          }
        }
      }
    })

    const result = await tool.execute('tool-call-status-page', {
      action: 'status',
      delegation_id: delegation.delegation_id,
      trajectory_limit: 1,
      trajectory_cursor: 'cursor-current'
    })
    const text = result.content[0]?.type === 'text' ? result.content[0].text : ''

    expect(requests).toHaveLength(1)
    expect(requests[0]).toMatchObject({ trajectory_limit: 1, trajectory_cursor: 'cursor-current' })
    expect(text).toContain(executionEnd)
    expect(text).toContain(new Date(0).toISOString())
    expect(text).toContain(pageEnd)
    expect(text).toContain('"next_cursor":"cursor-older"')
  })

  it('writes fixed official config and credentials into account-scoped CODEX_HOME', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-subagent-home-'))
    try {
      const authJSON = '{"tokens":{"access_token":"sensitive-subscription-token"}}'
      const materialized = materializeCodexConfig({
        sharedFsRoot: root,
        runtime: {
          mode: 'official_subscription',
          accountID: 'account-1',
          authJSON,
          authHash: 'hash-1'
        }
      })

      expect(materialized.codexHome).toBe(join(root, '.ankole', 'codex', 'account-1'))
      const configPath = join(materialized.codexHome, 'config.toml')
      const authPath = join(materialized.codexHome, 'auth.json')
      const config = readFileSync(configPath, 'utf8')
      expect(config).toContain('web_search = "disabled"')
      expect(config).toContain('project_doc_max_bytes = 131072')
      expect(config).toContain('multi_agent = false')
      expect(config).toContain('apps = false')
      expect(config).toContain('plugins = false')
      expect(config).not.toContain('base_url')
      expect(config).not.toContain('model_provider')
      expect(readFileSync(authPath, 'utf8')).toBe(authJSON)
      expect(statSync(configPath).mode & 0o777).toBe(0o600)
      expect(statSync(authPath).mode & 0o777).toBe(0o600)
      expect(materialized).not.toHaveProperty('cleanupRoot')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('disables Codex native web search in the generated AIGateway config', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-subagent-aigateway-config-'))
    try {
      const materialized = materializeCodexConfig({
        sharedFsRoot: root,
        runtime: {
          mode: 'aigateway',
          accountID: 'aigateway',
          modelOverride: 'coding',
          aiGatewayKey: {
            request_id: 'key-1',
            agent_uid: 'agent-1',
            api_key: 'test-key',
            token_type: 'Bearer',
            expires_at: Math.floor(Date.now() / 1000) + 3600,
            expires_in: 3600,
            scope: 'ai_gateway',
            base_url: 'http://control.test/api/v1/ai-gateway'
          }
        }
      })

      const config = readFileSync(join(materialized.codexHome, 'config.toml'), 'utf8')
      expect(config).toContain('web_search = "disabled"')
      expect(config).toContain('name = "Ankole AIGateway"')
      expect(config).toContain('model_provider = "ankole_aigateway"')
      expect(config).toContain('[model_providers.ankole_aigateway]')
      expect(config).not.toContain('[model_providers.openai]')
      expect(config).toContain('base_url = "http://control.test/api/v1/ai-gateway"')
      expect(existsSync(join(materialized.codexHome, 'auth.json'))).toBe(false)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('renders parent wakeups as verification and delivery instructions', () => {
    const text = actorEventText(
      {
        data: {
          title: 'Launch brief',
          result_summary: 'Drafted and tested.',
          workdir: '/workspace/user-files/subagent/019f0000'
        }
      },
      'subagent.delegation.completed'
    )

    expect(text).toContain('Verify the deliverables yourself')
    expect(text).toContain('subagent(status)')
    expect(text).toContain('make a small mechanical correction directly')
    expect(text).toContain('when the work benefits from the existing Codex context')
    expect(text).toContain('reply_attachment')
  })
})

function response(): SubagentDelegationResponse {
  return {
    request_id: 'subagent-response-1',
    delegation_id: '019f0000-0000-7000-8000-000000000001',
    agent_uid: 'agent-1',
    session_id: 'session-1',
    status: 'queued',
    runtime: 'task_worker',
    codex_account_id: 'aigateway',
    title: 'Launch brief',
    task: 'Write the brief.',
    background: 'Operations handoff context.',
    notes: 'Keep the report short.',
    reply_route: { binding_name: 'lark', signal_channel_id: 'chat-1' },
    attempts: 0,
    workdir: '/workspace/user-files/subagent/019f0000',
    queued_at: new Date(0).toISOString(),
    result: {},
    error: {},
    metadata: {}
  }
}
