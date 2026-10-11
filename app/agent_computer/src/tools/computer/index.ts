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
import type { Drive } from '../../drive/drive'

export interface ComputerToolsBinding {
  agentHome: string
  workspaceRoot: string
  drive: Drive
  /** Operator-managed shell variables resolved for this turn's agent. */
  workerEnv?: Record<string, string>
  /** Trusted ephemeral shell variables for this Actor turn. */
  runtimeEnv?: Record<string, string>
}

/**
 * Builds the environment tools that the control-plane loop calls on this
 * Worker. The tools use the current workspace and the Agent Home.
 */
export function createComputerTools(binding: ComputerToolsBinding): WorkerAgentTool[] {
  const context = createComputerToolContext(binding)
  // Warm the workspace search index while the model is still thinking. A warm
  // index rescans too; fff throttles repeats, so the rescan is cheap.
  fffSearchRuntime.prewarm(binding.workspaceRoot)

  return computerToolsForContext(context)
}

/** The runtime and schema exporter use this same tool catalog. */
export function computerToolsForContext(context: ComputerToolContext): WorkerAgentTool[] {
  return [
    createCommandTool(context),
    createReadFileTool(context),
    createFindTool(context),
    createGrepTool(context),
    createLsTool(context),
    createApplyPatchTool(context)
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
    drive: binding.drive,
    computer
  }
}
