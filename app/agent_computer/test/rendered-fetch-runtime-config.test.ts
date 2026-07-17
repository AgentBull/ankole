import { describe, expect, it } from 'bun:test'
import type { TurnStart } from '../src/lanes/actor_lane'
import { rpcMethods, type RPCRequester } from '../src/lanes/rpc_lane'
import { resolveRenderedFetchRuntimeConfig } from '../src/core/turns/rendered_fetch_runtime_config'

function appConfigureRPC(
  values: Record<string, { value: unknown; source: string }>,
  onKeys?: (keys: string[]) => void
): RPCRequester {
  return (async (method: unknown, payload: unknown) => {
    expect(method).toBe(rpcMethods.appConfigureResolve)
    const request = payload as { agent_uid: string; keys: string[] }
    onKeys?.(request.keys)
    return { request_id: 'req-1', agent_uid: request.agent_uid, values }
  }) as RPCRequester
}

describe('rendered web_fetch runtime AppConfigure', () => {
  it('requests the rendered-route TTL and semantic SSRF policy without backend configuration', async () => {
    let requestedKeys: string[] = []
    const turnStart = { turn: { actor: { agent_uid: 'agent-security' } } } as TurnStart
    const rpc = appConfigureRPC(
      {
        'worker.rendered_fetch_idle_ttl_ms': { value: 72_000, source: 'agent' },
        'security.ssrf_filter': { value: true, source: 'agent' }
      },
      keys => {
        requestedKeys = keys
      }
    )

    const config = await resolveRenderedFetchRuntimeConfig(turnStart, rpc)

    expect(requestedKeys).toEqual(['worker.rendered_fetch_idle_ttl_ms', 'security.ssrf_filter'])
    expect(requestedKeys).not.toContain('worker.remote_browser_cdp_config')
    expect(config).toEqual({ renderedFetchIdleTtlMs: 72_000, ssrfFilter: true })
  })

  it('fails safe when AppConfigure omits the SSRF policy but honors an explicit false', async () => {
    const turnStart = { turn: { actor: { agent_uid: 'agent-default' } } } as TurnStart
    const values: Record<string, { value: unknown; source: string }> = {}
    const rpc = appConfigureRPC(values)

    expect(await resolveRenderedFetchRuntimeConfig(turnStart, rpc)).toEqual({ ssrfFilter: true })
    values['security.ssrf_filter'] = { value: false, source: 'agent' }
    expect(await resolveRenderedFetchRuntimeConfig(turnStart, rpc)).toEqual({ ssrfFilter: false })
  })
})
