import type { BrowserRuntime } from '../../browser-runtime'
import type { WorkerAgentTool } from '../types'
import type { AIGatewayHTTPClient } from '../ai_gateway_transport'
import { createWebTools } from '../../tools/web/web-tools'
import { renderedFetchBrowserSettings, type RenderedFetchRuntimeConfig } from './rendered_fetch_runtime_config'

/**
 * Text Turns and Codex Jobs share this projection so their rendered-fetch
 * fallback stays identical. Browser materialization keeps browser-source
 * variables that other tools do not receive.
 */
export function createTurnWebTools(opts: {
  aiGateway: AIGatewayHTTPClient
  renderedFetchRuntimeConfig: RenderedFetchRuntimeConfig
  workerEnv: Record<string, string>
  workspaceRoot: string
  browserRuntime?: BrowserRuntime
}): Promise<WorkerAgentTool[]> {
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
