import { chmod, readFile, rm, rmdir, stat } from 'node:fs/promises'
import { writeFileAtomic } from '../common/atomic-write'
import { mkdirAgent } from '../common/agent-user'
import { dirname, join, relative } from 'node:path'
import { type Drive, type DriveFile, joinDrivePath, sha256File } from './drive'

/**
 * Keeps one local directory in step with one drive folder.
 *
 * A local index records, for every file that the drive and the directory
 * share, its digest and the size and mtime it had on disk. A file whose size
 * and mtime still match its index entry is not hashed again.
 *
 */

type IndexEntry = { sha256: string; size: number; mtimeMs: number }
type FolderIndex = { version: 1; files: Record<string, IndexEntry> }

type MaterializeResult = { downloaded: number; removed: number }

/**
 * Downloads changed files of a drive folder into `localDir` and removes local
 * files that the drive no longer has. `indexPath` must not lie under a path
 * that the drive folder names.
 */
export async function materializeFolder(
  drive: Drive,
  prefix: string,
  localDir: string,
  indexPath: string
): Promise<MaterializeResult> {
  const files = await drive.list(prefix)
  const index = await readIndex(indexPath)
  const remote = new Map(filesInside(prefix, files))
  const removed = await removeDeletedFiles(localDir, indexPath, index, remote)
  const next: FolderIndex = { version: 1, files: {} }
  let downloaded = 0

  for (const [relativePath, file] of remote) {
    const localPath = join(localDir, relativePath)
    const current = await currentEntry(localPath, index.files[relativePath])
    let materialized = file

    if (current?.sha256 !== file.sha256) {
      await mkdirAgent(dirname(localPath))
      materialized = await drive.get(file.path, localPath)
      await assertListedContent(file, materialized, localPath)
      downloaded += 1
    }
    const onDisk = await stat(localPath)
    if ((onDisk.mode & 0o777) !== materialized.mode) await chmod(localPath, materialized.mode)
    next.files[relativePath] = { sha256: materialized.sha256, size: onDisk.size, mtimeMs: onDisk.mtimeMs }
  }

  await writeIndex(indexPath, next)
  return { downloaded, removed }
}

/**
 * Writes every file of a drive folder into an empty local directory. Unlike
 * `materializeFolder`, it keeps no index: the caller owns and removes the
 * directory.
 */
export async function downloadFolder(drive: Drive, prefix: string, localDir: string): Promise<DriveFile[]> {
  const files = filesInside(prefix, await drive.list(prefix))
  for (const [relativePath, file] of files) {
    const localPath = join(localDir, relativePath)
    await mkdirAgent(dirname(localPath))
    const materialized = await drive.get(file.path, localPath)
    await assertListedContent(file, materialized, localPath)
  }
  return files.map(([, file]) => file)
}

async function assertListedContent(listed: DriveFile, downloaded: DriveFile, localPath: string): Promise<void> {
  if (
    downloaded.sha256 !== listed.sha256 ||
    downloaded.mode !== listed.mode ||
    downloaded.size !== listed.size ||
    (await sha256File(localPath)) !== listed.sha256
  ) {
    throw new Error(`drive folder changed during download: ${listed.path}; retry preparation`)
  }
}

/** Removes old indexed files before a drive path changes between a file and a folder. */
async function removeDeletedFiles(
  localDir: string,
  indexPath: string,
  index: FolderIndex,
  remote: ReadonlyMap<string, DriveFile>
): Promise<number> {
  let removed = 0
  for (const relativePath of Object.keys(index.files)) {
    if (remote.has(relativePath)) continue
    await rm(join(localDir, relativePath), { force: true })
    await removeEmptyParents(join(localDir, relativePath), localDir)
    delete index.files[relativePath]
    removed += 1
  }

  // Record removals before downloads. A failed download may leave a new
  // directory where the old index still named a file.
  if (removed > 0) await writeIndex(indexPath, index)
  return removed
}

async function currentEntry(localPath: string, indexed: IndexEntry | undefined): Promise<IndexEntry | undefined> {
  let onDisk
  try {
    onDisk = await stat(localPath)
  } catch {
    return undefined
  }
  if (!onDisk.isFile()) return undefined
  if (indexed && indexed.size === onDisk.size && indexed.mtimeMs === onDisk.mtimeMs) return indexed
  return { sha256: await sha256File(localPath), size: onDisk.size, mtimeMs: onDisk.mtimeMs }
}

function folderRelativePath(prefix: string, path: string): string {
  if (prefix === '') return path
  const folder = `${joinDrivePath(prefix)}/`
  if (!path.startsWith(folder)) throw new Error(`drive file ${path} is outside folder ${prefix}`)
  return path.slice(folder.length)
}

function filesInside(prefix: string, files: DriveFile[]): Array<[string, DriveFile]> {
  return files.map(file => [folderRelativePath(prefix, file.path), file])
}

async function readIndex(indexPath: string): Promise<FolderIndex> {
  try {
    const parsed = JSON.parse(await readFile(indexPath, 'utf8')) as Partial<FolderIndex>
    if (parsed.version === 1 && parsed.files && typeof parsed.files === 'object') {
      return { version: 1, files: parsed.files }
    }
  } catch {
    // A missing or unreadable index means nothing is known to be in step.
  }
  return { version: 1, files: {} }
}

async function writeIndex(indexPath: string, index: FolderIndex): Promise<void> {
  await mkdirAgent(dirname(indexPath))
  await writeFileAtomic(indexPath, JSON.stringify(index), 0o600)
}

async function removeEmptyParents(path: string, stopAt: string): Promise<void> {
  let current = dirname(path)
  while (relative(stopAt, current) !== '' && !relative(stopAt, current).startsWith('..')) {
    try {
      await rmdir(current)
    } catch {
      return
    }
    current = dirname(current)
  }
}
