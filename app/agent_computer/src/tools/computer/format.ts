// oxlint-disable no-control-regex
/** Shared formatting helpers for the computer tools (output limits, line numbering). */

import { sanitizeBinaryOutput, truncateUtf16Safe } from '@/common/text-sanitize'

// Output the model reads (command stdout/stderr) is capped at 50K chars; a single
// read_file call may return more (100K) since the model asked for that file explicitly.
// Both exist to keep one tool result from eating the context window.
export const MAX_OUTPUT_CHARS = 50_000
export const MAX_READ_CHARS = 100_000
// Per-line cap in read_file: a single absurdly long line (minified bundle, base64 blob)
// is truncated so it cannot dominate the output on its own.
const MAX_LINE_LENGTH = 2000

// The four ANSI_* patterns below cover the families of ANSI/VT escape sequences a
// terminal program emits (string/DCS, OSC title+hyperlink, CSI color/cursor, two-byte
// charset escapes). They are stripped because the model gains nothing from these control
// bytes, and they waste context and can interfere with text matching. Each pattern also
// matches the 8-bit (C1) form, not just the ESC-prefixed form.

const ANSI_STRING_PATTERN = /(?:\u001B[P^_][\s\S]*?(?:\u001B\\|\u009C)|[\u0090\u009E\u009F][\s\S]*?\u009C)/g
const ANSI_OSC_PATTERN = /(?:\u001B\][^\u0007\u001B]*(?:\u0007|\u001B\\)|\u009D[^\u0007\u009C]*(?:\u0007|\u009C))/g
const ANSI_CSI_PATTERN = /(?:\u001B\[|\u009B)[0-?]*[ -/]*[@-~]/g
const ANSI_ESC_PATTERN = /\u001B[()#%*+\-./ ][0-~]/g

/**
 * Removes terminal control sequences from text before it is shown to the model.
 * Order matters: the multi-char string/OSC sequences are removed first so their inner
 * bytes are gone before the broad CSI/ESC passes run, preventing a partial strip that
 * could leave stray fragments behind.
 */
export function stripAnsi(text: string): string {
  return text
    .replace(ANSI_STRING_PATTERN, '')
    .replace(ANSI_OSC_PATTERN, '')
    .replace(ANSI_CSI_PATTERN, '')
    .replace(ANSI_ESC_PATTERN, '')
}

/**
 * Truncates large output, keeping the head (40%) and tail (60%) and dropping the
 * middle. Tail gets the larger share because a command's outcome — errors, the final
 * summary, the prompt that returned — is usually at the end, while the head still
 * preserves how it started. Cleans ANSI/binary first so the budget is spent on real
 * text, not control bytes. The 40/60 split matches hermes for parity.
 */
export function truncateOutput(text: string, max = MAX_OUTPUT_CHARS): string {
  const cleaned = sanitizeBinaryOutput(stripAnsi(text))
  if (cleaned.length <= max) return cleaned
  const head = Math.floor(max * 0.4)
  const tail = max - head
  const omitted = cleaned.length - max
  const prefix = truncateUtf16Safe(cleaned, head)
  const suffixStart = cleaned.length - tail
  // The tail cut can land in the middle of a surrogate pair (e.g. an emoji), leaving a
  // lone low surrogate at the front of the suffix. Drop that orphan so the output stays
  // valid UTF-16 rather than starting with a replacement character.
  const suffix =
    suffixStart > 0 && isLowSurrogate(cleaned.charCodeAt(suffixStart))
      ? cleaned.slice(suffixStart + 1)
      : cleaned.slice(suffixStart)
  return `${prefix}\n... [output truncated — ${omitted} chars omitted of ${cleaned.length} total] ...\n${suffix}`
}

export interface NumberedLines {
  text: string
  totalLines: number
  truncated: boolean
}

/**
 * Renders `LINE_NUM|CONTENT` with 1-indexed pagination (the read_file format). Line
 * numbers are 1-based to match what an editor shows the user, so the model can refer to
 * a line the same way a person would. `offset` is clamped to >= 1 so a 0/negative value
 * does not slice from the wrong place.
 *
 * @param offset - 1-based first line to emit.
 * @param limit - Maximum lines to emit from `offset`.
 * @returns The numbered text, the file's total line count, and whether more lines remain
 *          past this page (so read_file can hint that the model should continue).
 */
export function numberLines(content: string, offset: number, limit: number): NumberedLines {
  const lines = content.split('\n')
  if (lines.length > 0 && lines[lines.length - 1] === '') lines.pop() // trailing newline
  const totalLines = lines.length
  const start = Math.max(1, offset)
  const slice = lines.slice(start - 1, start - 1 + limit)
  const text = slice
    .map((line, index) => {
      const lineNumber = start + index
      const safeLine = sanitizeBinaryOutput(line)
      // Over-long single lines are clipped with a marker so one pathological line can't
      // blow past the read budget while the rest of the page is still useful.
      const rendered =
        safeLine.length > MAX_LINE_LENGTH
          ? `${truncateUtf16Safe(safeLine, MAX_LINE_LENGTH)}... [line truncated]`
          : safeLine
      return `${lineNumber}|${rendered}`
    })
    .join('\n')
  // `truncated` is true when the page stopped short of the end of file (more to read),
  // computed from where the slice ended rather than whether `limit` was hit.
  return { text, totalLines, truncated: totalLines > start - 1 + slice.length }
}

/**
 * Heuristic binary check: a NUL byte within the first 8 KB. Cheap and good enough to
 * keep read_file/send-file from dumping binary as garbage text; it can miss a binary
 * whose first 8 KB happen to be NUL-free, which is an accepted tradeoff for not scanning
 * the whole file.
 */
export function looksBinary(buffer: Buffer): boolean {
  return buffer.subarray(0, 8192).includes(0)
}

/** True for a UTF-16 low surrogate code unit (the trailing half of a surrogate pair). */
function isLowSurrogate(value: number): boolean {
  return value >= 0xdc00 && value <= 0xdfff
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
