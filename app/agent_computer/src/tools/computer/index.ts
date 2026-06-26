import type { AgentTool } from '../../core'
import { createBrowserTools } from '../browser/browser-tools'
import { createCommandTool } from './command-tool'
import { createContainerComputer, type ComputerToolContext } from './context'
import { createInteractiveTerminalTool } from './interactive-terminal-tool'
import { createPatchTool } from './patch-tool'
import { createReadFileTool } from './read-file-tool'
import { createReplyAttachmentTool, type ReplyAttachmentStore } from './reply-attachment-tool'

export interface ComputerToolsBinding {
  agentUid: string
  conversationId?: string
  workspaceRoot: string
  replyAttachmentStore?: ReplyAttachmentStore
}

/**
 * Builds the run-bound tool list for Ankole Agent Computer.
 *
 * BullX resolves a remote computer worker from the control plane. Ankole already
 * runs the AI SDK loop inside Agent Computer, so this factory keeps the migrated
 * tool contracts but binds them to the container's `/workspace`.
 */
export function createComputerTools(binding: ComputerToolsBinding): AgentTool<any>[] {
  const computer = createContainerComputer(binding.workspaceRoot)
  const context: ComputerToolContext = {
    agentUid: binding.agentUid,
    workspaceRoot: binding.workspaceRoot,
    executionScopeId: binding.conversationId ?? binding.agentUid,
    getComputer: async () => computer,
    backgroundIds: new Set()
  }

  return [
    ...createBrowserTools(context),
    createCommandTool(context),
    createInteractiveTerminalTool(context),
    createReadFileTool(context),
    createPatchTool(context),
    ...(binding.replyAttachmentStore ? [createReplyAttachmentTool(context, binding.replyAttachmentStore)] : [])
  ]
}
