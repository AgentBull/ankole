import { type ResolveSessionResponse, Computer } from '@agentbull/bullx-computer'
import { statusFromError } from '@/common/errors'
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
  // Two-stage lazy memoization for the run. `computerPromise` is the bare session
  // (resolve-or-create); `credentialsPromise` is that same session after secrets and
  // library files have been materialized into it. Every tool goes through `getComputer`,
  // so the session is created on first tool use and shared by all later calls. Both are
  // promises (not values) so concurrent tool calls await the same in-flight setup instead
  // of each starting their own.
  let computerPromise: Promise<Computer> | undefined
  let credentialsPromise: Promise<Computer> | undefined
  // Remembers the worker the resolver last handed back, so a failed acquisition can ask the
  // control plane to drop that stale sticky binding before retrying (see the recovery below).
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
      // Clear the memo so a later tool call can retry from scratch rather than re-awaiting a
      // rejected promise forever.
      computerPromise = undefined
      // Recovery for a dead sticky worker: the binding pointed us at a worker that was already
      // resolved but then could not be reached (network/5xx/timeout). Ask the control plane to
      // release that binding so the next resolve picks a healthy worker, then try once more.
      // Only retried for transient/connectivity failures — a deterministic error would just fail
      // again and is rethrown below.
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
  // The handle every tool actually receives: the session plus a guarantee that runtime
  // credentials and library files were materialized into it exactly once before any tool runs.
  // Materialization is folded into this memo so it is not re-done on every tool call; a failure
  // clears the memo so the next call retries the whole acquire+materialize sequence.
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

/**
 * Decides whether a failed session acquisition is worth retrying against a fresh worker.
 *
 * Only transient failures qualify: server-side 5xx, request timeout (408), or rate limit (429)
 * by status, plus a set of low-level connection failures recognized by message because they
 * arrive as plain network errors without a usable status. A 4xx like "bad request" is treated as
 * deterministic and is excluded, since rebinding to another worker would not change the outcome.
 */
function isRecoverableComputerResolveError(error: unknown): boolean {
  const status = statusFromError(error, { fallback: undefined, includeCode: true })
  if (typeof status === 'number' && (status >= 500 || status === 408 || status === 429)) return true
  const message = error instanceof Error ? error.message.toLowerCase() : String(error).toLowerCase()
  return ['econnrefused', 'econnreset', 'fetch failed', 'socket hang up', 'timeout', 'timed out'].some(part =>
    message.includes(part)
  )
}
