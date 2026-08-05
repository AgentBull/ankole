import { rpcMethods, type RPCRequester } from '../../lanes/rpc_lane'
import { jsonFromBytes } from '../../fabric/envelope_proto'
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
  const response = await rpc(
    rpcMethods.appConfigureResolve,
    { keys: [RenderedFetchIdleTtlMsKey, SSRFFilterKey] },
    { agentUid: turnStart.turn.actor.agent_uid }
  )

  const renderedFetchIdleTtlMs = configuredValue(response.values[RenderedFetchIdleTtlMsKey]?.valueJson)
  const ssrfFilter = configuredValue(response.values[SSRFFilterKey]?.valueJson)

  return {
    ssrfFilter: ssrfFilter !== false,
    ...(typeof renderedFetchIdleTtlMs === 'number' && Number.isFinite(renderedFetchIdleTtlMs)
      ? { renderedFetchIdleTtlMs }
      : {})
  }
}

function configuredValue(valueJson: Uint8Array | undefined): unknown {
  return valueJson ? jsonFromBytes(valueJson) : undefined
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
  workspaceRoot: string
  browserRuntime?: BrowserRuntime
}) {
  return createWebTools({
    aiGateway: opts.aiGateway,
    workspaceRoot: opts.workspaceRoot,
    ...(opts.browserRuntime
      ? {
          renderedFallback: opts.browserRuntime.renderedWebFetchFallback(
            renderedFetchBrowserSettings(opts.renderedFetchRuntimeConfig, opts.workerEnv)
          )
        }
      : {})
  })
}
