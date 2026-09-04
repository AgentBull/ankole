import type { BrowserRuntime } from '../../browser-runtime'
import type { TurnStart } from '../../lanes/actor_lane'
import type { WorkerAgentTool } from '../types'
import type { AIGatewayHTTPClient } from '../ai_gateway_transport'
import { createWebTools } from '../../tools/web/web-tools'
import { renderedFetchBrowserSettings, type RenderedFetchRuntimeConfig } from './rendered_fetch_runtime_config'
import { webSearchIsProviderHosted } from './turn_runtime_policy'

/**
 * Text turns, Workflow tasks, and Codex Jobs share this projection so their
 * rendered-fetch fallback and their provider-hosted search rule stay
 * identical: when the Agent leaves web search to its model Provider, the local
 * `web_search` tool is absent. Browser materialization keeps browser-source
 * variables that other tools do not receive.
 */
export async function createTurnWebTools(opts: {
  turnStart: TurnStart
  aiGateway: AIGatewayHTTPClient
  renderedFetchRuntimeConfig: RenderedFetchRuntimeConfig
  workerEnv: Record<string, string>
  workspaceRoot: string
  repeatFetchSessionKey: string
  browserRuntime?: BrowserRuntime
}): Promise<WorkerAgentTool[]> {
  const tools = await createWebTools({
    aiGateway: opts.aiGateway,
    workspaceRoot: opts.workspaceRoot,
    repeatFetchSessionKey: opts.repeatFetchSessionKey,
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
