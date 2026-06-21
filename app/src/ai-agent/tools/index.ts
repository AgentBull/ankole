// Assembles the "run-static" tool set — the tools whose availability is fixed at
// startup by provider config (web_search / web_extract), as opposed to the
// run-bound tools (clarify, todo, browser, ...) the runtime builds per turn from
// a binding. Splitting these out lets the runtime decide capability once instead
// of per request.

import type { AgentTool } from '../core'
import { builtinWebProviders } from '../web/providers'
import { webProviderRegistry } from '../web/registry'
import { createWebExtractTool } from './web-extract-tool'
import { createWebSearchTool } from './web-search-tool'

export interface AiAgentToolSet {
  /** Run-static tools (web_search / web_extract) enabled by provider availability. */
  staticTools: AgentTool<any>[]
  /** Names to activate via `runtime.setTools(staticTools, activeNames)`. */
  activeNames: string[]
}

/** Register built-in web providers (idempotent). Call once at startup, before plugins. */
export function registerBuiltinWebProviders(): void {
  for (const provider of builtinWebProviders) {
    if (!webProviderRegistry.get(provider.id)) webProviderRegistry.register(provider)
  }
}

/**
 * Build the run-static tool set. Web tools are included only when at least one
 * provider for that capability is available. Must run after providers (built-in
 * + plugin) are registered, since availability depends on config.
 *
 * clarify is run-bound and wired separately via `runtime.setClarifyFactory`.
 */
export async function buildAiAgentTools(): Promise<AiAgentToolSet> {
  const staticTools: AgentTool<any>[] = []
  if (await webProviderRegistry.hasAnyAvailable('search')) staticTools.push(createWebSearchTool())
  if (await webProviderRegistry.hasAnyAvailable('extract')) staticTools.push(createWebExtractTool())
  return { staticTools, activeNames: staticTools.map(tool => tool.name) }
}
