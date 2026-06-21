/**
 * Minimal LCS-based unified diff for the `patch` tool's output. This is a display
 * artifact — what the user sees after an edit — not something fed back to the matcher,
 * so it favors readability and a self-contained implementation over producing the
 * minimal-edit-script a library like `diff` would. A line is the unit of comparison.
 */

interface DiffOp {
  type: 'eq' | 'del' | 'add'
  line: string
}

// Cap on the LCS table size (rows×cols). The table is O(n·m) in both time and memory,
// so a huge edit (e.g. a generated file rewritten wholesale) could blow up; past this
// many cells we skip the diff and print a one-line summary instead. Two million cells
// is a few MB of ints — cheap enough to always allow, large enough for normal edits.
const MAX_DP_CELLS = 2_000_000

/**
 * Computes a line-level edit script (equal / delete / add) via longest common
 * subsequence. Fills the DP table bottom-up, then walks it top-down to emit ops.
 *
 * Stored as a flat array indexed `i*width + j` rather than a 2-D array: one allocation
 * instead of n+1 row arrays, which matters at the cell counts this can reach. The
 * tie-break `>=` (favoring delete when both directions look equal) just fixes a stable
 * ordering for adjacent unrelated changes; it does not affect correctness.
 */
function lcsDiff(a: string[], b: string[]): DiffOp[] {
  const n = a.length
  const m = b.length
  const width = m + 1
  const dp = Array.from({ length: (n + 1) * width }, () => 0)
  const at = (i: number, j: number) => dp[i * width + j]!

  // dp[i][j] = LCS length of a[i:] and b[j:]; computed back-to-front so each cell reads
  // from already-filled neighbors to its right/below.
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      dp[i * width + j] = a[i] === b[j] ? at(i + 1, j + 1) + 1 : Math.max(at(i + 1, j), at(i, j + 1))
    }
  }

  // Reconstruct the script by following the choices the table encodes: equal lines
  // advance both cursors; otherwise step in whichever direction keeps the LCS length.
  const ops: DiffOp[] = []
  let i = 0
  let j = 0
  while (i < n && j < m) {
    if (a[i] === b[j]) {
      ops.push({ type: 'eq', line: a[i]! })
      i++
      j++
    } else if (at(i + 1, j) >= at(i, j + 1)) {
      ops.push({ type: 'del', line: a[i]! })
      i++
    } else {
      ops.push({ type: 'add', line: b[j]! })
      j++
    }
  }
  // One side exhausted: the remainder is a pure run of deletes or adds.
  while (i < n) ops.push({ type: 'del', line: a[i++]! })
  while (j < m) ops.push({ type: 'add', line: b[j++]! })
  return ops
}

/**
 * Produces a unified diff with `context` unchanged lines kept around each change.
 *
 * @param path - File path used in the `--- a/… +++ b/…` header (display only).
 * @param context - Unchanged lines to show on each side of a change (default 3).
 * @returns The diff text; a `(no changes)` note when identical; a one-line summary when
 *          the input is too large to diff (see {@link MAX_DP_CELLS}).
 */
export function unifiedDiff(oldText: string, newText: string, path: string, context = 3): string {
  if (oldText === newText) return `(no changes to ${path})`
  const a = oldText.split('\n')
  const b = newText.split('\n')
  const header = `--- a/${path}\n+++ b/${path}`
  // Guard the quadratic LCS before allocating its table: on an oversized change, skip
  // the line-by-line diff and summarize, so an enormous rewrite cannot stall the run or
  // flood the model's context with a giant diff.
  if ((a.length + 1) * (b.length + 1) > MAX_DP_CELLS) {
    return `${header}\n@@ large change: ${a.length} → ${b.length} lines @@`
  }

  const ops = lcsDiff(a, b)
  // Mark each op for inclusion if it is itself a change or lies within `context` lines
  // of one. This collapses long unchanged stretches while still surrounding every edit
  // with a few orienting lines, like standard unified diff.
  const keep = ops.map((_, idx) => {
    for (let delta = -context; delta <= context; delta++) {
      const neighbor = ops[idx + delta]
      if (neighbor && neighbor.type !== 'eq') return true
    }
    return false
  })

  const out = [header]
  let gap = false
  for (let idx = 0; idx < ops.length; idx++) {
    // Dropped (out-of-context) line: just remember that a gap occurred.
    if (!keep[idx]) {
      gap = true
      continue
    }
    // First kept line after a dropped run gets a bare `@@` separator so the reader sees
    // that lines were skipped. The `out.length > 1` test suppresses a leading `@@`
    // before any content (only the header is present yet). These are gap markers, not
    // real `@@ -start,len +start,len @@` hunk headers — line numbers are intentionally
    // omitted because nothing downstream parses them.
    if (gap && out.length > 1) out.push('@@')
    gap = false
    const op = ops[idx]!
    const prefix = op.type === 'eq' ? ' ' : op.type === 'del' ? '-' : '+'
    out.push(`${prefix}${op.line}`)
  }
  return out.join('\n')
}
