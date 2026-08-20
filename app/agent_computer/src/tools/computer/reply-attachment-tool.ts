import { basename, relative, resolve } from 'node:path'
import { z } from 'zod'
import { defineWorkerTool, type AgentToolResult, type WorkerAgentTool } from '../../core'
import { jsonToolResult } from '../../core/tool-result'
import { insideAgentHome, resolveAgentHomePath } from '../../core/agent-home-paths'
import { compactActivityPath } from '../activity-summary'
import type { ComputerToolContext } from './context'

const ReplyAttachmentParams = z.object({
  path: z.string().min(1).describe('File path under the cross-session user files directory.'),
  name: z.string().min(1).optional().describe('Display filename for the outbound attachment.'),
  mimeType: z.string().min(1).optional().describe('MIME type for the outbound attachment.')
})

interface ReplyAttachmentDetails {
  tool: 'reply_attachment'
  ok: true
  delivery_state: 'queued'
  attachments: Array<{
    agent_computer_path: string
    user_files_relative_path: string
    name: string
    mime_type?: string
    size: number
  }>
}

/**
 * Builds the tool that marks one Agent `user-files` file for provider reply
 * attachment.
 *
 * The tool does not upload the file itself; it records structured details that
 * the control plane can attach when finalizing the visible reply.
 */
export function createReplyAttachmentTool(
  context: ComputerToolContext
): WorkerAgentTool<typeof ReplyAttachmentParams, ReplyAttachmentDetails> {
  return defineWorkerTool({
    name: 'reply_attachment',
    description: `Queue a file for native delivery with the final reply: place the deliverable under ${context.userFilesRoot} and call reply_attachment with that real path. Success confirms that Ankole recorded the file, not that the chat provider accepted it. In the final answer, say the file is prepared for delivery; do not claim that the provider already received it.`,
    schema: ReplyAttachmentParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    describeActivity: params => {
      const path = compactActivityPath(params.path)
      return path
        ? { key: 'signals_gateway.reply.activity.attachment_prepare_target', bindings: { path } }
        : { key: 'signals_gateway.reply.activity.attachment_prepare' }
    },
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<ReplyAttachmentDetails>> {
      const computer = await context.getComputer(signal)
      const buffer = await computer.readFileToBuffer({ path: params.path }, { signal })
      if (!buffer) {
        throw new Error(`reply_attachment file not found: ${params.path}`)
      }

      const relativePath = userFilesRelativePath(
        params.path,
        context.agentHome,
        context.workspaceRoot,
        context.userFilesRoot
      )
      const attachment = {
        agent_computer_path: `${context.userFilesRoot}/${relativePath}`,
        user_files_relative_path: relativePath,
        name: params.name ?? basename(relativePath),
        ...(params.mimeType ? { mime_type: params.mimeType } : {}),
        size: buffer.byteLength
      }
      const details: ReplyAttachmentDetails = {
        tool: 'reply_attachment',
        ok: true,
        delivery_state: 'queued',
        attachments: [attachment]
      }

      return jsonToolResult(details)
    }
  })
}

/**
 * Converts accepted workspace paths to a user-files-relative path.
 */
function userFilesRelativePath(path: string, agentHome: string, workspaceRoot: string, userFilesRoot: string): string {
  const resolved =
    path.startsWith('/') && insideAgentHome(agentHome, path)
      ? resolve(path)
      : resolveAgentHomePath(agentHome, path, { cwd: workspaceRoot })
  const relativePath = relative(resolve(userFilesRoot), resolved).replaceAll('\\', '/')

  if (!relativePath || relativePath === '..' || relativePath.startsWith('../')) {
    throw new Error(`reply_attachment only accepts files under ${userFilesRoot}`)
  }

  return relativePath
}
