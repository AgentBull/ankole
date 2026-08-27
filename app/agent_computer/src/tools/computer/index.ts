import type { WorkerAgentTool } from '../../core'
import { createApplyPatchTool } from './apply-patch-tool'
import { createCommandTool } from './command-tool'
import { createContainerComputer } from './computer'
import type { ComputerToolContext } from './context'
import { fffSearchRuntime } from './fff-search'
import { createFindTool } from './find-tool'
import { createGrepTool } from './grep-tool'
import { createLsTool } from './ls-tool'
import { createReadFileTool } from './read-file-tool'
import { createReplyAttachmentTool } from './reply-attachment-tool'

export interface ComputerToolsBinding {
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
export function createComputerTools(binding: ComputerToolsBinding): WorkerAgentTool[] {
  const context = createComputerToolContext(binding)
  // Warm the workspace search index while the model is still thinking, and
  // rescan a warm one: the shared filesystem can carry writes from other
  // Workers that the local watcher never saw.
  fffSearchRuntime.prewarm(binding.workspaceRoot)

  return [
    createCommandTool(context),
    createReadFileTool(context),
    createFindTool(context),
    createGrepTool(context),
    createLsTool(context),
    createApplyPatchTool(context),
    createReplyAttachmentTool(context)
  ]
}

/** Builds the shared run-scoped context used by main-agent computer tools. */
function createComputerToolContext(binding: ComputerToolsBinding): ComputerToolContext {
  const computer = createContainerComputer(binding.agentHome, binding.workspaceRoot, {
    workerEnv: binding.workerEnv,
    runtimeEnv: binding.runtimeEnv
  })
  return {
    agentHome: binding.agentHome,
    workspaceRoot: binding.workspaceRoot,
    userFilesRoot: binding.userFilesRoot,
    getComputer: async () => computer
  }
}
