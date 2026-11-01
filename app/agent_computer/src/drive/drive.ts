import { ms } from '@agentbull/active-support'
import type { Stats } from 'node:fs'
import { chmod, lstat, readdir, realpath, stat } from 'node:fs/promises'
import { dirname, join, relative, resolve } from 'node:path'
import { nodeErrorCode } from '../common/errors'
import type { AutomationAttemptRef } from '../fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { relativePathWithin } from '../core/path-boundary'
import { type RPCRequester, type TurnRPCFrame } from '../lanes/rpc_lane'

/**
 * Worker-side client for the Agent's drive in the control plane.
 *
 * The drive holds the files that other people see or receive and that the
 * control plane reads; the Agent Home keeps all other files of the Agent.
 * Bytes never travel in the RPC payload: `files.get` and
 * `files.commit` make the control plane move them over the WorkerFiles relay
 * of this Worker, naming each local file by its path inside the Agent Home.
 * The operations have `worker_agent` scope, so they also work while the
 * Worker drains and no Turn is active.
 */

export type DriveFile = {
  nodeId: string
  objectId: string
  path: string
  sha256: string
  size: number
  contentType: string
  source: string
  mode: number
  updatedAt: string
}

export type DriveUpsert = {
  /** Drive path to name. */
  path: string
  /** Absolute local file inside the Agent Home; every commit transfers its bytes. */
  localPath: string
  /** Optional checksum used only to verify the received bytes. */
  sha256?: string
  /** Size of the local file, checked by the control plane. */
  size?: number
  contentType?: string
  mode?: number
}

type LocalFile = { absolutePath: string; relativePath: string; mode: number; size: number }

/** Every transfer of one call runs on the control plane before the RPC returns. */
const transferTimeoutMs = ms('30m')
const listPageLimit = 1000
/** One put sends its files in one commit; a larger folder goes in parts. */
export const maxFilesPerPut = 1000
const maxDrivePathBytes = 1024
const maxSegmentBytes = 255

export class Drive {
  constructor(
    private readonly opts: {
      agentHome: string
      rpc: RPCRequester
      automationAttempt?: Omit<AutomationAttemptRef, '$typeName'>
    }
  ) {}

  get agentHome(): string {
    return this.opts.agentHome
  }

  /** Lists every drive file under a folder prefix, in path order. */
  async list(prefix = ''): Promise<DriveFile[]> {
    const files: DriveFile[] = []
    let after = ''
    let revision: string | undefined
    for (;;) {
      const page = await this.listPage(prefix, { limit: listPageLimit, after })
      if (!page.revision || (revision !== undefined && revision !== page.revision)) {
        throw new Error(`drive folder changed during listing: ${prefix}; retry preparation`)
      }
      revision = page.revision
      files.push(...page.files)
      if (!page.nextAfter) return files
      after = page.nextAfter
    }
  }

  async listPage(
    prefix: string,
    opts: { limit?: number; after?: string } = {}
  ): Promise<{ files: DriveFile[]; nextAfter: string; revision: string }> {
    const prefixPath = prefix === '' ? '' : assertDrivePath(prefix)
    const response = await this.opts.rpc(
      'files.list',
      {
        prefix: prefixPath,
        limit: opts.limit ?? listPageLimit,
        after: opts.after ?? '',
        automationAttempt: this.opts.automationAttempt
      },
      undefined,
      { retryOnDisconnect: true }
    )
    return { files: response.files.map(driveFileFromWire), nextAfter: response.nextAfter, revision: response.revision }
  }

  async get(
    path: string,
    localPath: string,
    opts: { node?: boolean; frame?: TurnRPCFrame; automationAttempt?: Omit<AutomationAttemptRef, '$typeName'> } = {}
  ): Promise<DriveFile> {
    const response = await this.opts.rpc(
      'files.get',
      {
        path: opts.node ? '' : assertDrivePath(path),
        homeRelativePath: await this.homeRelativePath(localPath, { create: true }),
        nodeId: opts.node ? path : '',
        automationAttempt: opts.automationAttempt ?? this.opts.automationAttempt
      },
      opts.frame,
      { timeoutMs: transferTimeoutMs, retryOnDisconnect: true }
    )
    if (!response.file) throw new Error(`files.get returned no file for ${path}`)
    const file = driveFileFromWire(response.file)
    await chmod(localPath, file.mode)
    return file
  }

  /** Names local files at drive paths and removes drive paths in one transaction. */
  async commit(upserts: DriveUpsert[], deletes: string[] = []): Promise<{ files: DriveFile[]; deleted: number }> {
    const wireUpserts = []
    for (const upsert of upserts) {
      const localPath = upsert.localPath
      wireUpserts.push({
        path: assertDrivePath(upsert.path),
        homeRelativePath: await this.homeRelativePath(localPath),
        sha256: upsert.sha256 ?? '',
        size: BigInt(upsert.size ?? (await stat(localPath)).size),
        contentType: upsert.contentType ?? '',
        mode: upsert.mode ?? 0
      })
    }
    const response = await this.opts.rpc(
      'files.commit',
      { upserts: wireUpserts, deletes: deletes.map(assertDrivePath), automationAttempt: this.opts.automationAttempt },
      undefined,
      { timeoutMs: transferTimeoutMs }
    )
    return { files: response.files.map(driveFileFromWire), deleted: response.deleted }
  }

