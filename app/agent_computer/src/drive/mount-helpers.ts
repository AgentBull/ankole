import type { RcCall } from './rclone-control'

export type DriveWriteResult = { Path: string; NodeID: string; Failure: string; Recovery: string }
export type DriveFlushedFile = { path: string; nodeId: string }
export type DriveWriteError = { path: string; failure: string; recovery: string }
export type DriveFlushResult =
  | { status: 'flushed'; files: DriveFlushedFile[] }
  | {
      status: 'pending'
      paths: string[]
      files: DriveFlushedFile[]
      reason?: string
      flush_incomplete?: boolean
    }
  | { status: 'failed'; errors: DriveWriteError[]; files: DriveFlushedFile[] }

const statCheckConcurrency = 8

async function runBoundedConcurrency<T>(
  items: readonly T[],
  limit: number,
  worker: (item: T) => Promise<void>
): Promise<void> {
  if (items.length === 0) return
  let nextIndex = 0
  const workerCount = Math.min(limit, items.length)
  await Promise.all(
    Array.from({ length: workerCount }, async () => {
      while (nextIndex < items.length) {
        const index = nextIndex++
        await worker(items[index]!)
      }
    })
  )
}

export async function flushDriveMounts<TMount extends { key: string }>(input: {
  mounts: readonly TMount[]
  since: Map<string, number>
  rc: RcCall
  signal: AbortSignal
  visiblePathForMount: (mount: TMount, remote: string) => string
}): Promise<DriveFlushResult> {
  const { mounts, since, rc, signal, visiblePathForMount } = input
  const results = await Promise.all(
    mounts.map(async mount => {
      try {
        const response = await rc<{
          files?: DriveWriteResult[]
          background?: boolean
          pending_paths?: string[]
          reason?: string
        }>('ankole/flush', { fs: mount.key, since_seq: since.get(mount.key) ?? 0 }, signal)
        return { mount, response, flushIncomplete: false }
      } catch (error) {
        return {
          mount,
          response: {
            background: true,
            reason: error instanceof Error ? error.message : String(error)
          },
          flushIncomplete: true
        }
      }
    })
  )
  const files: DriveFlushedFile[] = []
  const errors: DriveWriteError[] = []
  const pendingPaths: string[] = []
  const reasons: string[] = []
  let flushIncomplete = false

  for (const { mount, response, flushIncomplete: mountFlushIncomplete } of results) {
    if (mountFlushIncomplete) flushIncomplete = true
    for (const file of response.files ?? []) {
      const visiblePath = visiblePathForMount(mount, file.Path)
      if (file.Failure) {
        errors.push({ path: visiblePath, failure: file.Failure, recovery: file.Recovery })
      } else if (file.NodeID) {
        files.push({ path: visiblePath, nodeId: file.NodeID })
      }
    }
    if (response.background) {
      if (response.pending_paths?.length) {
        for (const raw of response.pending_paths) {
          const visiblePath = raw.startsWith('/drive/') ? raw : visiblePathForMount(mount, raw)
          if (isConcreteDriveFilePath(visiblePath)) {
            pendingPaths.push(visiblePath)
          } else {
            flushIncomplete = true
          }
        }
      } else {
        flushIncomplete = true
      }
      if (response.reason) reasons.push(response.reason)
    }
  }

  if (errors.length > 0) return { status: 'failed', errors, files }
  if (pendingPaths.length > 0 || flushIncomplete) {
    return {
      status: 'pending',
      paths: [...new Set(pendingPaths)],
      files,
      ...(flushIncomplete ? { flush_incomplete: true } : {}),
      ...(reasons.length > 0 ? { reason: reasons.join('; ') } : {})
    }
  }
  return { status: 'flushed', files }
}

