/**
 * The `replace` and `patch` tools edit files through the same file-safety
 * machinery (BOM/line-ending preservation, fuzzy matching, unified-diff output):
 *
 *  - `replace`: find one string and swap it. Simple and unambiguous, the everyday path.
 *  - `patch`: apply a multi-file V4A (`apply_patch`) envelope. Used when the model
 *    wants to express several edits, or edits across files, in one call.
 *
 * Why a dedicated tool instead of letting the model run sed/awk edits? Those are
 * easy to get subtly wrong (escaping, in-place flags, encoding) and produce no review
 * artifact. This tool matches against the real file, refuses ambiguous edits, and
 * returns a unified diff the user can read.
 */

import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import { compactActivityPath } from '../activity-summary'
import type { ContainerComputer } from './computer'
import type { ComputerToolContext } from './context'
import { unifiedDiff } from './diff'
import { splitWritePath } from './format'
import { findClosestLineMatches, findScopedFuzzyMatch, findUniqueFuzzyMatch } from './fuzzy-match'
import { parseV4APatch } from './v4a'

const MaxReplaceTextCharacters = 96 * 1024
const MaxPatchTextCharacters = 192 * 1024

const WorkingDirectoryParams = {
  cwd: z.string().max(4096).optional().describe('Base directory for relative paths (default current workspace).'),
  workdir: z.string().max(4096).optional().describe('Alias for cwd, matching command tool terminology.')
}

const ReplaceParams = z
  .object({
    path: z.string().min(1).max(4096).describe('File to edit.'),
    old_string: z
      .string()
      .max(MaxReplaceTextCharacters)
      .describe("Exact text to find; use '' only to create a missing file."),
    new_string: z
      .string()
      .max(MaxReplaceTextCharacters)
      .describe('Replacement text; an empty string deletes the match.'),
    replace_all: z.boolean().optional().describe('Replace all occurrences instead of requiring a unique match.'),
    ...WorkingDirectoryParams
  })
  .strict()

const PatchParams = z
  .object({
    patch: z
      .string()
      .min(1)
      .max(MaxPatchTextCharacters)
      .describe('V4A patch envelope: *** Begin Patch, file operations, hunks, then *** End Patch.'),
    ...WorkingDirectoryParams
  })
  .strict()

type ReplaceInput = z.infer<typeof ReplaceParams>
type PatchInput = z.infer<typeof PatchParams>

interface PatchDetails {
  mode: string
  filesModified: string[]
}

const patchFailureCounts = new Map<string, number>()

/**
 * Marks a patch failure as a target-matching problem that can trigger repeated
 * failure guidance.
 */
