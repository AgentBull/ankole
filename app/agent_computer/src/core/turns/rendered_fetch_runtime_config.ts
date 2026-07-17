import { rpcMethods, type RPCRequester } from '../../lanes/rpc_lane'
import type { TurnStart } from '../../lanes/actor_lane'
import type { BrowserRuntime, RenderedFetchBrowserMaterializeSettings } from '../../browser-runtime'
import { createWebTools } from '../../tools/web/web-tools'
import type { AIGatewayHTTPClient } from '../ai_gateway_transport'

const RenderedFetchIdleTtlMsKey = 'worker.rendered_fetch_idle_ttl_ms'
const SSRFFilterKey = 'security.ssrf_filter'

export type RenderedFetchRuntimeConfig = {
  renderedFetchIdleTtlMs?: number
  ssrfFilter: boolean
}

/** Resolves only the internal rendered web_fetch fallback knobs. */
export async function resolveRenderedFetchRuntimeConfig(
  turnStart: TurnStart,
  rpc: RPCRequester
): Promise<RenderedFetchRuntimeConfig> {
  const response = await rpc(rpcMethods.appConfigureResolve, {
    agent_uid: turnStart.turn.actor.agent_uid,
    keys: [RenderedFetchIdleTtlMsKey, SSRFFilterKey]
  })

  const renderedFetchIdleTtlMs = response.values[RenderedFetchIdleTtlMsKey]?.value
  const ssrfFilter = response.values[SSRFFilterKey]?.value

  return {
    ssrfFilter: ssrfFilter !== false,
    ...(typeof renderedFetchIdleTtlMs === 'number' && Number.isFinite(renderedFetchIdleTtlMs)
      ? { renderedFetchIdleTtlMs }
      : {})
  }
}

/**
 * Projects the resolved fallback config into browser materialize settings.
 * Takes the full worker env on purpose: the browser backend needs the
 * material-source variables that other tool consumers get stripped.
 */
export function renderedFetchBrowserSettings(
  config: RenderedFetchRuntimeConfig,
  workerEnv: Record<string, string>
): RenderedFetchBrowserMaterializeSettings {
  return {
    workerEnv,
    ssrfFilter: config.ssrfFilter,
    ...(typeof config.renderedFetchIdleTtlMs === 'number' ? { idleTtlMs: config.renderedFetchIdleTtlMs } : {})
  }
}

/**
 * Builds the web tools for one turn, wiring the rendered web_fetch fallback
 * when a browser runtime is present. Shared by the text turn loop and the
 * codex job projection so the recipe cannot drift between the two.
 */
export function createTurnWebTools(opts: {
  aiGateway: AIGatewayHTTPClient
  renderedFetchRuntimeConfig: RenderedFetchRuntimeConfig
  workerEnv: Record<string, string>
  browserRuntime?: BrowserRuntime
  abortSignal?: AbortSignal
}) {
  return createWebTools({
    aiGateway: opts.aiGateway,
    abortSignal: opts.abortSignal,
    ...(opts.browserRuntime
      ? {
          renderedFallback: opts.browserRuntime.renderedWebFetchFallback(
            renderedFetchBrowserSettings(opts.renderedFetchRuntimeConfig, opts.workerEnv)
          )
        }
      : {})
  })
}
