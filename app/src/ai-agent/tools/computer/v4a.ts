/**
 * V4A ("apply_patch") envelope parser — the multi-file patch format hermes' `patch`
 * tool accepts in `mode: 'patch'`. We parse Update/Add/Delete/Move; the patch tool
 * applies Update/Add (Delete/Move need a file-delete API the worker doesn't expose
 * in v1).
 */

export type V4AOperation =
  | { kind: 'update'; path: string; hunks: Array<{ search: string; replace: string }> }
  | { kind: 'add'; path: string; content: string }
  | { kind: 'delete'; path: string }
  | { kind: 'move'; from: string; to: string }

const UPDATE = /^\*\*\*\s*Update\s+File:\s*(.+)$/
const ADD = /^\*\*\*\s*Add\s+File:\s*(.+)$/
const DELETE = /^\*\*\*\s*Delete\s+File:\s*(.+)$/
const MOVE = /^\*\*\*\s*Move\s+File:\s*(.+?)\s*->\s*(.+)$/

export function parseV4APatch(patch: string): V4AOperation[] {
  const lines = patch.split('\n')
  let cursor = 0
  for (let i = 0; i < lines.length; i++) {
    const trimmed = lines[i]!.trim()
    if (trimmed === '*** Begin Patch' || trimmed === '***Begin Patch') {
      cursor = i + 1
      break
    }
  }

  const ops: V4AOperation[] = []
  let update: Extract<V4AOperation, { kind: 'update' }> | null = null
  let add: { path: string; content: string[] } | null = null
  let search: string[] = []
  let replace: string[] = []
  let inHunk = false

  const flushHunk = () => {
    if (update && inHunk && (search.length > 0 || replace.length > 0)) {
      update.hunks.push({ search: search.join('\n'), replace: replace.join('\n') })
    }
    search = []
    replace = []
    inHunk = false
  }
  const flush = () => {
    flushHunk()
    if (update) {
      ops.push(update)
      update = null
    }
    if (add) {
      ops.push({ kind: 'add', path: add.path, content: add.content.join('\n') })
      add = null
    }
  }

  for (let i = cursor; i < lines.length; i++) {
    const line = lines[i]!
    const trimmed = line.trim()
    if (trimmed === '*** End Patch' || trimmed === '***End Patch') {
      flush()
      return ops
    }

    const update_ = trimmed.match(UPDATE)
    const add_ = trimmed.match(ADD)
    const delete_ = trimmed.match(DELETE)
    const move_ = trimmed.match(MOVE)
    if (update_) {
      flush()
      update = { kind: 'update', path: update_[1]!.trim(), hunks: [] }
      continue
    }
    if (add_) {
      flush()
      add = { path: add_[1]!.trim(), content: [] }
      continue
    }
    if (delete_) {
      flush()
      ops.push({ kind: 'delete', path: delete_[1]!.trim() })
      continue
    }
    if (move_) {
      flush()
      ops.push({ kind: 'move', from: move_[1]!.trim(), to: move_[2]!.trim() })
      continue
    }
    if (trimmed.startsWith('@@')) {
      flushHunk()
      inHunk = true
      continue
    }

    if (add) {
      if (line.startsWith('+')) add.content.push(line.slice(1))
      continue
    }
    if (update) {
      inHunk = true
      if (line.startsWith('+')) replace.push(line.slice(1))
      else if (line.startsWith('-')) search.push(line.slice(1))
      else if (line.startsWith('\\')) {
        continue // "\ No newline at end of file"
      } else {
        const context = line.startsWith(' ') ? line.slice(1) : line
        search.push(context)
        replace.push(context)
      }
    }
  }

  flush()
  return ops
}
