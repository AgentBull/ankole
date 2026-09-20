import { mkdirSync, rmSync, statSync } from 'node:fs'
import type { Stats } from 'node:fs'
import { chmod, copyFile, rename } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { FileTransferError } from './errors'
import { fileFingerprint } from './fingerprint'
import {
  assertCreatableFileAddress,
  assertExistingFileAddress,
  fileAddress,
  resolveFileAddress,
  safeTransferID,
  scratchDirectoryFor
} from './path-security'
import type { FileAddress, FileLaneState } from './types'
import type { WorkerConfig } from '../../worker/config'
import { errorMessage, nodeErrorCode } from '../../common/errors'

/**
 * One relay transfer as the control plane requests it. `url` is a one-time
 * signed bearer credential on the issuing control-plane Pod: it is used for
 * exactly one HTTP request and never written to logs or errors.
 */
export type RelayTransferRequest = {
  transferId: string
  url: string
  root: string
  relativePath: string
  maxBytes: bigint
}

export type RelayTransferResult = {
  address: FileAddress
  size: number
  xxh3_128: string
}

/**
 * Pulls one file from the relay URL into a worker-visible root.
 *
 * Bytes stream into the transfer scratch directory and reach the target path
 * only through an atomic rename, so a failed or oversize pull never leaves a
 * partial file where the Agent can read it.
 */
export async function pullFile(
  config: WorkerConfig,
  state: FileLaneState,
  request: RelayTransferRequest
): Promise<RelayTransferResult> {
  const transferID = safeTransferID(request.transferId)
  const address = fileAddress(request.root, request.relativePath)
  const maxBytes = boundedByteCount(request.maxBytes)
  const targetPath = assertCreatableFileAddress(config, address, resolveFileAddress(config, address))
  const tempDir = scratchDirectoryFor(transferID)
  const decodedPath = join(tempDir, 'decoded')
  const finalTempPath = `${targetPath}.ankole-transfer-${transferID}.tmp`

  rmSync(tempDir, { recursive: true, force: true })
  mkdirSync(tempDir, { recursive: true })

  try {
    await downloadToFile(request.url, decodedPath, maxBytes)

    mkdirSync(dirname(targetPath), { recursive: true })
    rmSync(finalTempPath, { force: true })
    await moveToTargetFilesystem(decodedPath, finalTempPath)
    await rename(finalTempPath, targetPath)
    if (address.root === 'agent_home_documents') {
      await chmod(targetPath, 0o444)
    }

    const xxh3_128 = await fileFingerprint(state, address.root, address.relativePath, targetPath)
    return { address, size: statSync(targetPath).size, xxh3_128 }
  } catch (error) {
    removePathBestEffort(finalTempPath)
    throw error
  } finally {
    rmSync(tempDir, { recursive: true, force: true })
  }
}

/**
 * Pushes one regular file from a worker-visible root to the relay URL.
 *
 * The identity of the file (`dev`/`ino`) plus its size and mtime are read
 * before the upload and compared after it: a replacement during the transfer
 * can reproduce the size and mtime but not the inode, and the control plane
 * must not treat bytes from a replaced file as a successful read.
 */
export async function pushFile(
  config: WorkerConfig,
  state: FileLaneState,
  request: RelayTransferRequest
): Promise<RelayTransferResult> {
  safeTransferID(request.transferId)
  const address = fileAddress(request.root, request.relativePath)
  const maxBytes = boundedByteCount(request.maxBytes)
  const { filePath, stat } = openPushSource(config, address)

  if (stat.size > maxBytes) {
    throw new FileTransferError('file_too_large', `file exceeds ${maxBytes} bytes: ${address.virtualPath}`)
  }

  await uploadFromFile(request.url, filePath, stat.size)

  if (!sourceStillStable(filePath, stat)) {
    throw new FileTransferError('file_changed', `file changed during read: ${address.virtualPath}`)
  }

  const xxh3_128 = await fileFingerprint(state, address.root, address.relativePath, filePath)
  return { address, size: stat.size, xxh3_128 }
}

function openPushSource(config: WorkerConfig, address: FileAddress): { filePath: string; stat: Stats } {
  const lexicalFilePath = resolveFileAddress(config, address)

  try {
    const filePath = assertExistingFileAddress(config, address, lexicalFilePath)
    const stat = statSync(filePath)
    if (!stat.isFile()) {
      throw new FileTransferError('not_regular_file', `not a regular file: ${address.virtualPath}`)
    }
    return { filePath, stat }
  } catch (error) {
    if (error instanceof FileTransferError) throw error

    switch (nodeErrorCode(error)) {
      case 'ENOENT':
      case 'ENOTDIR':
        throw new FileTransferError('file_not_found', `file does not exist: ${address.virtualPath}`)

      case 'EISDIR':
        throw new FileTransferError('not_regular_file', `not a regular file: ${address.virtualPath}`)

      default:
        throw error
    }
  }
}

async function downloadToFile(url: string, path: string, maxBytes: number): Promise<void> {
  let response: Response
  try {
    response = await fetch(url)
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

async function uploadFromFile(url: string, path: string, size: number): Promise<void> {
  let response: Response
  try {
    response = await fetch(url, {
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
