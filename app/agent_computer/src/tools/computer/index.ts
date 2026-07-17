import type { AgentTool } from '../../core'
import { createCommandTool } from './command-tool'
import { createContainerComputer } from './computer'
import type { ComputerToolContext } from './context'
import { createPatchTool, createReplaceTool } from './patch-tool'
import { createReadFileTool } from './read-file-tool'
import { createReplyAttachmentTool } from './reply-attachment-tool'

export interface ComputerToolsBinding {
  agentUID: string
  conversationID?: string
  workspaceRoot: string
  /** Operator-managed shell variables resolved for this turn's agent. */
  workerEnv?: Record<string, string>
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
    createCommandTool(context),
    createReadFileTool(context),
    createReplaceTool(context),
    createPatchTool(context),
    createReplyAttachmentTool(context)
  ]
}

/** Builds the shared run-scoped context used by main-agent computer tools. */
function createComputerToolContext(binding: ComputerToolsBinding): ComputerToolContext {
  const executionScopeID = binding.conversationID ?? binding.agentUID
  const computer = createContainerComputer(binding.workspaceRoot, {
    workerEnv: binding.workerEnv
  })
  return {
    workspaceRoot: binding.workspaceRoot,
    executionScopeID,
    getComputer: async () => computer
  }
}
