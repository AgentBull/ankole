import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import { buildTool } from '../build-tool'
import type { ComputerToolContext } from './context'
import { MAX_READ_CHARS, looksBinary, numberLines } from './format'

const ReadFileParams = z.object({
  path: z.string().min(1).describe('Text file to read (absolute /workspace/..., relative, or ~/path).'),
  offset: z.number().int().min(1).optional().describe('1-indexed start line (default 1).'),
  limit: z.number().int().min(1).max(2000).optional().describe('Maximum lines to return (default 500, max 2000).'),
  cwd: z.string().optional().describe('Base directory for a relative path (default /workspace).'),
  workdir: z.string().optional().describe('Alias for cwd, matching command tool terminology.')
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
      "Read a text file from the computer with line numbers and pagination. Use this instead of cat/head/tail in command or terminal. Output format: 'LINE_NUM|CONTENT'. Relative paths resolve from cwd/workdir, defaulting to /workspace. Use offset and limit for large files; reads over about 100K characters are rejected so you can narrow the range. Cannot read images or binary files.",
    schema: ReadFileParams,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<ReadFileDetails>> {
      const computer = await context.getComputer(signal)
      const buffer = await computer.readFileToBuffer(
        { path: params.path, cwd: params.cwd ?? params.workdir },
        { signal }
      )
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
