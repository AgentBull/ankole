import { existsSync, statSync } from 'node:fs'
import { basename, normalize, relative, resolve } from 'node:path'
import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import type { FinalProposalAttachment } from '../../turn_envelopes'
import { buildTool } from '../build-tool'
import type { ComputerToolContext } from './context'

const ReplyAttachmentParams = z.object({
  path: z
    .string()
    .min(1)
    .describe('File to send as a native reply attachment. Must point inside /workspace/user-files.'),
  name: z.string().min(1).optional().describe('Optional provider-visible filename. Defaults to the file basename.'),
  mimeType: z.string().min(1).optional().describe('Optional MIME type hint.')
})

export type ReplyAttachmentStore = {
  attachments: FinalProposalAttachment[]
}

type ReplyAttachmentDetails = FinalProposalAttachment & {
  registered: true
}

export function createReplyAttachmentStore(): ReplyAttachmentStore {
  return { attachments: [] }
}

/**
 * Registers files the final provider reply should send as native attachments.
 *
 * The file itself is already durable worker filesystem state under
 * /workspace/user-files. This tool only records the model's provider-visible
 * intent so the final proposal does not depend on scraping paths from text.
 */
export function createReplyAttachmentTool(
  context: ComputerToolContext,
  store: ReplyAttachmentStore
): AgentTool<typeof ReplyAttachmentParams, ReplyAttachmentDetails> {
  return buildTool({
    name: 'reply_attachment',
    label: 'Reply Attachment',
    description:
      'Attach an existing /workspace/user-files file to the final external reply. Use this after creating or selecting a deliverable that should be sent as a native file attachment, not merely mentioned in text.',
    schema: ReplyAttachmentParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    async execute(_toolCallId, params): Promise<AgentToolResult<ReplyAttachmentDetails>> {
      const attachment = normalizeReplyAttachment(context.workspaceRoot, params)
      const existingIndex = store.attachments.findIndex(
        item => item.user_files_relative_path === attachment.user_files_relative_path
      )

      if (existingIndex >= 0) {
        store.attachments[existingIndex] = attachment
      } else {
        store.attachments.push(attachment)
      }

      return {
        content: [
          {
            type: 'text',
            text: `registered_reply_attachment=${attachment.agent_computer_path}\nname=${attachment.name}`
          }
        ],
        details: { ...attachment, registered: true }
      }
    }
  })
}

function normalizeReplyAttachment(
  workspaceRoot: string,
  params: z.infer<typeof ReplyAttachmentParams>
): FinalProposalAttachment {
  const root = resolve(workspaceRoot)
  const userFilesRoot = resolve(root, 'user-files')
  const path = workspacePath(root, params.path)

  if (!inside(path, userFilesRoot)) {
    throw new Error('reply attachments must be under /workspace/user-files')
  }
  if (!existsSync(path)) {
    throw new Error(`reply attachment file does not exist: ${params.path}`)
  }

  const stat = statSync(path)
  if (!stat.isFile()) {
    throw new Error(`reply attachment must be a regular file: ${params.path}`)
  }

  const relativePath = normalizeRelative(relative(userFilesRoot, path))
  const name = sanitizeName(params.name) || basename(relativePath)

  return {
    agent_computer_path: `/workspace/user-files/${relativePath}`,
    user_files_relative_path: relativePath,
    name,
    ...(params.mimeType ? { mime_type: params.mimeType } : {}),
    size: stat.size
  }
}

function workspacePath(root: string, path: string): string {
  const normalized = normalize(path)
  const relativePath = normalized.startsWith('/workspace')
    ? normalized.slice('/workspace'.length)
    : normalized.startsWith('/')
      ? normalized
      : `/${normalized}`

  const resolved = resolve(root, `.${relativePath}`)
  if (!inside(resolved, root)) {
    throw new Error('path escapes workspace root')
  }
  return resolved
}

function inside(path: string, root: string): boolean {
  return path === root || path.startsWith(`${root}/`)
}

function normalizeRelative(path: string): string {
  return path.split('\\').join('/')
}

function sanitizeName(value: string | undefined): string | undefined {
  const name = value?.split(/[\\/]/).pop()?.trim()
  return name || undefined
}
