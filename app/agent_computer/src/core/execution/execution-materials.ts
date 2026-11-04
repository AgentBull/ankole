import type { BrowserRuntime, MaterializedBrowserRuntime } from '../../browser-runtime'
import { browserRuntimeEnv, withoutBrowserMaterialSourceEnv } from '../../browser-runtime'
import type { RenderedFetchRuntimeConfig } from '../../fabric/envelope_proto'
import type { RPCRequester, TurnRPCFrame } from '../../lanes/rpc_lane'
import { materializeMCPorterConfig, type MaterializedMCPorterConfig, type MCPServerConfig } from '../../tools/mcp'
import type { RenderedWebFetchOptions } from '../../tools/web/web-tools'
import { resolveAgentWorkerEnvParts, type ResolvedAgentWorkerEnv } from './worker_env'

export type PreparedExecutionMaterials = {
  workerEnv: Record<string, string>
  runtimeEnv: Record<string, string>
  browserEnv: Record<string, string>
  renderedFetch?: RenderedWebFetchOptions
  mcpServers: MCPServerConfig[]
  cleanup(): Promise<void>
}

type BrowserMaterialInput = {
  runtime: BrowserRuntime
  scopeRoot: string
  artifactRoot: string
  ssrfFilter: boolean
}

export type PrepareExecutionMaterialsInput = {
  agentHome: string
  rpc: RPCRequester
  frame: TurnRPCFrame
  bindingName?: string
  runtimeEnv?: Record<string, string>
  mcpServers: MCPServerConfig[]
  mcporterDirectory?: string
  projectEnv?: (workerEnv: ResolvedAgentWorkerEnv) => Record<string, string>
  renderedFetch?: { config: RenderedFetchRuntimeConfig; browserRuntime: BrowserRuntime }
  browser?: BrowserMaterialInput
  abortSignal?: AbortSignal
}

type MaterialCleanup = {
  browser?: Pick<MaterializedBrowserRuntime, 'cleanup'>
  mcporter?: Pick<MaterializedMCPorterConfig, 'cleanup'>
}

/**
 * Prepares the disposable environment for one execution.
 *
 * MCP traffic uses a live Turn credential. Browser material and MCPorter
 * configuration live only for the execution that owns them.
 */
export async function prepareExecutionMaterials(
  input: PrepareExecutionMaterialsInput
): Promise<PreparedExecutionMaterials> {
  let mcporter: MaterializedMCPorterConfig | undefined
  let browser: MaterializedBrowserRuntime | undefined

  try {
    input.abortSignal?.throwIfAborted()
    const resolved = await resolveAgentWorkerEnvParts(input.rpc, input.frame, input.bindingName)
    input.abortSignal?.throwIfAborted()

    const projectedWorkerEnv = input.projectEnv ? input.projectEnv(resolved) : resolved.vars
    const renderedFetch = input.renderedFetch?.browserRuntime.renderedWebFetchFallback({
      workerEnv: projectedWorkerEnv,
      ssrfFilter: input.renderedFetch.config.ssrfFilter,
      ...(typeof input.renderedFetch.config.renderedFetchIdleTtlMs === 'number'
        ? { idleTtlMs: input.renderedFetch.config.renderedFetchIdleTtlMs }
        : {})
    })
    input.abortSignal?.throwIfAborted()
    mcporter = materializeMCPorterConfig(input.mcpServers, {
      directory: input.mcporterDirectory,
      gatewayOrigin: resolved.vars.ANKOLE_MCP_ORIGIN,
      gatewayToken: resolved.vars.ANKOLE_MCP_TOKEN,
      connections: resolved.vars.ANKOLE_MCP_CONNECTIONS ? JSON.parse(resolved.vars.ANKOLE_MCP_CONNECTIONS) : {}
    })

    if (input.browser) {
      browser = await input.browser.runtime.materializePersistent({
        scopeRoot: input.browser.scopeRoot,
        artifactRoot: input.browser.artifactRoot,
        settings: {
          workerEnv: projectedWorkerEnv,
          ssrfFilter: input.browser.ssrfFilter
        }
      })
    }
    input.abortSignal?.throwIfAborted()

    const browserEnv = browser ? browserRuntimeEnv(browser) : {}
    let cleaned = false
    let refreshing: Promise<void> | undefined
    const refresh = resolved.vars.ANKOLE_MCP_TOKEN
      ? setInterval(() => {
          if (refreshing || cleaned) return
          refreshing = resolveAgentWorkerEnvParts(input.rpc, input.frame, input.bindingName)
            .then(next => {
              if (cleaned) return
              mcporter!.updateGateway({
                gatewayOrigin: next.vars.ANKOLE_MCP_ORIGIN,
                gatewayToken: next.vars.ANKOLE_MCP_TOKEN,
                connections: next.vars.ANKOLE_MCP_CONNECTIONS ? JSON.parse(next.vars.ANKOLE_MCP_CONNECTIONS) : {}
              })
            })
            .catch(() => {
              /* The current token remains usable until its expiry; retry on the next interval. */
            })
            .finally(() => {
              refreshing = undefined
            })
        }, 5 * 60_000)
      : undefined
    refresh?.unref()

    return {
      workerEnv: { ...withoutBrowserMaterialSourceEnv(projectedWorkerEnv), ...mcporter.env },
      runtimeEnv: {
        ...input.runtimeEnv,
        ANKOLE_MCP_TOKEN: resolved.vars.ANKOLE_MCP_TOKEN ?? '',
        ANKOLE_MCP_ORIGIN: resolved.vars.ANKOLE_MCP_ORIGIN ?? '',
        GIT_ASKPASS: '/usr/local/bin/ankole-git-askpass',
        GIT_TERMINAL_PROMPT: '0',
        GIT_CONFIG_PARAMETERS: "'credential.useHttpPath=true' 'credential.helper='"
      },
      browserEnv,
      renderedFetch,
      mcpServers: input.mcpServers,
      cleanup: async () => {
        if (cleaned) return
        cleaned = true
        clearInterval(refresh)
        await refreshing
        await cleanupExecutionMaterials({ browser, mcporter })
      }
    }
  } catch (error) {
    await cleanupExecutionMaterials({ browser, mcporter }).catch(() => undefined)
    throw error
  }
}

/** Testable cleanup rule used by every prepared execution. */
export async function cleanupExecutionMaterials(materials: MaterialCleanup): Promise<void> {
  let firstError: unknown

  try {
    await materials.browser?.cleanup()
  } catch (error) {
    firstError = error
  }

  try {
    materials.mcporter?.cleanup()
  } catch (error) {
    firstError ??= error
  }

  if (firstError) throw firstError
}
