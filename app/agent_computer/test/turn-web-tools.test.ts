import { describe, expect, it } from 'bun:test'
import type { TurnStart } from '../src/lanes/actor_lane'
import { createTurnWebTools } from '../src/core/web-tools'

describe('turn web tools', () => {
  it('declares no local web_search when the Agent leaves search to its model Provider', async () => {
    const toolNames = async (aiAgent: Record<string, unknown>) => {
      const turnStart: TurnStart = {
        mode: 'start',
        fetch_runtime_config: { ssrfFilter: true },
        turn: {
          actor: { session_id: 'job:1000' },
          job_id: 1000,
          attempt: 1,
          actor_event_id: 'event-1'
        },
        actor_event: {
          actor_event_id: 'event-1',
          type: 'background_agent_job.turn'
        },
        request_context: { ai_agent: aiAgent }
      }
      const tools = await createTurnWebTools({
        turnStart,
        rpc: async () => {
          throw new Error('catalog must not perform RPC')
        },
        renderedFetchRuntimeConfig: { ssrfFilter: true },
        workerEnv: {}
      })
      return tools.map(tool => tool.name)
    }

    expect(await toolNames({})).toEqual(['web_search', 'web_fetch'])
    expect(await toolNames({ provider_hosted: { web_search: false } })).toEqual(['web_search', 'web_fetch'])
    expect(await toolNames({ provider_hosted: { web_search: true } })).toEqual(['web_fetch'])
  })
})
