import { match, P } from '@pleisto/active-support'

/**
 * V4A ("apply_patch") envelope parser — the multi-file patch format accepted
 * by the strict `patch` tool and by the `apply_patch` command in the Job runtime.
 * The grammar follows Codex upstream:
 *
 *   start:         begin_patch hunk+ end_patch
 *   hunk:          add_hunk | delete_hunk | update_hunk
 *   add_hunk:      "*** Add File: " filename LF add_line+
 *   delete_hunk:   "*** Delete File: " filename LF
 *   update_hunk:   "*** Update File: " filename LF change_move? change?
 *   change_move:   "*** Move to: " filename LF
 *   change:        (change_context | change_line)+ eof_line?
 *
 * We parse Add/Update/Delete and the Update rename; the patch tool applies Add and
 * Update only (delete and rename need file APIs the worker doesn't expose in v1).
 * Where this parser differs, it is more permissive than upstream: the envelope
 * markers are optional and an unmarked body line counts as context.
 *
 * V4A is the context-diff dialect Codex/OpenAI `apply_patch` uses. The key design
 * choice is that a hunk is located by the lines that surround it (context lines),
 * not by line numbers: an LLM cannot reliably count lines in a file, so encoding
 * "replace lines 40-47" would be fragile. Instead each hunk carries the unchanged
 * lines above and below the edit, and the applier finds where they sit in the
 * current file. The `@@` markers only separate hunks here; unlike a real unified
 * diff they carry no line-number ranges to trust.
 */

export interface V4AHunk {
  context?: string
  endOfFile?: boolean
  replace: string
  search: string
}

export type V4AOperation =
  | { kind: 'update'; path: string; moveTo?: string; hunks: V4AHunk[] }
  | { kind: 'add'; path: string; content: string }
  | { kind: 'delete'; path: string }

// File-operation header lines. Each operation is introduced by a `*** <Verb> File:`
// line; the surrounding `\s*` tolerates the spacing variations models emit.
const UPDATE = /^\*\*\*\s*Update\s+File:\s*(.+)$/
const ADD = /^\*\*\*\s*Add\s+File:\s*(.+)$/
const DELETE = /^\*\*\*\s*Delete\s+File:\s*(.+)$/
// A rename belongs to the Update operation above it and carries the destination only.
const MOVE_TO = /^\*\*\*\s*Move\s+to:\s*(.+)$/i

/**
 * Parses a V4A patch envelope into a flat list of file operations. Pure: it only
 * splits the text into operations and hunks, and does not touch the filesystem or
 * try to locate the hunks — that is the patch tool's job.
 *
 * @param patch - The raw `*** Begin Patch` … `*** End Patch` envelope text.
 * @returns The operations in document order; an empty array if no envelope/body is found.
 */
export function parseV4APatch(patch: string): V4AOperation[] {
  const lines = patch.split('\n')
  // Skip any preamble the model wrote before the envelope and start parsing at the
  // line after `*** Begin Patch`. If the marker is missing, cursor stays at 0 and we
  // simply read from the top — being lenient here avoids rejecting otherwise-valid bodies.
  let cursor = 0
  for (let i = 0; i < lines.length; i++) {
    const trimmed = lines[i]!.trim()
    if (trimmed === '*** Begin Patch' || trimmed === '***Begin Patch') {
      cursor = i + 1
      break
    }
  }

  // The parser is a small line-at-a-time state machine. `update`/`add` hold the
  // operation currently being built; `search`/`replace` accumulate the two sides of
  // the hunk in progress. A hunk is only committed once the next boundary is seen, so
  // these buffers must be flushed at every transition (new hunk, new file, end).
  const ops: V4AOperation[] = []
  let update: Extract<V4AOperation, { kind: 'update' }> | null = null
  let add: { path: string; content: string[] } | null = null
  let context: string | undefined
  let endOfFile = false
  let search: string[] = []
  let replace: string[] = []
  let inHunk = false

  // Commits the current Update hunk (if it carried any lines) and resets the buffers.
  // The emptiness guard drops a bare `@@` with nothing under it instead of pushing a
  // no-op hunk that would match the entire file.
  const flushHunk = () => {
    if (update && inHunk && (search.length > 0 || replace.length > 0)) {
      update.hunks.push({
        ...(context === undefined ? {} : { context }),
        ...(endOfFile ? { endOfFile } : {}),
        search: search.join('\n'),
        replace: replace.join('\n')
      })
    }
    context = undefined
    endOfFile = false
    search = []
    replace = []
    inHunk = false
  }
  // Closes out the whole operation in progress (flushing its trailing hunk first) and
  // appends it to the result. Called whenever a new file header or the end marker is hit.
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
    // End marker: finish the pending operation and stop, ignoring any trailing text.
    if (trimmed === '*** End Patch' || trimmed === '***End Patch') {
      flush()
      return ops
    }

    // A file-operation header always closes whatever operation was open before it.
    const update_ = trimmed.match(UPDATE)
    const add_ = trimmed.match(ADD)
    const delete_ = trimmed.match(DELETE)
    const moveTo_ = trimmed.match(MOVE_TO)
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
    // A rename line renames the file the current Update operation targets, so it
    // annotates that operation instead of starting a new one.
    if (moveTo_ && update) {
      update.moveTo = moveTo_[1]!.trim()
      continue
    }
    if (update && trimmed === '*** End of File') {
      inHunk = true
      endOfFile = true
      continue
    }
    // `@@` starts the next hunk within the same Update file. Its trailing text is a
    // context anchor used by the applier before matching the hunk body.
    if (trimmed.startsWith('@@')) {
      flushHunk()
      context = trimmed === '@@' ? undefined : trimmed.replace(/^@@\s*/, '')
      inHunk = true
      continue
    }

    // For an Add, only `+` lines are file content; everything else is ignored so stray
    // blank or context lines in the body cannot leak into the new file.
    if (add) {
      if (line.startsWith('+')) add.content.push(line.slice(1))
      continue
    }
    if (update) {
      inHunk = true
      // Classify the body line by its first column, mirroring unified-diff conventions:
      //   '+' goes only to the replacement side, '-' only to the search side, and an
      // unmarked/space-prefixed line is shared context that appears on both sides. The
      // search side is what fuzzy-match later locates in the file; the replace side is
      // what gets written there. Note slicing by raw `+`/`-`/` ` (not on `trimmed`) so
      // the original indentation of the line survives into the match.
      match(line)
        .with(
          P.when(value => value.startsWith('+')),
          value => {
            replace.push(value.slice(1))
          }
        )
        .with(
          P.when(value => value.startsWith('-')),
          value => {
            search.push(value.slice(1))
          }
        )
        .with(
          P.when(value => value.startsWith('\\')),
          () => undefined
        )
        .otherwise(value => {
          // Context line: keep on both sides. A leading space is the diff column marker
          // and is stripped; a line with no marker at all is taken verbatim, which keeps
          // genuinely blank lines (emitted as "") intact as context.
          const context = value.startsWith(' ') ? value.slice(1) : value
          search.push(context)
          replace.push(context)
        })
      continue
    }
  }

  // Reached EOF without an explicit `*** End Patch` — flush whatever was in progress
  // rather than discarding the last operation.
  flush()
  return ops
}
