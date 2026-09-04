import { describe, expect, it } from 'bun:test'
import type { TurnStart } from '../src/lanes/actor_lane'
import { createTurnWebTools } from '../src/core/turns/turn_web_tools'
import { turnStartForTest } from './support/llm'

describe('turn web tools', () => {
  it('declares no local web_search when the Agent leaves search to its model Provider', async () => {
    const toolNames = async (aiAgent: Record<string, unknown>) => {
      const turnStart = turnStartForTest() as TurnStart
      turnStart.request_context = { ai_agent: aiAgent }
      const tools = await createTurnWebTools({
        turnStart,
        aiGateway: { baseURL: 'https://control.test/api/v1/ai-gateway', fetch: async () => new Response('{}') },
        renderedFetchRuntimeConfig: { ssrfFilter: true },
        workerEnv: {},
        workspaceRoot: '/tmp',
        repeatFetchSessionKey: 'turn-web-tools-test'
      })
      return tools.map(tool => tool.name)
    }

    expect(await toolNames({})).toEqual(['web_search', 'web_fetch'])
    expect(await toolNames({ provider_hosted: { web_search: false } })).toEqual(['web_search', 'web_fetch'])
    expect(await toolNames({ provider_hosted: { web_search: true } })).toEqual(['web_fetch'])
  })
})
