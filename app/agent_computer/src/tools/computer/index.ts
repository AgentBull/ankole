import type { AgentTool } from '../../core'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import { createBrowserTools } from '../browser/browser-tools'
import { createCommandTool } from './command-tool'
import { createContainerComputer } from './computer'
import type { ComputerToolContext } from './context'
import { createInteractiveTerminalTool } from './interactive-terminal-tool'
import { createPatchTool } from './patch-tool'
import { createReadFileTool } from './read-file-tool'
import { createReplyAttachmentTool } from './reply-attachment-tool'

export interface ComputerToolsBinding {
  agentUID: string
  conversationID?: string
  workspaceRoot: string
  browserRemoteCDPConfig?: JSONObject | null
  localBrowserIdleTtlMs?: number
}

/**
 * Builds the run-bound tool list for Ankole Agent Computer.
 *
 * Ankole resolves a remote computer worker from the control plane. The model
 * loop already runs inside Agent Computer, so this factory keeps the migrated
 * tool contracts but binds them to the container's `/workspace`.
 */
export function createComputerTools(binding: ComputerToolsBinding): AgentTool<any>[] {
  const context = createComputerToolContext(binding)

  return [
    ...createBrowserTools(context),
    createCommandTool(context),
    createInteractiveTerminalTool(context),
    createReadFileTool(context),
    createPatchTool(context),
    createReplyAttachmentTool(context)
  ]
}

/** Builds the shared run-scoped context used by main-agent and subagent browser tools. */
export function createComputerToolContext(binding: ComputerToolsBinding): ComputerToolContext {
  const executionScopeID = binding.conversationID ?? binding.agentUID
  const computer = createContainerComputer(binding.workspaceRoot, executionScopeID)
  return {
    agentUID: binding.agentUID,
    workspaceRoot: binding.workspaceRoot,
    executionScopeID,
    browserRemoteCDPConfig: binding.browserRemoteCDPConfig,
    localBrowserIdleTtlMs: binding.localBrowserIdleTtlMs,
    getComputer: async () => computer
  }
}
