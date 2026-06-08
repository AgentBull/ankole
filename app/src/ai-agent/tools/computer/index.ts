import { type ResolveSessionResponse, Computer } from '@agentbull/bullx-computer'
import type { AgentTool } from '../../core'
import { createCommandTool } from './command-tool'
import type { ComputerToolContext } from './context'
import { createInteractiveTerminalTool } from './interactive-terminal-tool'
import { createPatchTool } from './patch-tool'
import { createProcessTool } from './process-tool'
import { createReadFileTool } from './read-file-tool'
import { createTerminalTool } from './terminal-tool'

export interface ComputerToolsBinding {
  agentUid: string
}

export interface ComputerToolsDeps {
  /** In-process worker resolver (the BullX control plane), bypassing the SDK's HTTP call. */
  resolveWorker: (agentUid: string, signal?: AbortSignal) => Promise<ResolveSessionResponse>
}

/**
 * Build the run-bound computer tools for one agent. They share a lazily-created
 * computer session (resolve-or-create on first use). `command` uses one-shot
 * worker commands, `terminal` uses the persistent shell shortcut, and
 * `interactive_terminal` uses tmux-backed terminal sessions.
 */
export function createComputerTools(binding: ComputerToolsBinding, deps: ComputerToolsDeps): AgentTool<any>[] {
  let computerPromise: Promise<Computer> | undefined
  const getComputer = (signal?: AbortSignal): Promise<Computer> => {
    computerPromise ??= Computer.getOrCreate({ agentUid: binding.agentUid, resolveWorker: deps.resolveWorker, signal })
    return computerPromise
  }
  const context: ComputerToolContext = { getComputer, backgroundIds: new Set() }
  return [
    createCommandTool(context),
    createTerminalTool(context),
    createInteractiveTerminalTool(context),
    createProcessTool(context),
    createReadFileTool(context),
    createPatchTool(context)
  ]
}
