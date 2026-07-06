import { basename, relative, resolve } from 'node:path'
import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import { insideWorkspace, resolveWorkspacePath } from '../../core/workspace-paths'
import type { ComputerToolContext } from './context'

const ReplyAttachmentParams = z.object({
  path: z.string().min(1).describe('File path under /workspace/user-files to attach to the reply.'),
  name: z.string().min(1).optional().describe('Display filename for the outbound attachment.'),
  mimeType: z.string().min(1).optional().describe('MIME type for the outbound attachment.')
})

interface ReplyAttachmentDetails {
  tool: 'reply_attachment'
  ok: true
  attachments: Array<{
    agent_computer_path: string
    user_files_relative_path: string
    name: string
    mime_type?: string
    size: number
  }>
}

/**
 * Builds the tool that marks one `/workspace/user-files` file for provider reply
 * attachment.
 *
 * The tool does not upload the file itself; it records structured details that
 * the control plane can attach when finalizing the visible reply.
 */
export function createReplyAttachmentTool(
  context: ComputerToolContext
): AgentTool<typeof ReplyAttachmentParams, ReplyAttachmentDetails> {
  return {
    name: 'reply_attachment',
    description:
      "You can send files natively: to deliver a file to the user, call reply_attachment with a local path under /workspace/user-files (e.g. path='/workspace/user-files/report.pdf'). The file will be sent as a native attachment in the current provider reply.",
    schema: ReplyAttachmentParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<ReplyAttachmentDetails>> {
      const computer = await context.getComputer(signal)
      const buffer = await computer.readFileToBuffer({ path: params.path }, { signal })
      if (!buffer) {
        throw new Error(`reply_attachment file not found: ${params.path}`)
      }

      const relativePath = userFilesRelativePath(params.path, context.workspaceRoot)
      const attachment = {
        agent_computer_path: `/workspace/user-files/${relativePath}`,
        user_files_relative_path: relativePath,
        name: params.name ?? basename(relativePath),
        ...(params.mimeType ? { mime_type: params.mimeType } : {}),
        size: buffer.byteLength
      }
      const details: ReplyAttachmentDetails = {
        tool: 'reply_attachment',
        ok: true,
        attachments: [attachment]
      }

      return {
        content: [{ type: 'text', text: JSON.stringify(details) }],
        details
      }
    }
  }
}

/**
 * Converts accepted workspace paths to a user-files-relative path.
 */
function userFilesRelativePath(path: string, workspaceRoot: string): string {
  const resolved =
    path.startsWith('/') && insideWorkspace(workspaceRoot, path)
      ? resolve(path)
      : resolveWorkspacePath(workspaceRoot, path)
  const userFilesRoot = resolve(workspaceRoot, 'user-files')
  const relativePath = relative(userFilesRoot, resolved).replaceAll('\\', '/')

  if (!relativePath || relativePath === '..' || relativePath.startsWith('../')) {
    throw new Error('reply_attachment only accepts files under /workspace/user-files')
  }

  return relativePath
}
