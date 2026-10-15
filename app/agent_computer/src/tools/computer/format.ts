// oxlint-disable no-control-regex

import { sanitizeBinaryOutput, truncateUtf16Safe, truncateUtf16SafeTail } from '@/common/text-sanitize'

// Command output uses the smaller cap. read_file uses the larger one because the model asked for that file.
export const MAX_OUTPUT_CHARS = 50_000
export const MAX_READ_CHARS = 100_000
// read_file clips each rendered line to this length.
const MAX_LINE_LENGTH = 2000

const ANSI_STRING_PATTERN = /(?:\u001B[P^_][\s\S]*?(?:\u001B\\|\u009C)|[\u0090\u009E\u009F][\s\S]*?\u009C)/g
const ANSI_OSC_PATTERN = /(?:\u001B\][^\u0007\u001B]*(?:\u0007|\u001B\\)|\u009D[^\u0007\u009C]*(?:\u0007|\u009C))/g
const ANSI_CSI_PATTERN = /(?:\u001B\[|\u009B)[0-?]*[ -/]*[@-~]/g
const ANSI_ESC_PATTERN = /\u001B[()#%*+\-./ ][0-~]/g

/** Remove multi-character sequences before the CSI and ESC passes so a partial strip cannot leave fragments. */
export function stripAnsi(text: string): string {
  return text
    .replace(ANSI_STRING_PATTERN, '')
    .replace(ANSI_OSC_PATTERN, '')
    .replace(ANSI_CSI_PATTERN, '')
    .replace(ANSI_ESC_PATTERN, '')
}

/** Truncates output and returns the counts needed to decide whether to store the full output. */
export function truncateOutputDetailed(
  text: string,
  max = MAX_OUTPUT_CHARS
): { text: string; omittedChars: number; totalChars: number } {
  const cleaned = sanitizeBinaryOutput(stripAnsi(text))
  if (cleaned.length <= max) return { text: cleaned, omittedChars: 0, totalChars: cleaned.length }
  const head = Math.floor(max * 0.4)
  const tail = max - head
  const omitted = cleaned.length - max
  const prefix = truncateUtf16Safe(cleaned, head)
  const suffix = truncateUtf16SafeTail(cleaned, tail)
  return {
    text: `${prefix}\n... [output truncated — ${omitted} chars omitted of ${cleaned.length} total] ...\n${suffix}`,
    omittedChars: omitted,
    totalChars: cleaned.length
  }
}

export function clipLinesToBudget(
  text: string,
  maxChars: number
): { text: string; clipped: boolean; keptLines: number; totalLines: number } {
  const lines = text.split('\n')
  if (text.length <= maxChars) {
    return { text, clipped: false, keptLines: lines.length, totalLines: lines.length }
  }

  const kept: string[] = []
  let used = 0
  for (const line of lines) {
    const cost = line.length + (kept.length > 0 ? 1 : 0)
    if (used + cost > maxChars) break
    kept.push(line)
    used += cost
  }
  if (kept.length === 0) {
    return { text: truncateUtf16Safe(lines[0] ?? '', maxChars), clipped: true, keptLines: 1, totalLines: lines.length }
  }
  return { text: kept.join('\n'), clipped: true, keptLines: kept.length, totalLines: lines.length }
}

export interface NumberedLines {
  endLine: number
  startLine: number
  text: string
  totalLines: number
  truncated: boolean
}

/**
 * Line numbers are 1-based so the model can name a line the way an editor does.
 * Each line arrives already clipped to its first 8 KB by the reader process.
 */
export function renderNumberedWindow(lines: string[], startLine: number, totalLines: number): NumberedLines {
  const endLine = lines.length === 0 ? startLine - 1 : startLine + lines.length - 1
  const text = lines
    .map((line, index) => {
      const lineNumber = startLine + index
      const safeLine = sanitizeBinaryOutput(line)
      const rendered =
        safeLine.length > MAX_LINE_LENGTH
          ? `${truncateUtf16Safe(safeLine, MAX_LINE_LENGTH)}... [line truncated]`
          : safeLine
      return `${lineNumber}|${rendered}`
    })
    .join('\n')
  return { endLine, startLine, text, totalLines, truncated: totalLines > startLine - 1 + lines.length }
}

/** A NUL-free prefix can still be binary; callers accept that miss. */
export function looksBinary(buffer: Buffer): boolean {
  return buffer.subarray(0, 8192).includes(0)
}
