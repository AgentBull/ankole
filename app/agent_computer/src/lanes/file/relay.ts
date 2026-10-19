import { mkdirSync, rmSync, statSync } from 'node:fs'
import type { Stats } from 'node:fs'
import { copyFile, open, rename } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { FileTransferError } from './errors'
import {
  assertCreatableHomePath,
  assertExistingHomePath,
  homePath,
  safeTransferID,
  scratchDirectoryFor
} from './path-security'
import type { AgentHomeConfig } from '../../worker/config'
import { errorMessage, nodeErrorCode } from '../../common/errors'
import { chownAgentPath, mkdirAgentSync } from '../../common/agent-user'

/**
 * One relay transfer as the control plane requests it. `homeRelativePath`
 * names a path inside the bound Agent's Home. `url` is a one-time signed
 * bearer credential on the issuing control-plane Pod: it is used for exactly
 * one HTTP request and never written to logs or errors.
 */
export type RelayTransferRequest = {
  transferId: string
  url: string
  homeRelativePath: string
  maxBytes: bigint
}

export type RelayTransferResult = { size: number }

/**
 * Pulls one file from the relay URL into the Agent Home.
 *
 * Bytes stream into the transfer scratch directory and reach the target path
 * only through an atomic rename, so a failed or oversize pull never leaves a
 * partial file where the Agent can read it.
 */
export async function pullFile(
  config: AgentHomeConfig,
  request: RelayTransferRequest,
  signal?: AbortSignal
): Promise<RelayTransferResult> {
  signal?.throwIfAborted()
  const transferID = safeTransferID(request.transferId)
  const maxBytes = boundedByteCount(request.maxBytes)
  const targetPath = assertCreatableHomePath(
    config,
    homePath(config, request.homeRelativePath),
    request.homeRelativePath
  )
  const tempDir = scratchDirectoryFor(transferID)
  const decodedPath = join(tempDir, 'decoded')
  const finalTempPath = `${targetPath}.ankole-transfer-${transferID}.tmp`

  rmSync(tempDir, { recursive: true, force: true })
  mkdirSync(tempDir, { recursive: true })

  try {
    await downloadToFile(request.url, decodedPath, maxBytes, signal)
    signal?.throwIfAborted()

    mkdirAgentSync(dirname(targetPath))
    rmSync(finalTempPath, { force: true })
    await moveToTargetFilesystem(decodedPath, finalTempPath)
    await chownAgentPath(finalTempPath)
    signal?.throwIfAborted()
    await rename(finalTempPath, targetPath)

    return { size: statSync(targetPath).size }
  } catch (error) {
    removePathBestEffort(finalTempPath)
    throw error
  } finally {
    rmSync(tempDir, { recursive: true, force: true })
  }
}

/**
 * Pushes one regular file from the Agent Home to the relay URL.
 *
 * The identity of the file (`dev`/`ino`) plus its size and mtime are read
 * before the upload and compared after it: a replacement during the transfer
 * can reproduce the size and mtime but not the inode, and the control plane
 * must not treat bytes from a replaced file as a successful read.
 */
export async function pushFile(
  config: AgentHomeConfig,
  request: RelayTransferRequest,
  signal?: AbortSignal
): Promise<RelayTransferResult> {
  signal?.throwIfAborted()
  safeTransferID(request.transferId)
  const name = request.homeRelativePath
  const maxBytes = boundedByteCount(request.maxBytes)
  const { filePath, stat } = openPushSource(config, name)

  if (stat.size > maxBytes) {
    throw new FileTransferError('file_too_large', `file exceeds ${maxBytes} bytes: ${name}`)
  }

  await uploadFromFile(request.url, filePath, stat.size, signal)

  if (!sourceStillStable(filePath, stat)) {
    throw new FileTransferError('file_changed', `file changed during read: ${name}`)
  }

  return { size: stat.size }
}

/**
 * Pushes several regular files under one directory as one bundle, so a
 * commit of many new files costs one transfer.
 *
 * Each entry is a 4-byte big-endian path length, the UTF-8 path relative to
 * the directory, an 8-byte big-endian content length, and the content. The
 * bundle is written to the transfer scratch directory first, because the
 * relay needs the content length up front. Every file is checked for
 * replacement or change after the upload, as for a single push.
 */
export async function pushBundle(
  config: AgentHomeConfig,
  request: RelayTransferRequest & { bundlePaths: string[] },
  signal?: AbortSignal
): Promise<RelayTransferResult> {
  signal?.throwIfAborted()
  const transferID = safeTransferID(request.transferId)
  const base = request.homeRelativePath
  const maxBytes = boundedByteCount(request.maxBytes)
  const sources = request.bundlePaths.map(entry => {
    const path = bundleEntryPath(entry)
    return { path, ...openPushSource(config, `${base}/${path}`) }
  })
  const total = sources.reduce(
    (sum, source) => sum + bundleHeaderBytes + Buffer.byteLength(source.path, 'utf8') + source.stat.size,
    0
  )
  if (total > maxBytes) {
    throw new FileTransferError('file_too_large', `bundle exceeds ${maxBytes} bytes: ${base}`)
  }

  const tempDir = scratchDirectoryFor(transferID)
  const bundlePath = join(tempDir, 'bundle')
  rmSync(tempDir, { recursive: true, force: true })
  mkdirSync(tempDir, { recursive: true })
  try {
    const bundle = await open(bundlePath, 'w')
    try {
      for (const source of sources) {
        signal?.throwIfAborted()
        const name = Buffer.from(source.path, 'utf8')
        const header = Buffer.alloc(bundleHeaderBytes + name.byteLength)
        header.writeUInt32BE(name.byteLength, 0)
        name.copy(header, 4)
        header.writeBigUInt64BE(BigInt(source.stat.size), 4 + name.byteLength)
        await bundle.write(header)
        // Each entry carries exactly the size in its header, so a file that
        // changes size fails the transfer instead of shifting later entries.
        let written = 0
        for await (const chunk of Bun.file(source.filePath).stream()) {
          signal?.throwIfAborted()
          written += chunk.byteLength
          if (written > source.stat.size) break
          await bundle.write(chunk)
        }
        if (written !== source.stat.size) {
          throw new FileTransferError('file_changed', `file changed during read: ${base}/${source.path}`)
        }
      }
    } finally {
      await bundle.close()
    }
    await uploadFromFile(request.url, bundlePath, total, signal)
  } finally {
    rmSync(tempDir, { recursive: true, force: true })
  }

  for (const source of sources) {
    if (!sourceStillStable(source.filePath, source.stat)) {
      throw new FileTransferError('file_changed', `file changed during read: ${base}/${source.path}`)
    }
  }
  return { size: total }
}

