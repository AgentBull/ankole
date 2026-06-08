/** Minimal LCS-based unified diff for the `patch` tool's output. */

interface DiffOp {
  type: 'eq' | 'del' | 'add'
  line: string
}

const MAX_DP_CELLS = 2_000_000

function lcsDiff(a: string[], b: string[]): DiffOp[] {
  const n = a.length
  const m = b.length
  const width = m + 1
  const dp = Array.from({ length: (n + 1) * width }, () => 0)
  const at = (i: number, j: number) => dp[i * width + j]!

  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      dp[i * width + j] = a[i] === b[j] ? at(i + 1, j + 1) + 1 : Math.max(at(i + 1, j), at(i, j + 1))
    }
  }

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
  while (i < n) ops.push({ type: 'del', line: a[i++]! })
  while (j < m) ops.push({ type: 'add', line: b[j++]! })
  return ops
}

/** Produce a unified diff with `context` lines around each change. */
export function unifiedDiff(oldText: string, newText: string, path: string, context = 3): string {
  if (oldText === newText) return `(no changes to ${path})`
  const a = oldText.split('\n')
  const b = newText.split('\n')
  const header = `--- a/${path}\n+++ b/${path}`
  if ((a.length + 1) * (b.length + 1) > MAX_DP_CELLS) {
    return `${header}\n@@ large change: ${a.length} → ${b.length} lines @@`
  }

  const ops = lcsDiff(a, b)
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
    if (!keep[idx]) {
      gap = true
      continue
    }
    if (gap && out.length > 1) out.push('@@')
    gap = false
    const op = ops[idx]!
    const prefix = op.type === 'eq' ? ' ' : op.type === 'del' ? '-' : '+'
    out.push(`${prefix}${op.line}`)
  }
  return out.join('\n')
}
