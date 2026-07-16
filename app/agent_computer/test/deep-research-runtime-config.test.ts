import { describe, expect, it } from 'bun:test'
import { DeepResearchConfigKey, resolveDeepResearchRuntimeConfig } from '../src/core/turns/deep_research_runtime_config'
import type { TextTurnLoopOptions } from '../src/core/turns/turn_options'
import { turnStartForTest } from './support/llm'

describe('@ankole/agent-computer Deep Research runtime config', () => {
  it('fails closed when the control-plane resolver is unavailable', async () => {
    await expect(resolveDeepResearchRuntimeConfig(turnStartForTest(), baseOptions())).rejects.toThrow(
      'Deep Research requires the control-plane AppConfigure resolver'
    )
  })

  it('loads the complete scoped policy object from AppConfigure', async () => {
    const requests: unknown[] = []
    const config = await resolveDeepResearchRuntimeConfig(turnStartForTest(), {
      ...baseOptions(),
      requestAppConfigure: async request => {
        requests.push(request)
        return {
          request_id: request.request_id,
          agent_uid: request.agent_uid,
          values: {
            [DeepResearchConfigKey]: {
              source: 'agent',
              scope: 'agent:agent-1',
              value: {
                wallclock_budget: 3_600_000,
                submission_grace: 120_000,
                retention_days: 45
              }
            }
          }
        }
      }
    })

    expect(requests).toHaveLength(1)
    expect(config).toEqual({
      wallclockBudgetMs: 3_600_000,
      submissionGraceMs: 120_000,
      retentionDays: 45
    })
  })

  it('rejects partial policy objects instead of silently mixing defaults', async () => {
    await expect(
      resolveDeepResearchRuntimeConfig(turnStartForTest(), {
        ...baseOptions(),
        requestAppConfigure: async request => ({
          request_id: request.request_id,
          agent_uid: request.agent_uid,
          values: {
            [DeepResearchConfigKey]: {
              source: 'agent',
              value: { wallclock_budget: 3_600_000 }
            }
          }
        })
      })
    ).rejects.toThrow('submission_grace must be an integer')
  })
})

function baseOptions(): TextTurnLoopOptions {
  return {
    workspaceRoot: '/workspace',
    requestAIGatewayAPIKey: async request => ({
      request_id: request.request_id,
      agent_uid: request.agent_uid,
      api_key: 'unused',
      token_type: 'Bearer',
      expires_at: 1,
      expires_in: 1,
      scope: 'ai_gateway',
      base_url: 'http://control.test/api/v1/ai-gateway'
    })
  }
}