export async function flushDrivePathsByMount<TMount extends { key: string }>(input: {
  paths: readonly string[]
  scopeMount: TMount
  chatMount: TMount | undefined
  rc: RcCall
  signal: AbortSignal
}): Promise<{ flushed: string[]; pending: string[]; files: DriveFlushedFile[]; errors?: DriveWriteError[] }> {
  const { paths, scopeMount, chatMount, rc, signal } = input
  const uniquePaths = [...new Set(paths)].filter(isConcreteDriveFilePath)
  if (uniquePaths.length === 0) return { flushed: [], pending: [], files: [] }

  const grouped = new Map<TMount, Array<{ visiblePath: string; remote: string }>>()
  const pendingSet = new Set<string>()
  const flushedFiles = new Map<string, DriveFlushedFile>()
  const errors: DriveWriteError[] = []

  for (const visiblePath of uniquePaths) {
    const chat = visiblePath.startsWith('/drive/ChatDrive/')
    const mount = chat ? chatMount : scopeMount
    if (!mount) {
      pendingSet.add(visiblePath)
      continue
    }
    const remote = visiblePath.slice(chat ? '/drive/ChatDrive/'.length : '/drive/'.length)
    const list = grouped.get(mount)
    if (list) list.push({ visiblePath, remote })
    else grouped.set(mount, [{ visiblePath, remote }])
  }

  await Promise.all(
    [...grouped.entries()].map(async ([mount, entries]) => {
      let flushResults: DriveWriteResult[]
      try {
        const response = await rc<{ files?: DriveWriteResult[] }>(
          'ankole/flush-paths',
          { fs: mount.key, paths: entries.map(entry => entry.remote) },
          signal
        )
        flushResults = response.files ?? []
      } catch {
        for (const entry of entries) pendingSet.add(entry.visiblePath)
        return
      }

      const byRemote = new Map<string, DriveWriteResult>()
      for (const item of flushResults) byRemote.set(item.Path, item)

      const needsStat: Array<{ visiblePath: string; remote: string }> = []
      for (const entry of entries) {
        const item = byRemote.get(entry.remote)
        if (item?.Failure) {
          errors.push({ path: entry.visiblePath, failure: item.Failure, recovery: item.Recovery })
        } else if (item?.NodeID) {
          flushedFiles.set(entry.visiblePath, { path: entry.visiblePath, nodeId: item.NodeID })
        } else {
          needsStat.push(entry)
        }
      }

      await runBoundedConcurrency(needsStat, statCheckConcurrency, async entry => {
        try {
          const listing = await rc<{ item: { ID?: string } | null }>(
            'operations/stat',
            { fs: `${mount.key}:`, remote: entry.remote },
            signal
          )
          if (listing.item?.ID) {
            flushedFiles.set(entry.visiblePath, { path: entry.visiblePath, nodeId: listing.item.ID })
          } else {
            pendingSet.add(entry.visiblePath)
          }
        } catch {
          pendingSet.add(entry.visiblePath)
        }
      })
    })
  )

  const flushed: string[] = []
  const pending: string[] = []
  const files: DriveFlushedFile[] = []
  for (const visiblePath of uniquePaths) {
    const file = flushedFiles.get(visiblePath)
    if (file) {
      flushed.push(visiblePath)
      files.push(file)
    } else if (pendingSet.has(visiblePath)) {
      pending.push(visiblePath)
    }
  }

  return {
    flushed,
    pending,
    files,
    ...(errors.length > 0 ? { errors } : {})
  }
}

export function isConcreteDriveFilePath(path: string): boolean {
  if (!path.startsWith('/drive/')) return false
  if (path === '/drive/Library' || path.startsWith('/drive/Library/')) return false
  if (path === '/drive/ChatDrive' || path === '/drive/ChatDrive/') return false
  if (path.endsWith('/') || path.endsWith('/*')) return false
  const remainder = path.startsWith('/drive/ChatDrive/')
    ? path.slice('/drive/ChatDrive/'.length)
    : path.slice('/drive/'.length)
  return remainder.length > 0 && remainder !== '*'
}

export function formatDriveFlushSummary(result: DriveFlushResult): string {
  switch (result.status) {
    case 'flushed':
      return ''
    case 'pending': {
      const sample = result.paths.slice(0, 5).join(', ')
      const suffix = sample ? ` (${sample}${result.paths.length > 5 ? ', ...' : ''})` : ''
      return `Drive: uploads are still in flight${suffix}.`
    }
    case 'failed':
      return result.errors
        .map(err => `Drive write failed: ${err.path}: ${err.failure}; saved at ${err.recovery}`)
        .join('\n')
  }
}

export async function defaultLazyUnmount(mountPoint: string): Promise<void> {
  const proc = Bun.spawn(['umount', '-l', mountPoint], {
    stdin: 'ignore',
    stdout: 'ignore',
    stderr: 'ignore'
  })
  await proc.exited
}

export function defaultSpawnDaemon(socketPath: string, cacheDir: string): ReturnType<typeof Bun.spawn> {
  return Bun.spawn(
    [
      'ankole-rclone',
      'rcd',
      '--config',
      '/dev/null',
      '--rc-addr',
      socketPath,
      '--rc-no-auth',
      '--cache-dir',
      cacheDir,
      '--transfers',
      '4',
      '--low-level-retries',
      '1'
    ],
    {
      stdin: 'ignore',
      stdout: 'ignore',
      stderr: 'inherit',
      env: { PATH: process.env.PATH!, ANKOLE_WORKER_CACHE_CAPACITY: process.env.ANKOLE_WORKER_CACHE_CAPACITY }
    }
  )
}

/**
 * Extracts mount points matching `targetPath` (and optionally descendants) from Linux
 * `/proc/self/mountinfo` in reverse mount order so stacked and child mounts detach first.
 */
export function parseMountPointsUnder(mountinfo: string, targetPath: string, includeDescendants = true): string[] {
  const normalized = targetPath.replace(/\/+$/, '') || '/'
  const childPrefix = normalized === '/' ? '/' : `${normalized}/`
  const matches: string[] = []
  for (const line of mountinfo.split('\n')) {
    if (!line) continue
    const rawMountPoint = line.split(' ')[4]
    if (!rawMountPoint) continue
    const mountPoint = rawMountPoint.replace(/\\(040|011|012|134)/g, (_, code: string) => {
      if (code === '040') return ' '
      if (code === '011') return '\t'
      if (code === '012') return '\n'
      return '\\'
    })
    if (mountPoint === normalized || (includeDescendants && mountPoint.startsWith(childPrefix))) {
      matches.push(mountPoint)
    }
  }
  return matches.reverse()
}

export function waitForProcessExit(exited: Promise<unknown>, timeoutMs: number): Promise<boolean> {
  let timer: ReturnType<typeof setTimeout> | undefined
  return Promise.race([
    exited.then(
      () => true,
      () => true
    ),
    new Promise<boolean>(resolve => {
      timer = setTimeout(() => resolve(false), timeoutMs)
      timer.unref?.()
    })
  ]).finally(() => {
    if (timer) clearTimeout(timer)
  })
}
