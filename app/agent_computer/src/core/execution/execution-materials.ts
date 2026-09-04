import type { BrowserRuntime, MaterializedBrowserRuntime } from '../../browser-runtime'
import { browserSandboxRuntime, withoutBrowserMaterialSourceEnv } from '../../browser-runtime'
import type { RPCRequester } from '../../lanes/rpc_lane'
import { materializeMCPorterConfig, type MaterializedMCPorterConfig, type MCPServerConfig } from '../../tools/mcp'
import { materializeLarkCredential, type MaterializedLarkCredential } from './lark-credential'
import { resolveAgentWorkerEnvParts, type ResolvedAgentWorkerEnv } from './worker_env'

export type PreparedExecutionMaterials = {
  workerEnv: Record<string, string>
  runtimeEnv: Record<string, string>
  browserEnv: Record<string, string>
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
  agentUID: string
  agentHome: string
  rpc: RPCRequester
  bindingName?: string
  runtimeEnv?: Record<string, string>
  mcpServers: MCPServerConfig[]
  mcporterDirectory?: string
  projectEnv?: (workerEnv: ResolvedAgentWorkerEnv) => Record<string, string>
  consumeMaterialSourceEnv?: (workerEnv: Record<string, string>) => Promise<void>
  browser?: BrowserMaterialInput
  abortSignal?: AbortSignal
}

type MaterialCleanup = {
  browser?: Pick<MaterializedBrowserRuntime, 'cleanup'>
  mcporter?: Pick<MaterializedMCPorterConfig, 'cleanup'>
  lark?: Pick<MaterializedLarkCredential, 'cleanup'>
}

/**
 * Prepares the disposable environment for one sandbox execution.
 *
 * The raw Lark token never enters the returned WorkerEnv. Browser source
 * settings are consumed before they are removed, and every caller gets the
 * same Browser, MCPorter, then Lark cleanup order.
 */
export async function prepareExecutionMaterials(
  input: PrepareExecutionMaterialsInput
): Promise<PreparedExecutionMaterials> {
  let lark: MaterializedLarkCredential | undefined
  let mcporter: MaterializedMCPorterConfig | undefined
  let browser: MaterializedBrowserRuntime | undefined

  try {
    input.abortSignal?.throwIfAborted()
    const resolved = await resolveAgentWorkerEnvParts(input.agentUID, input.rpc, input.bindingName)
    input.abortSignal?.throwIfAborted()

    lark = materializeLarkCredential({
      agentUID: input.agentUID,
      agentHome: input.agentHome,
      rpc: input.rpc,
      workerEnv: resolved,
      ...(input.bindingName ? { bindingName: input.bindingName } : {})
    })

    const projectedWorkerEnv = input.projectEnv ? input.projectEnv(lark.workerEnv) : lark.workerEnv.vars
    await input.consumeMaterialSourceEnv?.(projectedWorkerEnv)
    input.abortSignal?.throwIfAborted()
    mcporter = materializeMCPorterConfig(input.mcpServers, {
      ...(input.mcporterDirectory ? { directory: input.mcporterDirectory } : {})
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

    const browserEnv = browser ? browserSandboxRuntime(browser).env : {}
    let cleaned = false

    return {
      workerEnv: { ...withoutBrowserMaterialSourceEnv(projectedWorkerEnv), ...mcporter.env },
      runtimeEnv: { ...(input.runtimeEnv ?? {}), ...lark.runtimeEnv },
      browserEnv,
      mcpServers: input.mcpServers,
      cleanup: async () => {
        if (cleaned) return
        cleaned = true
        await cleanupExecutionMaterials({ browser, mcporter, lark })
      }
    }
  } catch (error) {
    await cleanupExecutionMaterials({ browser, mcporter, lark }).catch(() => undefined)
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

  try {
    materials.lark?.cleanup()
  } catch (error) {
    firstError ??= error
  }

  if (firstError) throw firstError
}
