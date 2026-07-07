import { zstdDecompressBlock } from '@ankole/kernel'
import { mkdirSync, rmSync, statSync } from 'node:fs'
import { appendFile, rename, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { chunkSize, creditWindow, readBoolFrame, readU64Frame, sendFrame, u64Frame } from './codec'
import { fileFingerprint } from './fingerprint'
import { parseVirtualPathFrame, safeTransferId, scratchDirectoryFor, resolveFileAddress } from './path-security'
import type { FileTransferContext, PutTransfer } from './types'

export async function handleWriteOpen(
  context: FileTransferContext,
  transferId: string,
  frames: Buffer[]
): Promise<void> {
  if (context.state.puts.has(transferId)) {
    throw new Error(`file transfer already exists: ${transferId}`)
  }

  const address = parseVirtualPathFrame(frames[3], 'write path')
  const expectedOriginalSize = readU64Frame(frames[4], 'original_size')
  const targetPath = resolveFileAddress(context.config, address)
  const tempDir = scratchDirectoryFor(context.config, transferId)
  const decodedPath = join(tempDir, 'decoded')

  try {
    rmSync(tempDir, { recursive: true, force: true })
    mkdirSync(tempDir, { recursive: true })
    await writeFile(decodedPath, Buffer.alloc(0))
  } catch (error) {
    rmSync(tempDir, { recursive: true, force: true })
    throw error
  }

  context.state.puts.set(transferId, {
    transferId,
    address,
    targetPath,
    tempDir,
    decodedPath,
    nextSequence: 0,
    nextOffset: 0,
    expectedOriginalSize,
    decodedSize: 0
  })

  try {
    await sendFrame(context.sender, ['WRITE_READY', transferId, u64Frame(creditWindow)])
  } catch (error) {
    cleanupWriteTransfer(context, transferId)
    throw error
  }
}

export async function handleData(context: FileTransferContext, transferId: string, frames: Buffer[]): Promise<void> {
  const transfer = getPutTransfer(context, transferId)
  const sequence = readU64Frame(frames[3], 'sequence')
  const offset = readU64Frame(frames[4], 'offset')
  readBoolFrame(frames[5], 'eof')
  const chunk = frames[6]

  if (sequence !== transfer.nextSequence) {
    throw new Error(`unexpected sequence ${sequence}, expected ${transfer.nextSequence}`)
  }
  if (offset !== transfer.nextOffset) {
    throw new Error(`unexpected offset ${offset}, expected ${transfer.nextOffset}`)
  }
  if (!chunk) {
    throw new Error('DATA requires a binary chunk frame')
  }

  const decoded = await zstdDecompressBlock(chunk, chunkSize)
  await appendFile(transfer.decodedPath, decoded)
  transfer.nextSequence += 1
  transfer.nextOffset += chunk.byteLength
  transfer.decodedSize += decoded.byteLength
  await sendFrame(context.sender, ['CREDIT', transferId, u64Frame(chunk.byteLength)])
}

export async function handleWriteCommit(context: FileTransferContext, transferId: string): Promise<void> {
  const transfer = getPutTransfer(context, transferId)
  const finalTempPath = `${transfer.targetPath}.ankole-transfer-${safeTransferId(transferId)}.tmp`
  let fingerprint: string

  try {
    if (transfer.decodedSize !== transfer.expectedOriginalSize) {
      throw new Error(
        `size mismatch after file transfer: expected ${transfer.expectedOriginalSize}, got ${transfer.decodedSize}`
      )
    }

    mkdirSync(dirname(transfer.targetPath), { recursive: true })
    rmSync(finalTempPath, { force: true })
    await rename(transfer.decodedPath, finalTempPath)
    await rename(finalTempPath, transfer.targetPath)
    fingerprint = fileFingerprint(
      context.state,
      transfer.address.root,
      transfer.address.relativePath,
      transfer.targetPath
    )
    context.state.puts.delete(transferId)
    rmSync(transfer.tempDir, { recursive: true, force: true })
  } catch (error) {
    removePathBestEffort(finalTempPath)
    cleanupWriteTransfer(context, transferId)
    throw error
  }

  await sendFrame(context.sender, [
    'WRITE_COMMITTED',
    transferId,
    transfer.address.virtualPath,
    u64Frame(statSync(transfer.targetPath).size),
    fingerprint
  ])
}

export async function handleWriteAbort(context: FileTransferContext, transferId: string): Promise<void> {
  const transfer = context.state.puts.get(transferId)
  if (transfer) {
    rmSync(transfer.tempDir, { recursive: true, force: true })
    context.state.puts.delete(transferId)
  }

  await sendFrame(context.sender, ['WRITE_ABORTED', transferId])
}

export function cleanupWriteTransfer(context: FileTransferContext, transferId: string): void {
  const transfer = context.state.puts.get(transferId)
  if (!transfer) return

  rmSync(transfer.tempDir, { recursive: true, force: true })
  context.state.puts.delete(transferId)
}

function removePathBestEffort(path: string): void {
  try {
    rmSync(path, { force: true })
  } catch {
    // Parent-path conflicts can make best-effort temp cleanup itself fail.
  }
}

function getPutTransfer(context: FileTransferContext, transferId: string): PutTransfer {
  const transfer = context.state.puts.get(transferId)
  if (!transfer) {
    throw new Error(`unknown file transfer: ${transferId}`)
  }
  return transfer
}
