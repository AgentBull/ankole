/**
 * The `patch` tool: how the agent edits files on the computer. It has two modes that
 * share the same file-safety machinery (BOM/line-ending preservation, fuzzy matching,
 * unified-diff output):
 *
 *  - `replace` (default): find one string and swap it. Simple and unambiguous, the
 *    everyday path.
 *  - `patch`: apply a multi-file V4A (`apply_patch`) envelope. Used when the model
 *    wants to express several edits, or edits across files, in one call.
 *
 * Why a dedicated tool instead of letting the model run sed/awk/python? Those are
 * easy to get subtly wrong (escaping, in-place flags, encoding) and produce no review
 * artifact. This tool matches against the real file, refuses ambiguous edits, and
 * returns a unified diff the user can read.
 */

import { z } from 'zod'
import type { Computer } from '@agentbull/bullx-computer'
import type { AgentTool, AgentToolResult } from '../../core'
import { buildTool } from '../build-tool'
import type { ComputerToolContext } from './context'
import { unifiedDiff } from './diff'
import { splitWritePath } from './format'
import { findUniqueFuzzyMatch } from './fuzzy-match'
import { parseV4APatch } from './v4a'

const PatchParams = z.object({
  mode: z
    .enum(['replace', 'patch'])
    .optional()
    .describe("'replace' (default): find a unique string and replace it. 'patch': apply a V4A multi-file patch."),
  path: z.string().optional().describe('File to edit (replace mode).'),
  old_string: z.string().optional().describe('Exact text to find (replace mode).'),
  new_string: z.string().optional().describe('Replacement text; empty string deletes the match (replace mode).'),
  replace_all: z
    .boolean()
    .optional()
    .describe('Replace all occurrences instead of requiring a unique match (replace mode).'),
  patch: z
    .string()
    .optional()
    .describe('V4A patch envelope (patch mode): *** Begin Patch, file operations, hunks, then *** End Patch.'),
  cwd: z.string().optional().describe('Base directory for relative paths (default /workspace).'),
  workdir: z.string().optional().describe('Alias for cwd, matching command tool terminology.')
})

type PatchInput = z.infer<typeof PatchParams>

interface PatchDetails {
  mode: string
  filesModified: string[]
}

/**
 * The encoding-sensitive parts of a text file captured before editing, so they can be
 * reattached after. Matching and diffing happen on `normalized` (always LF, no BOM);
 * `hasBom`/`lineEnding` are replayed on write so the file the user sees keeps its
 * original byte-level conventions and the edit shows up as a content change, not a
 * spurious whitespace/encoding churn across every line.
 */
interface TextFileSnapshot {
  hasBom: boolean
  lineEnding: '\n' | '\r\n'
  normalized: string
}

/** Builds the `patch` tool bound to a run's computer session. */
export function createPatchTool(context: ComputerToolContext): AgentTool<typeof PatchParams, PatchDetails> {
  return buildTool({
    name: 'patch',
    label: 'Patch',
    description:
      "Targeted edits to files in the computer. Use this instead of sed/awk/perl/python scripts or heredocs for editing. Returns a unified diff. REPLACE MODE (default): pass path, old_string, and new_string; old_string must match uniquely unless replace_all=true, so include surrounding context lines. Use new_string='' to delete the match. PATCH MODE (mode='patch'): apply a V4A multi-file patch with *** Begin Patch / *** End Patch. Relative paths resolve from cwd/workdir, defaulting to /workspace.",
    schema: PatchParams,
    // Edits a file, so it must run after any in-flight reads/writes settle and is
    // flagged destructive for the permission layer.
    executionMode: 'sequential',
    isDestructive: true,
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<PatchDetails>> {
      const computer = await context.getComputer(signal)
      // `replace` is the default; only an explicit `mode: 'patch'` takes the V4A path.
      return (params.mode ?? 'replace') === 'patch'
        ? applyV4A(computer, params, signal)
        : applyReplace(computer, params, signal)
    }
  })
}

/**
 * Counts non-overlapping occurrences of `needle`. Used to enforce the uniqueness rule
 * in replace mode: 0 triggers the fuzzy fallback, 1 is the happy path, and >1 is
 * rejected unless `replace_all` is set. Advances past each hit by the needle's full
 * length so overlapping matches are not double-counted.
 */
function countOccurrences(haystack: string, needle: string): number {
  if (needle.length === 0) return 0
  let count = 0
  let index = haystack.indexOf(needle)
  while (index !== -1) {
    count++
    index = haystack.indexOf(needle, index + needle.length)
  }
  return count
}

