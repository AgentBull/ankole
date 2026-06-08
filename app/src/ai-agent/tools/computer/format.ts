/** Shared formatting helpers for the computer tools (output limits, line numbering). */

export const MAX_OUTPUT_CHARS = 50_000
export const MAX_READ_CHARS = 100_000
const MAX_LINE_LENGTH = 2000

/** Truncate large output keeping head (40%) + tail (60%), matching hermes parity. */
export function truncateOutput(text: string, max = MAX_OUTPUT_CHARS): string {
  if (text.length <= max) return text
  const head = Math.floor(max * 0.4)
  const tail = max - head
  const omitted = text.length - max
  return `${text.slice(0, head)}\n... [output truncated — ${omitted} chars omitted of ${text.length} total] ...\n${text.slice(text.length - tail)}`
}

export interface NumberedLines {
  text: string
  totalLines: number
  truncated: boolean
}

/** Render `LINE_NUM|CONTENT` with 1-indexed pagination (read_file format). */
export function numberLines(content: string, offset: number, limit: number): NumberedLines {
  const lines = content.split('\n')
  if (lines.length > 0 && lines[lines.length - 1] === '') lines.pop() // trailing newline
  const totalLines = lines.length
  const start = Math.max(1, offset)
  const slice = lines.slice(start - 1, start - 1 + limit)
  const text = slice
    .map((line, index) => {
      const lineNumber = start + index
      const rendered = line.length > MAX_LINE_LENGTH ? `${line.slice(0, MAX_LINE_LENGTH)}... [line truncated]` : line
      return `${lineNumber}|${rendered}`
    })
    .join('\n')
  return { text, totalLines, truncated: totalLines > start - 1 + slice.length }
}

/** Heuristic binary check: a NUL byte in the first 8 KB. */
export function looksBinary(buffer: Buffer): boolean {
  return buffer.subarray(0, 8192).includes(0)
}

/**
 * Split an agent-supplied path into the relative path + cwd that `writeFiles`
 * needs. A `/workspace/...` absolute path is anchored at `/workspace`; a relative
 * path uses the provided cwd (default `/workspace`).
 */
export function splitWritePath(path: string, cwd?: string): { relative: string; cwd: string } {
  if (path.startsWith('/workspace/')) return { relative: path.slice('/workspace/'.length), cwd: '/workspace' }
  return { relative: path, cwd: cwd ?? '/workspace' }
}
