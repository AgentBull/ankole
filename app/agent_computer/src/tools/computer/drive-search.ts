import { workspacePath } from './commands'
import { dirname } from 'node:path'
import { scopedPath, visibleDrivePath } from '../../drive/paths'
import type { ComputerToolContext } from './context'
import { MAX_OUTPUT_CHARS } from './format'

const SEARCH_TIMEOUT_MS = 15_000

/** Drive searches run in a cancellable child in the same view as shell tools.
 * The workspace's native synchronous index never receives a FUSE path. */
export async function searchDrive(
  context: ComputerToolContext,
  kind: 'find' | 'grep',
  params: {
    path?: string
    pattern?: string
    exclude?: string | string[]
    limit?: number
    context?: number
    caseSensitive?: boolean
    cursor?: string
  },
  signal?: AbortSignal
) {
  if (!context.driveView) return undefined
  const raw = params.path?.trim() || '.'
  const expanded = workspacePath(context.agentHome, context.workspaceRoot, raw)
  const firstGlob = expanded.search(/[*?[{]/)
  const prefix = firstGlob < 0 ? expanded : dirname(`${expanded.slice(0, firstGlob)}_`)
  const canonical = await scopedPath(
    context.driveView,
    context.agentHome,
    prefix,
    signal ? AbortSignal.any([signal, AbortSignal.timeout(15_000)]) : undefined
  )
  const visible = visibleDrivePath(context.driveView, canonical)
  if (visible !== '/drive' && !visible.startsWith('/drive/')) return undefined
  if (params.cursor) throw new Error('Drive searches do not use cursors; narrow the path or pattern.')
  const args =
    kind === 'find'
      ? ['--files', '--hidden', '--follow']
      : [
          '--line-number',
          '--hidden',
          '--follow',
          '--max-count',
          String(params.limit ?? 30),
          params.caseSensitive ? '--case-sensitive' : '--smart-case'
        ]
  if (kind === 'grep') args.push('--context', String(params.context ?? 0))
  if (firstGlob >= 0) args.push('--glob', expanded.slice(prefix.length + 1))
  const excludes = Array.isArray(params.exclude) ? params.exclude : (params.exclude?.split(/[\s,]+/) ?? [])
  for (const exclude of excludes) args.push('--glob', `!${exclude}`)
  if (kind === 'grep') args.push('--', params.pattern ?? '', visible)
  else args.push('--', visible)
  const startedAt = Date.now()
  const result = await context.computer.runCommand({ cmd: 'rg', args, signal, timeoutMs: SEARCH_TIMEOUT_MS })
  // rg exits 2 when some path could not be read. The command wrapper exits 124
  // at the time limit, or 137 when it had to escalate to KILL; 137 also follows
  // any outside KILL, so only a run that used up the limit counts as a timeout.
  // The matches printed before that are real, so they return with a note. A
  // cancelled search, or one that failed before printing a match, still fails.
  const stdout = (await result.output('stdout')).trimEnd()
  if (signal?.aborted || (result.exitCode > 1 && !stdout)) throw new Error(await result.output('both'))
  const timedOut =
    result.exitCode === 124 || (result.exitCode === 137 && Date.now() - startedAt >= SEARCH_TIMEOUT_MS - 1000)
  const stderr = (await result.output('stderr')).trim().split('\n')[0]
  const note = timedOut
    ? `\n[Search stopped at the ${SEARCH_TIMEOUT_MS / 1000} s limit; narrow the path or pattern for complete results.]`
    : result.exitCode > 1
      ? `\n[Some paths could not be searched: ${stderr || `rg exited with code ${result.exitCode}`}]`
      : ''
  let lines = stdout.split('\n').filter(Boolean)
  if (kind === 'find' && params.pattern) {
    const patterns = params.pattern.split(/\s+/)
    lines = lines.filter(line =>
      patterns.every(pattern =>
        /[*?[{]/.test(pattern)
          ? new Bun.Glob(pattern.includes('/') ? pattern : `**/${pattern}`).match(line.slice(visible.length + 1))
          : line.toLowerCase().includes(pattern.toLowerCase())
      )
    )
  }
  const total = lines.length
  const limit = params.limit ?? 30
  const text = lines.slice(0, limit).join('\n').slice(0, MAX_OUTPUT_CHARS)
  const truncated = total > limit || result.outputCapture?.droppedBytes
  return {
    content: [
      {
        type: 'text' as const,
        text: (text || 'No matches found') + (truncated ? '\n[Output limited; narrow the path or pattern.]' : '') + note
      }
    ],
    details: { totalMatched: total, totalFiles: total, totalFilesSearched: total }
  }
}