/**
 * Reads a file's bytes into the matching-friendly form plus the metadata needed to
 * undo that transform on write. The dominant line ending wins (count CRLF vs bare LF)
 * so a file that is mostly one style is rewritten in that style; the LF lookbehind
 * keeps the two counts from both claiming the same `\n`.
 */
function snapshotTextFile(buffer: Buffer): TextFileSnapshot {
  const raw = buffer.toString('utf-8')
  const hasBom = raw.charCodeAt(0) === 0xfeff
  const content = hasBom ? raw.slice(1) : raw
  const crlf = (content.match(/\r\n/g) ?? []).length
  const lf = (content.match(/(?<!\r)\n/g) ?? []).length
  return {
    hasBom,
    lineEnding: crlf > lf ? '\r\n' : '\n',
    normalized: content.replace(/\r\n/g, '\n')
  }
}

/** Re-applies the original line ending and BOM to edited (normalized) content before writing. */
function restoreTextFile(snapshot: Pick<TextFileSnapshot, 'hasBom' | 'lineEnding'>, normalized: string): string {
  const content = snapshot.lineEnding === '\r\n' ? normalized.replace(/\n/g, '\r\n') : normalized
  return snapshot.hasBom ? `\ufeff${content}` : content
}

/** Splices `replacement` into `source` over the half-open range [start, end). */
function replaceRange(source: string, start: number, end: number, replacement: string): string {
  return source.slice(0, start) + replacement + source.slice(end)
}

/**
 * Replace mode: swap a single occurrence of `old_string` (or all of them with
 * `replace_all`). The contract the model is held to is uniqueness — an edit only
 * applies when its target is unambiguous — which is what makes single-string editing
 * safe without line numbers.
 */
async function applyReplace(
  computer: Computer,
  params: PatchInput,
  signal: AbortSignal | undefined
): Promise<AgentToolResult<PatchDetails>> {
  if (!params.path || params.old_string === undefined || params.new_string === undefined) {
    throw new Error('replace mode requires path, old_string, and new_string')
  }
  const cwd = patchCwd(params)
  const buffer = await computer.readFileToBuffer({ path: params.path, cwd }, { signal })
  if (!buffer) throw new Error(`File not found: ${params.path}`)

  const snapshot = snapshotTextFile(buffer)
  const original = snapshot.normalized
  // Normalize the model's strings to LF too, so matching compares like with like
  // regardless of the file's stored line ending.
  const needle = params.old_string.replace(/\r\n/g, '\n')
  const replacement = params.new_string.replace(/\r\n/g, '\n')

  const occurrences = countOccurrences(original, needle)
  // Only reach for fuzzy matching when an exact match found nothing AND we are doing a
  // single replace. With `replace_all` an exact-zero result is just "nothing to do",
  // and fuzzy matching has no meaning for a bulk swap.
  const fuzzyMatch = occurrences === 0 && !params.replace_all ? findUniqueFuzzyMatch(original, needle) : undefined
  if (occurrences === 0 && !fuzzyMatch) {
    throw new Error(`Could not find old_string in ${params.path}.`)
  }
  // More than one exact hit and no `replace_all`: ambiguous. Fail loudly and tell the
  // model how to fix it (more context, or opt into replace_all) instead of guessing.
  if (occurrences > 1 && !params.replace_all) {
    throw new Error(
      `old_string is not unique in ${params.path} (${occurrences} matches); add context or set replace_all.`
    )
  }

  let updated: string
  if (params.replace_all) {
    // split/join replaces every occurrence without regex escaping concerns.
    updated = original.split(needle).join(replacement)
  } else {
    // Single replace. Prefer the fuzzy match already computed above; recompute only on
    // the exact-match path (where `fuzzyMatch` was never attempted). For a unique exact
    // hit this resolves to that same span.
    const match = fuzzyMatch ?? findUniqueFuzzyMatch(original, needle)
    if (!match) throw new Error(`old_string is not unique enough for fuzzy matching in ${params.path}.`)
    updated = replaceRange(original, match.start, match.end, replacement)
  }

  const target = splitWritePath(params.path, cwd)
  await computer.fs.writeFiles([{ path: target.relative, content: restoreTextFile(snapshot, updated) }], {
    cwd: target.cwd,
    signal
  })

  // Report how many were changed (all of them for replace_all, otherwise exactly one)
  // and show the edit as a diff the user can scan.
  const count = params.replace_all ? occurrences : 1
  const diff = unifiedDiff(original, updated, params.path)
  return {
    content: [
      { type: 'text', text: `Patched ${params.path} (${count} replacement${count === 1 ? '' : 's'}).\n${diff}` }
    ],
    details: { mode: 'replace', filesModified: [params.path] }
  }
}

