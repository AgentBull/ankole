import { compareCodePointStrings } from '../../../common/ordering'
import { ms } from '@agentbull/active-support'
import { stat } from 'node:fs/promises'
import { join } from 'node:path'

/** Relative file path to its size and modification time. */
export type WorkspaceSnapshot = Map<string, { size: number; mtimeMs: number }>

export type WorkspaceSnapshotOutcome = { files: WorkspaceSnapshot } | { skipped: 'too_many_files' | 'time_limit' }

export type WorkspaceSnapshotBounds = {
  /** Above this file count the snapshot does not describe the workspace. */
  maxEntries?: number
  /** Above this scan time the snapshot would delay the Job result. */
  timeBudgetMs?: number
}

/**
 * Directory names, at any depth, that hold runtime state, scratch files,
 * dependencies, or build output rather than Job deliverables.
 */
const excludedDirectoryNames = new Set([
  '.codex',
  '.ankole',
  '.git',
  '.venv',
  '__pycache__',
  'browser',
  'build',
  'dist',
  'node_modules',
  'target',
  'temp',
  'venv'
])

/** Files the runtime writes at the workspace root. */
const excludedRootFiles = new Set(['AGENTS.md'])

const defaultMaxEntries = 50_000
const defaultTimeBudgetMs = ms('2s')
/** Concurrent stat calls; keeps the event loop free for app-server traffic. */
const statBatchSize = 64

/** Records every regular file in the Job Workspace within the given bounds. */
export async function snapshotWorkspace(
  root: string,
  bounds: WorkspaceSnapshotBounds = {}
): Promise<WorkspaceSnapshotOutcome> {
  const maxEntries = bounds.maxEntries ?? defaultMaxEntries
  const deadline = Date.now() + (bounds.timeBudgetMs ?? defaultTimeBudgetMs)
  const files: WorkspaceSnapshot = new Map()
  const glob = new Bun.Glob('**/*')
  let batch: string[] = []

  const statBatch = async (): Promise<void> => {
    const paths = batch
    batch = []
    const stats = await Promise.all(paths.map(path => stat(join(root, path)).catch(() => undefined)))
    for (const [index, entry] of stats.entries()) {
      // A file that left between the directory listing and the stat is skipped.
      if (entry?.isFile()) files.set(paths[index]!, { size: entry.size, mtimeMs: entry.mtimeMs })
    }
  }

  for await (const path of glob.scan({ cwd: root, dot: true, onlyFiles: true, followSymlinks: false })) {
    if (excludedWorkspacePath(path)) continue
    if (files.size + batch.length >= maxEntries) return { skipped: 'too_many_files' }
    batch.push(path)
    if (batch.length < statBatchSize) continue
    await statBatch()
    if (Date.now() > deadline) return { skipped: 'time_limit' }
  }
  await statBatch()
  if (Date.now() > deadline) return { skipped: 'time_limit' }
  return { files }
}

function excludedWorkspacePath(path: string): boolean {
  const segments = path.split('/')
  if (segments.length === 1) return excludedRootFiles.has(path)
  return segments.slice(0, -1).some(segment => excludedDirectoryNames.has(segment))
}

/** Relative paths added, changed, or removed between two snapshots, sorted. */
export function changedWorkspacePaths(before: WorkspaceSnapshot, after: WorkspaceSnapshot): string[] {
  const changed: string[] = []
  for (const [path, entry] of after) {
    const previous = before.get(path)
    if (!previous || previous.size !== entry.size || previous.mtimeMs !== entry.mtimeMs) changed.push(path)
  }
  for (const path of before.keys()) {
    if (!after.has(path)) changed.push(path)
  }
  return changed.sort(compareCodePointStrings)
}
