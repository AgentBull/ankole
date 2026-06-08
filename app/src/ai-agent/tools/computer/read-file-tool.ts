import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import { buildTool } from '../build-tool'
import type { ComputerToolContext } from './context'
import { MAX_READ_CHARS, looksBinary, numberLines } from './format'

const ReadFileParams = z.object({
  path: z.string().min(1).describe('File to read (absolute /workspace/... or relative).'),
  offset: z.number().int().min(1).optional().describe('1-indexed start line (default 1).'),
  limit: z.number().int().min(1).max(2000).optional().describe('Max lines to return (default 500).'),
  cwd: z.string().optional().describe('Base directory for a relative path (default /workspace).')
})

interface ReadFileDetails {
  path: string
  found: boolean
  totalLines: number
  truncated: boolean
}

export function createReadFileTool(context: ComputerToolContext): AgentTool<typeof ReadFileParams, ReadFileDetails> {
  return buildTool({
    name: 'read_file',
    label: 'Read File',
    description:
      "Read a text file from the computer with line numbers and pagination. Use this instead of cat/head/tail. Output format: 'LINE_NUM|CONTENT'. Use offset and limit for large files. Cannot read binary files.",
    schema: ReadFileParams,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<ReadFileDetails>> {
      const computer = await context.getComputer(signal)
      const buffer = await computer.readFileToBuffer({ path: params.path, cwd: params.cwd }, { signal })
      if (!buffer) {
        return {
          content: [{ type: 'text', text: `File not found: ${params.path}` }],
          details: { path: params.path, found: false, totalLines: 0, truncated: false }
        }
      }
      if (looksBinary(buffer)) {
        return {
          content: [
            {
              type: 'text',
              text: `Cannot read binary file: ${params.path} (use a different tool for images/binaries).`
            }
          ],
          details: { path: params.path, found: true, totalLines: 0, truncated: false }
        }
      }

      const { text, totalLines, truncated } = numberLines(
        buffer.toString('utf-8'),
        params.offset ?? 1,
        params.limit ?? 500
      )
      if (text.length > MAX_READ_CHARS) {
        return {
          content: [
            {
              type: 'text',
              text: `Read produced ${text.length} characters which exceeds the ${MAX_READ_CHARS}-char limit; narrow the range with offset and limit.`
            }
          ],
          details: { path: params.path, found: true, totalLines, truncated: true }
        }
      }

      const hint = truncated ? '\n... [more lines — use offset to continue reading] ...' : ''
      return {
        content: [{ type: 'text', text: text + hint }],
        details: { path: params.path, found: true, totalLines, truncated }
      }
    }
  })
}
