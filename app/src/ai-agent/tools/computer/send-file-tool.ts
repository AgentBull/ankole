import path from 'node:path'
import { z } from 'zod'
import type { DrizzleExternalGatewayOutbox } from '@/external-gateway/outbox'
import type { AgentTool, AgentToolResult } from '../../core'
import { buildTool } from '../build-tool'
import type { ComputerToolContext } from './context'

const MAX_LARK_FILE_BYTES = 30 * 1024 * 1024

const SendFileParams = z.object({
  path: z.string().min(1).describe('File to send from the computer (absolute /workspace/... or relative).'),
  cwd: z.string().optional().describe('Base directory for a relative path (default /workspace).'),
  workdir: z.string().optional().describe('Alias for cwd, matching command tool terminology.'),
  filename: z.string().optional().describe('Visible filename in IM. Defaults to the basename of path.'),
  mimeType: z.string().optional().describe('Optional MIME type, e.g. text/csv or application/pdf.'),
  message: z.string().optional().describe('Optional short text to send immediately before the file.')
})

interface SendFileDetails {
  filename: string
  path: string
  queued: boolean
  size: number
}

export interface SendFileRunBinding {
  agentUid: string
  bindingName?: string
  conversationId?: string
  outbox?: DrizzleExternalGatewayOutbox
  providerRoomId?: string
  providerThreadId?: string
  scheduleOutboxDrain?: (availableAt?: Date) => void
}

export function createSendFileTool(
  context: ComputerToolContext,
  binding: SendFileRunBinding
): AgentTool<typeof SendFileParams, SendFileDetails> {
  return buildTool({
    name: 'send_file',
    label: 'Send File',
    description:
      'Send a file from the computer back to the current IM conversation. Use this after creating an artifact the user asked you to send, such as CSV, PDF, image, or report files. Prefer creating user-visible artifacts under /workspace/user-files, then call send_file with its path. Relative paths resolve from cwd/workdir, defaulting to /workspace.',
    schema: SendFileParams,
    executionMode: 'sequential',
    isDestructive: false,
    async execute(toolCallId, params, signal): Promise<AgentToolResult<SendFileDetails>> {
      if (
        !binding.bindingName ||
        !binding.conversationId ||
        !binding.outbox ||
        !binding.providerRoomId ||
        !binding.providerThreadId ||
        !binding.scheduleOutboxDrain
      ) {
        return {
          content: [{ type: 'text', text: 'Cannot send files in this context: no IM outbound binding is available.' }],
          details: {
            filename: params.filename ?? path.basename(params.path),
            path: params.path,
            queued: false,
            size: 0
          }
        }
      }

      const computer = await context.getComputer(signal)
      const buffer = await computer.readFileToBuffer(
        { path: params.path, cwd: params.cwd ?? params.workdir },
        { signal }
      )
      const filename = sanitizeFilename(params.filename ?? path.basename(params.path))
      if (!buffer) {
        return {
          content: [{ type: 'text', text: `File not found: ${params.path}` }],
          details: { filename, path: params.path, queued: false, size: 0 }
        }
      }
      if (buffer.byteLength === 0) {
        return {
          content: [{ type: 'text', text: `Cannot send empty file: ${params.path}` }],
          details: { filename, path: params.path, queued: false, size: 0 }
        }
      }
      if (buffer.byteLength > MAX_LARK_FILE_BYTES) {
        return {
          content: [
            {
              type: 'text',
              text: `Cannot send ${filename}: file is ${buffer.byteLength} bytes, above the 30 MB IM file limit.`
            }
          ],
          details: { filename, path: params.path, queued: false, size: buffer.byteLength }
        }
      }

      const filePayload = {
        filename,
        dataBase64: buffer.toString('base64'),
        ...(params.mimeType ? { mimeType: params.mimeType } : {})
      }

      await binding.outbox.enqueuePending({
        agentUid: binding.agentUid,
        bindingName: binding.bindingName,
        intent: {
          operation: 'post',
          outboundKey: `ai-agent-file:${binding.conversationId}:${toolCallId}`,
          providerRoomId: binding.providerRoomId,
          providerThreadId: binding.providerThreadId,
          finalPayload: {
            markdown: params.message ?? '',
            files: [filePayload]
          }
        }
      })
      binding.scheduleOutboxDrain()

      return {
        content: [{ type: 'text', text: `Queued file for IM delivery: ${filename} (${buffer.byteLength} bytes).` }],
        details: { filename, path: params.path, queued: true, size: buffer.byteLength }
      }
    }
  })
}

function sanitizeFilename(filename: string): string {
  const clean = filename.trim().replace(/[\\/]/g, '_')
  return clean || 'file'
}