/** Length fields of one bundle entry: a 4-byte path length and an 8-byte content length. */
const bundleHeaderBytes = 12

/** A bundle path stays inside its directory: relative, with no empty, `.`, or `..` segment. */
function bundleEntryPath(path: string): string {
  const valid =
    path.length > 0 &&
    !path.startsWith('/') &&
    path.split('/').every(segment => segment !== '' && segment !== '.' && segment !== '..')
  if (!valid) throw new Error(`invalid bundle path: ${path}`)
  return path
}

function openPushSource(config: AgentHomeConfig, homeRelativePath: string): { filePath: string; stat: Stats } {
  const lexicalFilePath = homePath(config, homeRelativePath)

  try {
    const filePath = assertExistingHomePath(config, lexicalFilePath, homeRelativePath)
    const stat = statSync(filePath)
    if (!stat.isFile()) {
      throw new FileTransferError('not_regular_file', `not a regular file: ${homeRelativePath}`)
    }
    return { filePath, stat }
  } catch (error) {
    if (error instanceof FileTransferError) throw error

    switch (nodeErrorCode(error)) {
      case 'ENOENT':
      case 'ENOTDIR':
        throw new FileTransferError('file_not_found', `file does not exist: ${homeRelativePath}`)

      case 'EISDIR':
        throw new FileTransferError('not_regular_file', `not a regular file: ${homeRelativePath}`)

      default:
        throw error
    }
  }
}

async function downloadToFile(url: string, path: string, maxBytes: number, signal?: AbortSignal): Promise<void> {
  let response: Response
  try {
    response = await fetch(url, { signal })
  } catch (error) {
    throw new FileTransferError('relay_failed', `relay request failed: ${errorMessage(error)}`)
  }

  if (!response.ok) {
    throw new FileTransferError('relay_failed', `relay responded with HTTP ${response.status}`)
  }

  const declaredLength = Number(response.headers.get('content-length') ?? '0')
  if (Number.isFinite(declaredLength) && declaredLength > maxBytes) {
    throw new FileTransferError('file_too_large', `relay body exceeds ${maxBytes} bytes`)
  }

  const writer = Bun.file(path).writer()
  let received = 0
  try {
    if (response.body) {
      for await (const chunk of response.body) {
        received += chunk.byteLength
        if (received > maxBytes) {
          throw new FileTransferError('file_too_large', `relay body exceeds ${maxBytes} bytes`)
        }
        writer.write(chunk)
      }
    }
    await writer.end()
  } catch (error) {
    try {
      await writer.end()
    } catch {
      // The partial file is discarded with the scratch directory.
    }
    if (error instanceof FileTransferError) throw error
    throw new FileTransferError('relay_failed', `relay stream failed: ${errorMessage(error)}`)
  }
}

async function uploadFromFile(url: string, path: string, size: number, signal?: AbortSignal): Promise<void> {
  let response: Response
  try {
    response = await fetch(url, {
      signal,
      method: 'PUT',
      body: Bun.file(path),
      headers: {
        'content-type': 'application/octet-stream',
        'content-length': String(size)
      }
    })
  } catch (error) {
    throw new FileTransferError('relay_failed', `relay request failed: ${errorMessage(error)}`)
  }

  if (!response.ok) {
    throw new FileTransferError('relay_failed', `relay responded with HTTP ${response.status}`)
  }
}

function sourceStillStable(filePath: string, initial: Stats): boolean {
  let current: Stats
  try {
    current = statSync(filePath)
  } catch {
    return false
  }
  return (
    current.isFile() &&
    current.dev === initial.dev &&
    current.ino === initial.ino &&
    current.size === initial.size &&
    current.mtimeMs === initial.mtimeMs
  )
}

function boundedByteCount(value: bigint): number {
  if (value <= 0n || value > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new Error(`invalid max_bytes: ${value}`)
  }
  return Number(value)
}

async function moveToTargetFilesystem(sourcePath: string, targetPath: string): Promise<void> {
  try {
    await rename(sourcePath, targetPath)
  } catch (error) {
    if (nodeErrorCode(error) !== 'EXDEV') throw error

    await copyFile(sourcePath, targetPath)
  }
}

function removePathBestEffort(path: string): void {
  try {
    rmSync(path, { force: true })
  } catch {
    // Parent-path conflicts can make best-effort temp cleanup itself fail.
  }
}