/** One fully-resolved file write, with both sides kept so the diff can be rendered after. */
interface PlannedWrite {
  path: string
  relative: string
  cwd: string
  snapshot: Pick<TextFileSnapshot, 'hasBom' | 'lineEnding'>
  before: string
  after: string
}

/**
 * Patch mode: apply a parsed V4A envelope across one or more files.
 *
 * Runs in two phases so the batch is closer to all-or-nothing. Phase 1 reads every
 * file and computes its new content, throwing on the first hunk that fails to match;
 * only if all of that succeeds does phase 2 start writing. This keeps a typo in the
 * third file's hunk from leaving the first two already overwritten. It is not a true
 * transaction (writes in phase 2 are not rolled back if one mid-way fails), but a
 * failure there is unlikely because matching already passed — a deliberately simpler
 * design than staging a real rollback.
 */
async function applyV4A(
  computer: Computer,
  params: PatchInput,
  signal: AbortSignal | undefined
): Promise<AgentToolResult<PatchDetails>> {
  if (!params.patch) throw new Error("patch mode requires 'patch'")
  const operations = parseV4APatch(params.patch)
  if (operations.length === 0) throw new Error('no operations parsed from patch')
  const cwd = patchCwd(params)

  // Phase 1: validate every operation and compute the new file contents up-front.
  const writes: PlannedWrite[] = []
  for (const operation of operations) {
    // Delete/Move are parsed but not executable here: the worker has no file-delete
    // API in v1, so refuse them explicitly rather than silently dropping the operation.
    if (operation.kind === 'delete' || operation.kind === 'move') {
      throw new Error(`V4A ${operation.kind} is not supported in this computer version (no file delete API)`)
    }
    const target = splitWritePath(operation.path, cwd)
    if (operation.kind === 'add') {
      // New file: no existing bytes to preserve, so assume LF and no BOM, and treat the
      // whole hunk content as the file body.
      writes.push({
        path: operation.path,
        relative: target.relative,
        cwd: target.cwd,
        snapshot: { hasBom: false, lineEnding: '\n' },
        before: '',
        after: operation.content.replace(/\r\n/g, '\n')
      })
      continue
    }
    const buffer = await computer.readFileToBuffer({ path: operation.path, cwd }, { signal })
    if (!buffer) throw new Error(`File not found: ${operation.path}`)
    const snapshot = snapshotTextFile(buffer)
    let after = snapshot.normalized
    const before = after
    // Apply the file's hunks in order against the running `after`. Each hunk is located
    // by its context (fuzzy match), then spliced in; locating against the already-edited
    // text means earlier hunks correctly shift the offsets seen by later ones. A hunk
    // that does not match uniquely aborts the whole patch (still phase 1, nothing written).
    for (const hunk of operation.hunks) {
      const search = hunk.search.replace(/\r\n/g, '\n')
      const replacement = hunk.replace.replace(/\r\n/g, '\n')
      const match = findUniqueFuzzyMatch(after, search)
      if (!match) throw new Error(`patch hunk did not match uniquely in ${operation.path}`)
      after = replaceRange(after, match.start, match.end, replacement)
    }
    writes.push({ path: operation.path, relative: target.relative, cwd: target.cwd, snapshot, before, after })
  }

  // Phase 2: apply (validation already passed, so partial failure is unlikely).
  const diffs: string[] = []
  for (const write of writes) {
    // Re-attach each file's original BOM/line ending on the way out, then emit its diff.
    await computer.fs.writeFiles([{ path: write.relative, content: restoreTextFile(write.snapshot, write.after) }], {
      cwd: write.cwd,
      signal
    })
    diffs.push(unifiedDiff(write.before, write.after, write.path))
  }
  return {
    content: [{ type: 'text', text: `Applied V4A patch to ${writes.length} file(s):\n\n${diffs.join('\n\n')}` }],
    details: { mode: 'patch', filesModified: writes.map(write => write.path) }
  }
}

/** Resolves the base directory, accepting `workdir` as an alias for `cwd` (command-tool parity). */
function patchCwd(params: Pick<PatchInput, 'cwd' | 'workdir'>): string | undefined {
  return params.cwd ?? params.workdir
}
