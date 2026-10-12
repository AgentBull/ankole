import type { BrowserRuntime } from '../browser-runtime'
import type { TurnStart } from '../lanes/actor_lane'
import type { WorkerAgentTool } from './types'
import type { RPCRequester } from '../lanes/rpc_lane'
import { createWebTools } from '../tools/web/web-tools'
import { renderedFetchBrowserSettings, type RenderedFetchRuntimeConfig } from './rendered-fetch-runtime-config'
import { webSearchIsProviderHosted } from './runtime-policy'

/**
 * Builds the web tools of a Codex Job. When the Agent leaves web search to its
 * model Provider, the local `web_search` tool is absent. Browser
 * materialization keeps browser-source variables that other tools do not
 * receive.
 */
export async function createTurnWebTools(opts: {
  turnStart: TurnStart
  rpc: RPCRequester
  renderedFetchRuntimeConfig: RenderedFetchRuntimeConfig
  workerEnv: Record<string, string>
  browserRuntime?: BrowserRuntime
}): Promise<WorkerAgentTool[]> {
  const tools = await createWebTools({
    rpc: opts.rpc,
    turn: opts.turnStart.turn,
    ...(opts.browserRuntime
      ? {
          renderedFallback: opts.browserRuntime.renderedWebFetchFallback(
            renderedFetchBrowserSettings(opts.renderedFetchRuntimeConfig, opts.workerEnv)
          )
        }
      : {})
  })
  return webSearchIsProviderHosted(opts.turnStart) ? tools.filter(tool => tool.name !== 'web_search') : tools
}
