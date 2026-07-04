/**
 * Worker-side diff adapter for patch-tool output.
 *
 * The diff algorithm lives in the shared native kernel (`imara-diff` through
 * @ankole/kernel). This module owns only worker concerns: file labels, display
 * fallback, and size guards so an edit never fails merely because its review diff
 * could not be rendered.
 */

import { unifiedTextDiff } from '@ankole/kernel'

const MAX_KERNEL_DIFF_INPUT_CHARS = 2_000_000

/**
 * Renders a unified diff or a bounded fallback summary for very large changes.
 */
export async function unifiedDiff(oldText: string, newText: string, path: string, context = 3): Promise<string> {
  if (oldText === newText) return `(no changes to ${path})`

  const header = `--- a/${path}\n+++ b/${path}`
  const oldLines = countLines(oldText)
  const newLines = countLines(newText)
  if (oldText.length + newText.length > MAX_KERNEL_DIFF_INPUT_CHARS) {
    return `${header}\n@@ large change: ${oldLines} -> ${newLines} lines @@`
  }

  try {
    const body = await unifiedTextDiff(oldText, newText, context)
    const trimmed = body.trimEnd()
    return trimmed.length === 0 ? `${header}\n(no hunks)` : `${header}\n${trimmed}`
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error)
    return `${header}\n@@ diff unavailable: ${reason}; ${oldLines} -> ${newLines} lines @@`
  }
}

/**
 * Counts visible lines in text without treating a final newline as an extra row.
 */
function countLines(text: string): number {
  const lines = text.split('\n')
  if (lines.at(-1) === '') lines.pop()
  return lines.length
}
