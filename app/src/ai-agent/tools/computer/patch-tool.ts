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
  patch: z.string().optional().describe('V4A patch envelope (patch mode).'),
  cwd: z.string().optional().describe('Base directory for relative paths (default /workspace).')
})

type PatchInput = z.infer<typeof PatchParams>

interface PatchDetails {
  mode: string
  filesModified: string[]
}

interface TextFileSnapshot {
  hasBom: boolean
  lineEnding: '\n' | '\r\n'
  normalized: string
}

export function createPatchTool(context: ComputerToolContext): AgentTool<typeof PatchParams, PatchDetails> {
  return buildTool({
    name: 'patch',
    label: 'Patch',
    description:
      "Targeted edits to files in the computer. Use this instead of sed/awk. REPLACE MODE (default): find a unique old_string and replace it (set replace_all for all matches). PATCH MODE (mode='patch'): apply a V4A multi-file patch. Returns a unified diff.",
    schema: PatchParams,
    executionMode: 'sequential',
    isDestructive: true,
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<PatchDetails>> {
      const computer = await context.getComputer(signal)
      return (params.mode ?? 'replace') === 'patch'
        ? applyV4A(computer, params, signal)
        : applyReplace(computer, params, signal)
    }
  })
}

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

function restoreTextFile(snapshot: Pick<TextFileSnapshot, 'hasBom' | 'lineEnding'>, normalized: string): string {
  const content = snapshot.lineEnding === '\r\n' ? normalized.replace(/\n/g, '\r\n') : normalized
  return snapshot.hasBom ? `\ufeff${content}` : content
}

function replaceRange(source: string, start: number, end: number, replacement: string): string {
  return source.slice(0, start) + replacement + source.slice(end)
}

async function applyReplace(
  computer: Computer,
  params: PatchInput,
  signal: AbortSignal | undefined
): Promise<AgentToolResult<PatchDetails>> {
  if (!params.path || params.old_string === undefined || params.new_string === undefined) {
    throw new Error('replace mode requires path, old_string, and new_string')
  }
  const buffer = await computer.readFileToBuffer({ path: params.path, cwd: params.cwd }, { signal })
  if (!buffer) throw new Error(`File not found: ${params.path}`)

  const snapshot = snapshotTextFile(buffer)
  const original = snapshot.normalized
  const needle = params.old_string.replace(/\r\n/g, '\n')
  const replacement = params.new_string.replace(/\r\n/g, '\n')

  const occurrences = countOccurrences(original, needle)
  const fuzzyMatch = occurrences === 0 && !params.replace_all ? findUniqueFuzzyMatch(original, needle) : undefined
  if (occurrences === 0 && !fuzzyMatch) {
    throw new Error(`Could not find old_string in ${params.path}.`)
  }
  if (occurrences > 1 && !params.replace_all) {
    throw new Error(
      `old_string is not unique in ${params.path} (${occurrences} matches); add context or set replace_all.`
    )
  }

  let updated: string
  if (params.replace_all) {
    updated = original.split(needle).join(replacement)
  } else {
    const match = fuzzyMatch ?? findUniqueFuzzyMatch(original, needle)
    if (!match) throw new Error(`old_string is not unique enough for fuzzy matching in ${params.path}.`)
    updated = replaceRange(original, match.start, match.end, replacement)
  }

  const { relative, cwd } = splitWritePath(params.path, params.cwd)
  await computer.fs.writeFiles([{ path: relative, content: restoreTextFile(snapshot, updated) }], { cwd, signal })

  const count = params.replace_all ? occurrences : 1
  const diff = unifiedDiff(original, updated, params.path)
  return {
    content: [
      { type: 'text', text: `Patched ${params.path} (${count} replacement${count === 1 ? '' : 's'}).\n${diff}` }
    ],
    details: { mode: 'replace', filesModified: [params.path] }
  }
}

interface PlannedWrite {
  path: string
  relative: string
  cwd: string
  snapshot: Pick<TextFileSnapshot, 'hasBom' | 'lineEnding'>
  before: string
  after: string
}

async function applyV4A(
  computer: Computer,
  params: PatchInput,
  signal: AbortSignal | undefined
): Promise<AgentToolResult<PatchDetails>> {
  if (!params.patch) throw new Error("patch mode requires 'patch'")
  const operations = parseV4APatch(params.patch)
  if (operations.length === 0) throw new Error('no operations parsed from patch')

  // Phase 1: validate every operation and compute the new file contents up-front.
  const writes: PlannedWrite[] = []
  for (const operation of operations) {
    if (operation.kind === 'delete' || operation.kind === 'move') {
      throw new Error(`V4A ${operation.kind} is not supported in this computer version (no file delete API)`)
    }
    const { relative, cwd } = splitWritePath(operation.path, params.cwd)
    if (operation.kind === 'add') {
      writes.push({
        path: operation.path,
        relative,
        cwd,
        snapshot: { hasBom: false, lineEnding: '\n' },
        before: '',
        after: operation.content.replace(/\r\n/g, '\n')
      })
      continue
    }
    const buffer = await computer.readFileToBuffer({ path: operation.path, cwd: params.cwd }, { signal })
    if (!buffer) throw new Error(`File not found: ${operation.path}`)
    const snapshot = snapshotTextFile(buffer)
    let after = snapshot.normalized
    const before = after
    for (const hunk of operation.hunks) {
      const search = hunk.search.replace(/\r\n/g, '\n')
      const replacement = hunk.replace.replace(/\r\n/g, '\n')
      const match = findUniqueFuzzyMatch(after, search)
      if (!match) throw new Error(`patch hunk did not match uniquely in ${operation.path}`)
      after = replaceRange(after, match.start, match.end, replacement)
    }
    writes.push({ path: operation.path, relative, cwd, snapshot, before, after })
  }

  // Phase 2: apply (validation already passed, so partial failure is unlikely).
  const diffs: string[] = []
  for (const write of writes) {
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
