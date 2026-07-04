import { basename } from 'node:path'
import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
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

export function createReplyAttachmentTool(
  context: ComputerToolContext
): AgentTool<typeof ReplyAttachmentParams, ReplyAttachmentDetails> {
  return {
    name: 'reply_attachment',
    description:
      'Attach one file from /workspace/user-files to the final provider reply. Use after creating a deliverable file that the user should receive in the current chat.',
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

function userFilesRelativePath(path: string, workspaceRoot: string): string {
  const normalized = path.replaceAll('\\', '/')
  const userFilesPrefix = `${workspaceRoot.replace(/\/+$/, '')}/user-files/`

  if (normalized.startsWith(userFilesPrefix)) {
    return trimLeadingSlash(normalized.slice(userFilesPrefix.length))
  }
  if (normalized.startsWith('/workspace/user-files/')) {
    return trimLeadingSlash(normalized.slice('/workspace/user-files/'.length))
  }

  throw new Error('reply_attachment only accepts files under /workspace/user-files')
}

function trimLeadingSlash(value: string): string {
  return value.replace(/^\/+/, '')
}