  /** A file already at the same drive path is replaced; drive files that the local side does not have stay. */
  async put(localPath: string, drivePath: string): Promise<DriveFile[]> {
    const localFiles = await collectLocalFiles(localPath)
    if (localFiles.length === 0) throw new Error(`no regular files to put under ${localPath}`)
    if (localFiles.length > maxFilesPerPut) {
      throw new Error(
        `${localFiles.length} files is more than one put sends (${maxFilesPerPut}); put the folder in smaller parts`
      )
    }
    const upserts: DriveUpsert[] = []
    for (const file of localFiles) {
      upserts.push({
        path: file.relativePath === '' ? drivePath : joinDrivePath(drivePath, file.relativePath),
        localPath: file.absolutePath,
        size: file.size,
        mode: file.mode
      })
    }
    return (await this.commit(upserts)).files
  }

  /** Removes one drive path and every path under it. */
  async remove(path: string): Promise<number> {
    return (await this.commit([], [path])).deleted
  }

  async homeRelativePath(localPath: string, opts: { create?: boolean } = {}): Promise<string> {
    const home = await realpath(this.opts.agentHome)
    const absolute = resolve(localPath)
    let physical: string
    if (opts.create) {
      const ancestor = await nearestExistingDirectory(dirname(absolute))
      physical = join(await realpath(ancestor), relative(ancestor, absolute))
    } else {
      physical = await realpath(absolute)
    }
    const relativePath = relativePathWithin(home, physical)
    if (!relativePath) throw new Error(`path must be a file inside the Agent Home: ${localPath}`)
    return relativePath.split('\\').join('/')
  }
}

export async function sha256File(path: string): Promise<string> {
  const hasher = new Bun.CryptoHasher('sha256')
  const reader = Bun.file(path).stream().getReader()
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    hasher.update(value)
  }
  return hasher.digest('hex')
}

async function collectLocalFiles(localPath: string): Promise<LocalFile[]> {
  const root = resolve(localPath)
  const rootStat = await lstat(root)
  if (rootStat.isFile()) return [localFile(root, '', rootStat)]
  if (!rootStat.isDirectory()) throw new Error(`path is not a regular file or directory: ${localPath}`)

  const files: LocalFile[] = []
  const walk = async (dir: string, prefix: string): Promise<void> => {
    let entries
    try {
      entries = await readdir(dir, { withFileTypes: true })
    } catch (error) {
      if (prefix !== '' && disappeared(error)) return
      throw error
    }
    entries.sort((left, right) => left.name.localeCompare(right.name))
    for (const entry of entries) {
      const absolutePath = join(dir, entry.name)
      const relativePath = prefix === '' ? entry.name : `${prefix}/${entry.name}`
      if (entry.isDirectory()) {
        await walk(absolutePath, relativePath)
      } else if (entry.isFile()) {
        try {
          const fileStat = await lstat(absolutePath)
          if (fileStat.isFile()) files.push(localFile(absolutePath, relativePath, fileStat))
        } catch (error) {
          if (!disappeared(error)) throw error
        }
      }
    }
  }
  await walk(root, '')
  return files
}

function localFile(absolutePath: string, relativePath: string, fileStat: Stats): LocalFile {
  return { absolutePath, relativePath, mode: fileStat.mode & 0o777, size: fileStat.size }
}

function disappeared(error: unknown): boolean {
  const code = nodeErrorCode(error)
  return code === 'ENOENT' || code === 'ENOTDIR'
}

export function joinDrivePath(...parts: string[]): string {
  return parts
    .flatMap(part => part.split('/'))
    .filter(segment => segment !== '')
    .join('/')
}

/** Validates a drive path with the control plane's rules and returns it. */
export function assertDrivePath(path: string): string {
  if (!isDrivePath(path)) {
    // The caller is often a model: the message states the rule it broke.
    throw new Error(
      `invalid drive path ${JSON.stringify(path)}: a drive path is relative (no leading "/"), ` +
        `separates segments with "/", and has no empty, "." or ".." segment; ` +
        `it is at most ${maxDrivePathBytes} bytes, each segment at most ${maxSegmentBytes} bytes`
    )
  }
  return path
}

/** Whether the control plane accepts `path` as a drive path. */
export function isDrivePath(path: string): boolean {
  return (
    path.length > 0 &&
    Buffer.byteLength(path, 'utf8') <= maxDrivePathBytes &&
    !path.includes('\0') &&
    path
      .split('/')
      .every(
        segment =>
          segment !== '' && segment !== '.' && segment !== '..' && Buffer.byteLength(segment, 'utf8') <= maxSegmentBytes
      )
  )
}

function driveFileFromWire(file: {
  nodeId: string
  objectId: string
  path: string
  sha256: string
  size: bigint
  contentType: string
  source: string
  mode: number
  updatedAt: string
}): DriveFile {
  return {
    nodeId: file.nodeId,
    objectId: file.objectId,
    path: file.path,
    sha256: file.sha256,
    size: Number(file.size),
    contentType: file.contentType,
    source: file.source,
    mode: file.mode,
    updatedAt: file.updatedAt
  }
}

async function nearestExistingDirectory(path: string): Promise<string> {
  let current = path
  for (;;) {
    try {
      if ((await stat(current)).isDirectory()) return current
    } catch {
      // Walk up until an existing ancestor; the relay creates the rest.
    }
    const parent = dirname(current)
    if (parent === current) return current
    current = parent
  }
}
