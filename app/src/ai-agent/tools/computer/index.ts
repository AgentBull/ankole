import { type ResolveSessionResponse, Computer } from '@agentbull/bullx-computer'
import type { AgentTool } from '../../core'
import { createBrowserTools } from '../browser/browser-tools'
import { createCodexDelegateTool } from './codex-delegate-tool'
import { createCommandTool } from './command-tool'
import type { ComputerToolContext } from './context'
import { createInteractiveTerminalTool } from './interactive-terminal-tool'
import { createPatchTool } from './patch-tool'
import { createProcessTool } from './process-tool'
import { createReadFileTool } from './read-file-tool'
import { materializeComputerRuntimeCredentials } from './runtime-credential-materialization'
import { createSendFileTool, type SendFileRunBinding } from './send-file-tool'
import { createTerminalTool } from './terminal-tool'

export interface ComputerToolsBinding extends SendFileRunBinding {
  agentUid: string
}

export interface ComputerToolsDeps {
  /** In-process worker resolver (the BullX control plane), bypassing the SDK's HTTP call. */
  resolveWorker: (agentUid: string, signal?: AbortSignal) => Promise<ResolveSessionResponse>
  /** Clears a stale sticky binding when the resolved worker dies before session acquisition completes. */
  releaseWorkerBinding?: (agentUid: string, worker: ResolveSessionResponse['worker']) => Promise<void>
}

/**
 * Build the run-bound computer tools for one agent. They share a lazily-created
 * computer session (resolve-or-create on first use). `command` uses one-shot
 * worker commands, `terminal` uses the persistent shell shortcut,
 * `interactive_terminal` uses tmux-backed terminal sessions, and browser tools
 * wrap the BullX-owned browser CLI inside the same computer.
 */
export function createComputerTools(binding: ComputerToolsBinding, deps: ComputerToolsDeps): AgentTool<any>[] {
  let computerPromise: Promise<Computer> | undefined
  let credentialsPromise: Promise<Computer> | undefined
  let lastResolvedWorker: ResolveSessionResponse['worker'] | undefined
  const getComputerSession = (signal?: AbortSignal): Promise<Computer> => {
    computerPromise ??= Computer.getOrCreate({
      agentUid: binding.agentUid,
      resolveWorker: async (agentUid, resolveSignal) => {
        const resolved = await deps.resolveWorker(agentUid, resolveSignal)
        lastResolvedWorker = resolved.worker
        return resolved
      },
      signal
    }).catch(async error => {
      computerPromise = undefined
      if (lastResolvedWorker && isRecoverableComputerResolveError(error)) {
        await deps.releaseWorkerBinding?.(binding.agentUid, lastResolvedWorker)
        lastResolvedWorker = undefined
        return Computer.getOrCreate({
          agentUid: binding.agentUid,
          resolveWorker: async (agentUid, resolveSignal) => {
            const resolved = await deps.resolveWorker(agentUid, resolveSignal)
            lastResolvedWorker = resolved.worker
            return resolved
          },
          signal
        })
      }
      throw error
    })
    return computerPromise
  }
  const getComputer = (signal?: AbortSignal): Promise<Computer> => {
    credentialsPromise ??= getComputerSession(signal)
      .then(async computer => {
        await materializeComputerRuntimeCredentials({ computer, agentUid: binding.agentUid })
        return computer
      })
      .catch(error => {
        credentialsPromise = undefined
        throw error
      })
    return credentialsPromise
  }
  const context: ComputerToolContext = {
    agentUid: binding.agentUid,
    // No conversation (programmatic runs) degrades to the agent-shared scope.
    executionScopeId: binding.conversationId ?? binding.agentUid,
    getComputer,
    backgroundIds: new Set()
  }
  return [
    ...createBrowserTools(context),
    createCodexDelegateTool(context),
    createCommandTool(context),
    createTerminalTool(context),
    createInteractiveTerminalTool(context),
    createProcessTool(context),
    createReadFileTool(context),
    createSendFileTool(context, binding),
    createPatchTool(context)
  ]
}

function isRecoverableComputerResolveError(error: unknown): boolean {
  const status = statusFromError(error)
  if (typeof status === 'number' && (status >= 500 || status === 408 || status === 429)) return true
  const message = error instanceof Error ? error.message.toLowerCase() : String(error).toLowerCase()
  return ['econnrefused', 'econnreset', 'fetch failed', 'socket hang up', 'timeout', 'timed out'].some(part =>
    message.includes(part)
  )
}

function statusFromError(error: unknown): number | undefined {
  if (!error || typeof error !== 'object') return undefined
  for (const key of ['status', 'statusCode', 'code']) {
    const value = (error as Record<string, unknown>)[key]
    const parsed = typeof value === 'number' ? value : typeof value === 'string' ? Number.parseInt(value, 10) : NaN
    if (Number.isInteger(parsed) && parsed >= 100 && parsed <= 599) return parsed
  }
  return undefined
}
