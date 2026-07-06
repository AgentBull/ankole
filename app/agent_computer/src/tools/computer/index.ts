import type { AgentTool } from '../../core'
import type { JsonObject } from '@pleisto/active-support'
import { createBrowserTools } from '../browser/browser-tools'
import { createCommandTool } from './command-tool'
import { createContainerComputer, type ComputerToolContext } from './context'
import { createInteractiveTerminalTool } from './interactive-terminal-tool'
import { createPatchTool } from './patch-tool'
import { createReadFileTool } from './read-file-tool'
import { createReplyAttachmentTool } from './reply-attachment-tool'

export interface ComputerToolsBinding {
  agentUid: string
  conversationId?: string
  workspaceRoot: string
  browserRemoteCdpConfig?: JsonObject | null
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
  const executionScopeId = binding.conversationId ?? binding.agentUid
  const computer = createContainerComputer(binding.workspaceRoot, executionScopeId)
  const context: ComputerToolContext = {
    agentUid: binding.agentUid,
    workspaceRoot: binding.workspaceRoot,
    executionScopeId,
    browserRemoteCdpConfig: binding.browserRemoteCdpConfig,
    localBrowserIdleTtlMs: binding.localBrowserIdleTtlMs,
    getComputer: async () => computer
  }

  return [
    ...createBrowserTools(context),
    createCommandTool(context),
    createInteractiveTerminalTool(context),
    createReadFileTool(context),
    createPatchTool(context),
    createReplyAttachmentTool(context)
  ]
}
