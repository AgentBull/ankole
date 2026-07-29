import type { AgentTool } from '../../core'
import { createApplyPatchTool } from './apply-patch-tool'
import { createCommandTool } from './command-tool'
import { createContainerComputer } from './computer'
import type { ComputerToolContext } from './context'
import { createReadFileTool } from './read-file-tool'
import { createReplyAttachmentTool } from './reply-attachment-tool'

export interface ComputerToolsBinding {
  agentUID: string
  conversationID?: string
  agentHome: string
  workspaceRoot: string
  userFilesRoot: string
  /** Operator-managed shell variables resolved for this turn's agent. */
  workerEnv?: Record<string, string>
  /** Trusted ephemeral shell variables for this Actor turn. */
  runtimeEnv?: Record<string, string>
}

/**
 * Builds the run-bound tool list for Ankole Agent Computer.
 *
 * Ankole resolves a remote computer worker from the control plane. The model
 * loop already runs inside Agent Computer, so this factory keeps the migrated
 * tool contracts but binds them to the current Agent Home at its real path.
 */
export function createComputerTools(binding: ComputerToolsBinding): AgentTool<any>[] {
  const context = createComputerToolContext(binding)

  return [
    createCommandTool(context),
    createReadFileTool(context),
    createApplyPatchTool(context),
    createReplyAttachmentTool(context)
  ]
}

/** Builds the shared run-scoped context used by main-agent computer tools. */
function createComputerToolContext(binding: ComputerToolsBinding): ComputerToolContext {
  const executionScopeID = binding.conversationID ?? binding.agentUID
  const computer = createContainerComputer(binding.agentHome, binding.workspaceRoot, {
    workerEnv: binding.workerEnv,
    runtimeEnv: binding.runtimeEnv
  })
  return {
    agentHome: binding.agentHome,
    workspaceRoot: binding.workspaceRoot,
    userFilesRoot: binding.userFilesRoot,
    executionScopeID,
    getComputer: async () => computer
  }
}