class PatchMatchError extends Error {
  constructor(
    readonly path: string,
    message: string
  ) {
    super(message)
  }
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

/** Builds the narrow single-replacement tool bound to a run's computer session. */
export function createReplaceTool(context: ComputerToolContext): AgentTool<typeof ReplaceParams, PatchDetails> {
  return {
    name: 'replace',
    description:
      "Replace one precise string in one file and return a unified diff. Use this instead of sed/awk edits or echo/cat heredocs. old_string must match uniquely unless replace_all=true, so include surrounding context lines. Use new_string='' to delete the match. Use old_string='' only to create a file that does not exist. For multi-file or multi-site edits use patch. Relative paths resolve from cwd/workdir, defaulting to the current workspace.",
    schema: ReplaceParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: true,
    describeActivity: params => {
      const path = compactActivityPath(params.path)
      return path ? `更新文件：${path}` : '更新文件'
    },
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<PatchDetails>> {
      const computer = await context.getComputer(signal)
      try {
        const result = await applyReplace(
          computer,
          { ...params, cwd: patchCwd(params) ?? context.workspaceRoot },
          signal
        )
        resetPatchFailures(context.executionScopeID, result.details.filesModified)
        return result
      } catch (error) {
        if (error instanceof PatchMatchError) {
          throw new Error(recordPatchFailure(context.executionScopeID, error.path, error.message))
        }
        throw error
      }
    }
  }
}

/** Builds the strict V4A patch tool bound to a run's computer session. */
export function createPatchTool(context: ComputerToolContext): AgentTool<typeof PatchParams, PatchDetails> {
  return {
    name: 'patch',
    description:
      'Apply a V4A patch for multi-file, multi-site, or larger edits and return unified diffs. Pass only a patch envelope with *** Begin Patch / *** End Patch. For one precise replacement use replace. Relative paths resolve from cwd/workdir, defaulting to the current workspace.',
    schema: PatchParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: true,
    describeActivity: () => '更新文件',
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<PatchDetails>> {
      const computer = await context.getComputer(signal)
      try {
        const result = await applyV4A(computer, { ...params, cwd: patchCwd(params) ?? context.workspaceRoot }, signal)
        resetPatchFailures(context.executionScopeID, result.details.filesModified)
        return result
      } catch (error) {
        if (error instanceof PatchMatchError) {
          throw new Error(recordPatchFailure(context.executionScopeID, error.path, error.message))
        }
        throw error
      }
    }
  }
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
  computer: ContainerComputer,
  params: ReplaceInput,
  signal: AbortSignal | undefined
): Promise<AgentToolResult<PatchDetails>> {
  const cwd = patchCwd(params)
  const buffer = await computer.readFileToBuffer({ path: params.path, cwd }, { signal })
  const needle = params.old_string.replace(/\r\n/g, '\n')
  const replacement = params.new_string.replace(/\r\n/g, '\n')
  if (!buffer) {
    if (needle.length !== 0) throw new Error(`File not found: ${params.path}`)
    const target = splitWritePath(params.path, cwd)
    await computer.fs.writeFiles(
      [{ path: target.relative, content: restoreTextFile({ hasBom: false, lineEnding: '\n' }, replacement) }],
      { cwd: target.cwd, signal }
    )
    const diff = await unifiedDiff('', replacement, params.path)
    return {
      content: [{ type: 'text', text: `Created ${params.path}.\n${diff}` }],
      details: { mode: 'replace', filesModified: [params.path] }
    }
  }

  const snapshot = snapshotTextFile(buffer)
  const original = snapshot.normalized
  if (needle.length === 0) {
    throw new Error(`old_string='' is only valid for creating a missing file; ${params.path} already exists.`)
  }

  const occurrences = countOccurrences(original, needle)
  // Only reach for fuzzy matching when an exact match found nothing AND we are doing a
  // single replace. With `replace_all` an exact-zero result is just "nothing to do",
  // and fuzzy matching has no meaning for a bulk swap.
  const fuzzyMatch = occurrences === 0 && !params.replace_all ? findUniqueFuzzyMatch(original, needle) : undefined
  if (occurrences === 0 && !fuzzyMatch) {
    throw new PatchMatchError(params.path, formatNoMatchError('old_string', params.path, original, needle))
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
  const diff = await unifiedDiff(original, updated, params.path)
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
  computer: ContainerComputer,
  params: PatchInput,
  signal: AbortSignal | undefined
): Promise<AgentToolResult<PatchDetails>> {
  const operations = parseV4APatch(params.patch)
  if (operations.length === 0) throw new Error('no operations parsed from patch')
  const cwd = patchCwd(params)

  // Phase 1: validate every operation and compute the new file contents up-front.
  const writes: PlannedWrite[] = []
  for (const operation of operations) {
    // Delete and rename are parsed but not executable here: the worker has no
    // file-delete or file-move API in v1, so refuse them explicitly rather than
    // silently dropping the operation.
    if (operation.kind === 'delete') {
      throw new Error('V4A delete is not supported in this computer version (no file delete API)')
    }
    if (operation.kind === 'update' && operation.moveTo !== undefined) {
      throw new Error('V4A "*** Move to:" is not supported in this computer version (no file move API)')
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
    let cursor = 0
    for (const hunk of operation.hunks) {
      const search = hunk.search.replace(/\r\n/g, '\n')
      const replacement = hunk.replace.replace(/\r\n/g, '\n')
      const match = findScopedFuzzyMatch(after, search, {
        context: hunk.context,
        endOfFile: hunk.endOfFile,
        start: cursor
      })
      if (!match) {
        throw new PatchMatchError(operation.path, formatNoMatchError('patch hunk', operation.path, after, search))
      }
      const scopedReplacement = formatScopedReplacement(after, match.start, match.end, replacement)
      after = replaceRange(after, match.start, match.end, scopedReplacement)
      cursor = match.start + scopedReplacement.length
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
    diffs.push(await unifiedDiff(write.before, write.after, write.path))
  }
  return {
    content: [{ type: 'text', text: `Applied V4A patch to ${writes.length} file(s):\n\n${diffs.join('\n\n')}` }],
    details: { mode: 'patch', filesModified: writes.map(write => write.path) }
  }
}

/** Resolves the base directory, accepting `workdir` as an alias for `cwd` (command-tool parity). */
function patchCwd(params: Pick<ReplaceInput | PatchInput, 'cwd' | 'workdir'>): string | undefined {
  return params.cwd ?? params.workdir
}

/**
 * Builds the retry-counter key for patch failures in one execution scope.
 */
function patchFailureKey(scopeID: string, path: string): string {
  return `${scopeID}\0${path}`
}

/**
 * Clears repeated-failure counters after a successful edit.
 */
function resetPatchFailures(scopeID: string, paths: string[]): void {
  for (const path of paths) patchFailureCounts.delete(patchFailureKey(scopeID, path))
}

/**
 * Records a patch-match failure and escalates guidance after repeated misses.
 */
function recordPatchFailure(scopeID: string, path: string, message: string): string {
  const key = patchFailureKey(scopeID, path)
  const count = (patchFailureCounts.get(key) ?? 0) + 1
  patchFailureCounts.set(key, count)
  if (count < 3) return message
  return `${message}\nRepeated patch failures for ${path}: stop retrying small variants of the same target. Re-read the file with read_file, include longer unique context, or rewrite the whole file when that is simpler.`
}

/**
 * Adds line breaks around pure insertion replacements when needed.
 */
function formatScopedReplacement(source: string, start: number, end: number, replacement: string): string {
  if (start !== end || replacement.length === 0) return replacement
  const prefix = start > 0 && source[start - 1] !== '\n' ? '\n' : ''
  const suffix = start < source.length && !replacement.endsWith('\n') ? '\n' : ''
  return `${prefix}${replacement}${suffix}`
}

/**
 * Builds a no-match error with nearby line suggestions.
 */
function formatNoMatchError(kind: 'old_string' | 'patch hunk', path: string, content: string, needle: string): string {
  const lines = content.split('\n')
  if (lines.at(-1) === '') lines.pop()
  const closest = findClosestLineMatches(content, needle, { contextLines: 2, limit: 3 })
  const header =
    kind === 'old_string'
      ? `Could not find old_string in ${path} (${lines.length} lines).`
      : `patch hunk did not match in ${path} (${lines.length} lines).`
  if (closest.length === 0) {
    return `${header} Add more surrounding context or verify the current file with read_file.`
  }
  const snippets = closest
    .map((match, index) => {
      const body = match.snippet.map(line => `${line.lineNumber}|${line.text}`).join('\n')
      return `Closest match ${index + 1} near line ${match.lineNumber}:\n${body}`
    })
    .join('\n\n')
  return `${header} Did you mean one of these sections?\n${snippets}\nAdd more surrounding context or verify the current file with read_file.`
}
