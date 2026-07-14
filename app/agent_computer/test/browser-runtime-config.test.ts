import { describe, expect, it } from 'bun:test'
import type { TurnStart } from '../src/lanes/actor_lane'
import { resolveBrowserRuntimeConfig } from '../src/core/turns/browser_runtime_config'
import type { TextTurnLoopOptions } from '../src/core/turns/turn_options'

describe('browser runtime AppConfigure', () => {
  it('resolves the semantic security.ssrf_filter key for every browser URL input', async () => {
    let requestedKeys: string[] = []
    const turnStart = { turn: { actor: { agent_uid: 'agent-security' } } } as TurnStart
    const opts = {
      requestAppConfigure: async (request: { request_id: string; agent_uid: string; keys: string[] }) => {
        requestedKeys = request.keys
        return {
          request_id: request.request_id,
          agent_uid: request.agent_uid,
          values: {
            'worker.remote_browser_cdp_config': { value: null, source: 'default' },
            'worker.local_browser_idle_ttl_ms': { value: 1_800_000, source: 'default' },
            'security.ssrf_filter': { value: true, source: 'agent' }
          }
        }
      }
    } as unknown as TextTurnLoopOptions

    const config = await resolveBrowserRuntimeConfig(turnStart, opts)

    expect(requestedKeys).toContain('security.ssrf_filter')
    expect(requestedKeys).not.toContain('web_tools.block_private_network')
    expect(config.ssrfFilter).toBe(true)
  })

  it('keeps private-network access open when AppConfigure is unavailable', async () => {
    const turnStart = { turn: { actor: { agent_uid: 'agent-default' } } } as TurnStart
    const config = await resolveBrowserRuntimeConfig(turnStart, {} as TextTurnLoopOptions)

    expect(config.ssrfFilter).toBe(false)
  })
})
