import { describe, expect, it } from 'bun:test'
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createSubagentTool } from '../src/tools/subagent/subagent-tool'
import { materializeCodexConfig } from '../src/tools/codex/config'
import type {
  SubagentDelegationCreateRequest,
  SubagentDelegationResponse,
  SubagentDelegationSteerRequest
} from '../src/lanes/rpc_lane'
import { turnStartForTest } from './support/llm'
import { actorEventText } from '../src/core/turns/actor_event_text'

describe('@ankole/agent-computer subagent tool', () => {
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
    expect(tool.description).toContain('at least 10 minutes')
    expect(tool.description).toContain('start returns immediately')
    expect(tool.description).not.toContain('action=run')

    const started = await tool.execute('tool-call-1', {
      action: 'start',
      title: 'Launch brief',
      brief: 'Write the brief, run checks, and report in Chinese.'
    })
    expect('status' in started.details ? started.details.status : undefined).toBe('queued')
    expect(starts).toHaveLength(1)
    expect(starts[0]?.turn).toEqual(turnStartForTest().turn)
    expect(starts[0]?.title).toBe('Launch brief')
    expect(starts[0]?.prompt).toContain('report in Chinese')

    const listed = await tool.execute('tool-call-2', { action: 'list' })
    expect(listed.content[0]).toEqual({
      type: 'text',
      text: `${delegation.delegation_id} | queued | Launch brief | attempts=0`
    })

    const status = await tool.execute('tool-call-status', {
      action: 'status',
      delegation_id: delegation.delegation_id
    })
    expect(status.content[0]).toMatchObject({ type: 'text' })
    expect(status.content[0]?.type === 'text' ? status.content[0].text : '').toContain('DELEGATE_DONE')

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
    runtime: 'codex',
    codex_account_id: 'aigateway',
    title: 'Launch brief',
    prompt: 'Write the brief.',
    reply_route: { binding_name: 'lark', signal_channel_id: 'chat-1' },
    attempts: 0,
    workdir: '/workspace/user-files/subagent/019f0000',
    queued_at: new Date(0).toISOString(),
    result: {},
    error: {},
    metadata: {}
  }
}
