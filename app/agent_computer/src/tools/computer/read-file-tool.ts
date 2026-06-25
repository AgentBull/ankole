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

/** Structured result alongside the text: enough for the runtime to know if a follow-up read is needed. */
interface ReadFileDetails {
  path: string
  found: boolean
  totalLines: number
  truncated: boolean
}

/**
 * Builds the `read_file` tool: the model's way to read a text file with line numbers
 * and pagination. Preferred over `cat`/`head` through the command tool because the
 * numbered, length-capped output is both easier for the model to cite and bounded so it
 * cannot flood the context window.
 */
export function createReadFileTool(context: ComputerToolContext): AgentTool<typeof ReadFileParams, ReadFileDetails> {
  return buildTool({
    name: 'read_file',
    label: 'Read File',
    description:
      "Read a text file from the computer with line numbers and pagination. Use this instead of cat/head/tail in command or interactive_terminal. Output format: 'LINE_NUM|CONTENT'. Relative paths resolve from cwd/workdir, defaulting to /workspace. Use offset and limit for large files; reads over about 100K characters are rejected so you can narrow the range. Cannot read images or binary files.",
    schema: ReadFileParams,
    // Pure read with no side effects, so it may run in parallel with other reads and is
    // marked read-only/non-destructive for the permission layer.
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<ReadFileDetails>> {
      const computer = await context.getComputer(signal)
      const buffer = await computer.readFileToBuffer(
        { path: params.path, cwd: params.cwd ?? params.workdir },
        { signal }
      )
      // Missing file is a normal outcome, not an exception: report it as text with
      // found:false so the model can react instead of the whole tool call erroring out.
      if (!buffer) {
        return {
          content: [{ type: 'text', text: `File not found: ${params.path}` }],
          details: { path: params.path, found: false, totalLines: 0, truncated: false }
        }
      }
      // Refuse binaries up front: feeding raw bytes to the model is useless and pollutes
      // context. The model is told to use an image/binary-aware tool instead.
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

      // Default window is the first 500 lines from line 1; the model widens or moves it
      // via offset/limit. Line numbering happens here, before the size check, because the
      // rendered (numbered) text is what counts against the budget.
      const { text, totalLines, truncated } = numberLines(
        buffer.toString('utf-8'),
        params.offset ?? 1,
        params.limit ?? 500
      )
      // Even within the line limit the rendered text can be huge (very long lines).
      // Rather than truncate and risk hiding the part the model wanted, reject the read
      // and ask it to narrow the range — an explicit retry beats a silently clipped result.
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

      // When more lines remain past this page, append a hint so the model knows to
      // continue with a higher offset instead of assuming it saw the whole file.
      const hint = truncated ? '\n... [more lines — use offset to continue reading] ...' : ''
      return {
        content: [{ type: 'text', text: text + hint }],
        details: { path: params.path, found: true, totalLines, truncated }
      }
    }
  })
}
