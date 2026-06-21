/**
 * The `send_file` tool: takes a file the agent produced inside its computer (a CSV, a
 * PDF, a report) and delivers it back to the human in the IM conversation that the run
 * is bound to. "Send" here does not write to disk or the network directly — it enqueues
 * an outbound message on the external-gateway outbox, which the gateway later drains to
 * the chat provider (Lark/IM). The file is carried inline as base64 in that payload.
 */

import path from 'node:path'
import { z } from 'zod'
import type { DrizzleExternalGatewayOutbox } from '@/external-gateway/outbox'
import type { AgentTool, AgentToolResult } from '../../core'
import { buildTool } from '../build-tool'
import type { ComputerToolContext } from './context'

// Hard ceiling on outbound file size. Set to the chat provider's (Lark) 30 MB limit so
// the tool fails with a clear message instead of letting the gateway reject the send later.
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
  /** Whether the file actually reached the outbox; false on any guard/validation miss. */
  queued: boolean
  size: number
}

/**
 * The outbound IM channel this run can deliver to. Every field is optional because a
 * run may have no IM binding at all (e.g. a scheduled/headless run with nowhere to send
 * a file to). When any required field is missing the tool degrades gracefully instead of
 * throwing — see the guard at the top of `execute`.
 */
export interface SendFileRunBinding {
  agentUid: string
  bindingName?: string
  conversationId?: string
  outbox?: DrizzleExternalGatewayOutbox
  providerRoomId?: string
  providerThreadId?: string
  /** Nudges the gateway to drain the outbox now, so the file is sent promptly instead of on the next poll. */
  scheduleOutboxDrain?: (availableAt?: Date) => void
}

/** Builds the `send_file` tool bound to one run's computer session and IM outbound binding. */
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
    // Sends a message to the user, so it is ordered (sequential) but not destructive to
    // the computer — it reads a file and enqueues, it does not modify state on disk.
    executionMode: 'sequential',
    isDestructive: false,
    async execute(toolCallId, params, signal): Promise<AgentToolResult<SendFileDetails>> {
      // No usable IM binding (headless/scheduled run, or a partially-wired one): report it
      // as a normal tool result rather than throwing, so the model learns it cannot send
      // here and can adjust, instead of the run failing.
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
      // Each failure below returns queued:false with a reason instead of throwing, so the
      // model gets actionable feedback (wrong path, empty, too big) and can recover.
      if (!buffer) {
        return {
          content: [{ type: 'text', text: `File not found: ${params.path}` }],
          details: { filename, path: params.path, queued: false, size: 0 }
        }
      }
      // Empty files are rejected: an empty attachment is almost always a generation bug
      // upstream, and sending nothing would just confuse the user.
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

      // The file travels inline as base64 inside the outbox payload (no separate upload
      // step here); the gateway/provider turns it into a real attachment on send.
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
          // Idempotency key for the outbox: scoping it to conversation + this tool-call id
          // means a retry of the same call cannot deliver the file to the user twice.
          outboundKey: `ai-agent-file:${binding.conversationId}:${toolCallId}`,
          providerRoomId: binding.providerRoomId,
          providerThreadId: binding.providerThreadId,
          finalPayload: {
            // Optional one-line message shown just before the file; empty string sends the
            // file alone.
            markdown: params.message ?? '',
            files: [filePayload]
          }
        }
      })
      // Kick the gateway to flush now so the file appears promptly rather than waiting for
      // the next scheduled drain.
      binding.scheduleOutboxDrain()

      // queued:true reports that the file was handed to the outbox, not that the user has
      // received it yet — actual delivery is the gateway's asynchronous job.
      return {
        content: [{ type: 'text', text: `Queued file for IM delivery: ${filename} (${buffer.byteLength} bytes).` }],
        details: { filename, path: params.path, queued: true, size: buffer.byteLength }
      }
    }
  })
}

/**
 * Reduces a filename to something safe to show as an attachment name. Path separators
 * are replaced with `_` so a model-supplied name cannot imply a directory or escape into
 * a path; an empty result falls back to `file` so the attachment always has a name.
 */
function sanitizeFilename(filename: string): string {
  const clean = filename.trim().replace(/[\\/]/g, '_')
  return clean || 'file'
}
