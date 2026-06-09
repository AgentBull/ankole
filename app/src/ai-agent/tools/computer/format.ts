// oxlint-disable no-control-regex
/** Shared formatting helpers for the computer tools (output limits, line numbering). */

export const MAX_OUTPUT_CHARS = 50_000
export const MAX_READ_CHARS = 100_000
const MAX_LINE_LENGTH = 2000

const ANSI_STRING_PATTERN = /(?:\u001B[P^_][\s\S]*?(?:\u001B\\|\u009C)|[\u0090\u009E\u009F][\s\S]*?\u009C)/g
const ANSI_OSC_PATTERN = /(?:\u001B\][^\u0007\u001B]*(?:\u0007|\u001B\\)|\u009D[^\u0007\u009C]*(?:\u0007|\u009C))/g
const ANSI_CSI_PATTERN = /(?:\u001B\[|\u009B)[0-?]*[ -/]*[@-~]/g
const ANSI_ESC_PATTERN = /\u001B[()#%*+\-./ ][0-~]/g

/** Remove terminal control sequences from text before it is shown to the model. */
export function stripAnsi(text: string): string {
  return text
    .replace(ANSI_STRING_PATTERN, '')
    .replace(ANSI_OSC_PATTERN, '')
    .replace(ANSI_CSI_PATTERN, '')
    .replace(ANSI_ESC_PATTERN, '')
}

/** Truncate large output keeping head (40%) + tail (60%), matching hermes parity. */
export function truncateOutput(text: string, max = MAX_OUTPUT_CHARS): string {
  const cleaned = stripAnsi(text)
  if (cleaned.length <= max) return cleaned
  const head = Math.floor(max * 0.4)
  const tail = max - head
  const omitted = cleaned.length - max
  return `${cleaned.slice(0, head)}\n... [output truncated — ${omitted} chars omitted of ${cleaned.length} total] ...\n${cleaned.slice(cleaned.length - tail)}`
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
