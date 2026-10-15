import { z } from 'zod'
import { defineWorkerTool, type AgentToolResult, type WorkerAgentTool } from '../../core'
import { compactActivityPath } from '../activity-summary'
import type { ContainerComputer } from './computer'
import type { ComputerToolContext } from './context'
import { MAX_READ_CHARS, clipLinesToBudget, looksBinary, renderNumberedWindow } from './format'

// The control plane converts the image for the model. The base64 copy of the
// file must fit the 16 MiB frame of the Worker channel.
const MAX_IMAGE_BYTES = 8 * 1024 * 1024
const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])

const ReadFileParams = z.object({
  path: z.string().min(1).describe('File to read (absolute, relative, or ~/path).'),
  offset: z.number().int().min(1).optional().describe('1-indexed start line (default 1).'),
  limit: z.number().int().min(1).max(2000).optional().describe('Maximum lines to return (default 500, max 2000).'),
  workdir: z.string().optional().describe('Base directory for a relative path (default current workspace).')
})

/** Structured result alongside the text: enough for the runtime to know if a follow-up read is needed. */
interface ReadFileDetails {
  path: string
  found: boolean
  totalLines: number
  truncated: boolean
}

export function createReadFileTool(
  context: ComputerToolContext
): WorkerAgentTool<typeof ReadFileParams, ReadFileDetails> {
  return defineWorkerTool({
    name: 'read_file',
    description:
      "Read a text file from the computer with line numbers and pagination, or view an image file (PNG, JPEG, GIF, WebP, or BMP, up to 8 MiB). Use this instead of cat/head/tail in command. Text output format: 'LINE_NUM|CONTENT'. Relative paths resolve from workdir, defaulting to the current workspace. Use offset and limit for large text files; a page stops at about 100K characters and tells you the offset to continue from. To view a PDF page or another image format, convert it to PNG first, for example with pdftoppm or magick.",
    schema: ReadFileParams,
    executionMode: 'parallel',
    isReadOnly: true,
    retrySafe: true,
    isDestructive: false,
    describeActivity: params => {
      const path = compactActivityPath(params.path)
      return path
        ? { key: 'signals_gateway.reply.activity.file_read_target', bindings: { path } }
        : { key: 'signals_gateway.reply.activity.file_read' }
    },
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<ReadFileDetails>> {
      const computer = context.computer
      // The reader process returns only this window plus the binary-sniff prefix, so a huge file never materializes here.
      const start = Math.max(1, params.offset ?? 1)
      const window = await computer.readFileWindow(
        { path: params.path, cwd: params.workdir, offset: start, limit: params.limit ?? 500 },
        { signal }
      )
      if (!window) {
        return {
          content: [{ type: 'text', text: `File not found: ${params.path}` }],
          details: { path: params.path, found: false, totalLines: 0, truncated: false }
        }
      }
      const mimeType = imageMimeType(window.sniff)
      if (mimeType) return viewImage(computer, params, mimeType, signal)
      if (looksBinary(window.sniff)) {
        return {
          content: [
            {
              type: 'text',
              text: `Cannot read binary file: ${params.path}. To view a PDF page or another image format, convert it to PNG first, for example with pdftoppm or magick, then read the PNG.`
            }
          ],
          details: { path: params.path, found: true, totalLines: 0, truncated: false }
        }
      }

      // Line numbering happens here, before the size check, because the rendered
      // (numbered) text is what counts against the budget.
      const window_ = renderNumberedWindow(window.lines, start, window.totalLines)
      const { startLine, totalLines } = window_
      let { endLine, text, truncated } = window_
      let clipNote = ''
      if (text.length > MAX_READ_CHARS) {
        const clipped = clipLinesToBudget(text, MAX_READ_CHARS)
        text = clipped.text
        endLine = startLine + clipped.keptLines - 1
        truncated = true
        clipNote = ` (${MAX_READ_CHARS}-char budget)`
      }

      const hint =
        text.length === 0 && totalLines > 0
          ? `\n[showing lines ${startLine}-${endLine} of ${totalLines}; offset is past end of file]`
          : truncated
            ? `\n... [showing lines ${startLine}-${endLine} of ${totalLines}${clipNote} — continue with offset=${endLine + 1}] ...`
            : `\n[${totalLines} lines total]`
      return {
        content: [{ type: 'text', text: text + hint }],
        details: { path: params.path, found: true, totalLines, truncated }
      }
    }
  })
}

async function viewImage(
  computer: ContainerComputer,
  params: z.output<typeof ReadFileParams>,
  mimeType: string,
  signal?: AbortSignal
): Promise<AgentToolResult<ReadFileDetails>> {
  const details = { path: params.path, found: true, totalLines: 0, truncated: false }
  const file = await computer.readFileBytes(
    { path: params.path, cwd: params.workdir, maxBytes: MAX_IMAGE_BYTES },
    { signal }
  )
  if (!file) {
    return {
      content: [{ type: 'text', text: `File not found: ${params.path}` }],
      details: { ...details, found: false }
    }
  }
  if ('size' in file) {
    return {
      content: [
        {
          type: 'text',
          text: `Image is too large to view: ${params.path} (${file.size} bytes; the limit is ${MAX_IMAGE_BYTES} bytes). Make a smaller copy first, for example with \`magick ${params.path} -resize 2048x2048 /tmp/view.png\`, then read it.`
        }
      ],
      details
    }
  }
  return {
    content: [
      { type: 'text', text: `Image file: ${params.path} (${mimeType}, ${file.bytes.byteLength} bytes)` },
      { type: 'image', image: file.bytes, mimeType }
    ],
    details
  }
}

/** Returns the MIME type of an image format that the control plane can convert for a model. */
export function imageMimeType(head: Buffer): string | undefined {
  if (head.subarray(0, 8).equals(PNG_SIGNATURE)) return 'image/png'
  if (head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff) return 'image/jpeg'
  const tag = head.subarray(0, 12).toString('latin1')
  if (tag.startsWith('GIF87a') || tag.startsWith('GIF89a')) return 'image/gif'
  if (tag.startsWith('RIFF') && tag.slice(8, 12) === 'WEBP') return 'image/webp'
  // A BMP header has four reserved zero bytes after its size field; text never does.
  if (tag.startsWith('BM') && head.length >= 10 && head.readUInt32LE(6) === 0) return 'image/bmp'
  return undefined
}
