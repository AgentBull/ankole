import { zstdCompressBlock } from '@ankole/kernel'
import { closeSync, fstatSync, openSync, readSync, statSync } from 'node:fs'
import type { Stats } from 'node:fs'
import {
  boolFrame,
  chunkSize,
  fingerprintMode,
  readU64Frame,
  requiredTextFrame,
  sendError,
  sendFrame,
  u64Frame,
  zstdLevel
} from './codec'
import { FileTransferError, type FileTransferErrorCode } from './errors'
import { fileFingerprint } from './fingerprint'
import { assertExistingFileAddress, parseVirtualPathFrame, resolveFileAddress } from './path-security'
import type { FileAddress, FileTransferContext, GetTransfer } from './types'
import { errorMessage, nodeErrorCode } from '../../common/errors'

export async function handleReadOpen(
  context: FileTransferContext,
  transferID: string,
  frames: Buffer[]
): Promise<void> {
  if (context.state.gets.has(transferID)) {
    throw new Error(`file transfer already exists: ${transferID}`)
  }

  const address = parseVirtualPathFrame(frames[3], 'read path')
  const fingerprint = fingerprintMode(requiredTextFrame(frames[4], 'fingerprint'))
  const { filePath, fd, stableStat } = openReadSource(context, address)

  const transfer: GetTransfer = {
    transferID,
    address,
    filePath,
    fd,
    fileSize: stableStat.size,
    readOffset: 0,
    nextSequence: 0,
    nextOffset: 0,
    credit: 0,
    chunksSent: 0,
    initialDev: stableStat.dev,
    initialIno: stableStat.ino,
    initialSize: stableStat.size,
    initialMtimeMs: stableStat.mtimeMs,
    draining: false
  }
  context.state.gets.set(transferID, transfer)

  try {
    await sendFrame(context.sender, [
      'READ_READY',
      transferID,
      address.virtualPath,
      u64Frame(stableStat.size),
      fingerprint === 'none' ? '' : await fileFingerprint(context.state, address.root, address.relativePath, filePath)
    ])
  } catch (error) {
    handleReadAbort(context, transferID)
    throw error
  }
}

function openReadSource(
  context: FileTransferContext,
  address: FileAddress
): { filePath: string; fd: number; stableStat: Stats } {
  const lexicalFilePath = resolveFileAddress(context.config, address)
  let fd = -1

  try {
    const filePath = assertExistingFileAddress(context.config, address, lexicalFilePath)
    fd = openSync(filePath, 'r')
    const stableStat = fstatSync(fd, { bigint: false })

    if (!stableStat.isFile()) {
      throw new FileTransferError('not_regular_file', `not a regular file: ${address.virtualPath}`)
    }

    return { filePath, fd, stableStat }
  } catch (error) {
    if (fd !== -1) {
      try {
        closeSync(fd)
      } catch {
        // The read did not start, so only best-effort descriptor cleanup remains.
      }
    }

    if (error instanceof FileTransferError) throw error

    switch (nodeErrorCode(error)) {
      case 'ENOENT':
        throw new FileTransferError('file_not_found', `file does not exist: ${address.virtualPath}`)

      case 'EISDIR':
        throw new FileTransferError('not_regular_file', `not a regular file: ${address.virtualPath}`)

      default:
        throw error
    }
  }
}

export function sendReadData(context: FileTransferContext, transferID: string, frames: Buffer[]): void {
  const transfer = context.state.gets.get(transferID)
  if (!transfer) {
    throw new Error(`unknown read transfer: ${transferID}`)
  }

  transfer.credit += readU64Frame(frames[3], 'credit')
  void drainReadTransfer(context, transfer)
}

export function handleReadAbort(context: FileTransferContext, transferID: string): void {
  const transfer = context.state.gets.get(transferID)
  if (!transfer) return

  closeTransferFile(transfer)
  context.state.gets.delete(transferID)
  transfer.finished = true
}

async function drainReadTransfer(context: FileTransferContext, transfer: GetTransfer): Promise<void> {
  if (transfer.finished || transfer.draining) return

  transfer.draining = true
  try {
    // Credit is a wire-byte budget. A block's compressed size is only known after
    // compression, so an incompressible block can overshoot the budget and drive
    // credit negative by up to one block. The control plane returns CREDIT equal
    // to each received chunk's wire size, so credit recovers on the next drain.
    // EOF chunks never receive a top-up, so finishing must not depend on credit.
    while (transfer.credit > 0 && transfer.readOffset < transfer.fileSize && !transfer.finished) {
      const bytesToRead = Math.min(chunkSize, transfer.credit, transfer.fileSize - transfer.readOffset)
      const block = readTransferBlock(transfer, bytesToRead)

      let compressed: Buffer
      try {
        compressed = await zstdCompressBlock(block, zstdLevel)
      } catch (error) {
        await finishReadTransferWithError(context, transfer, `zstd encode failed: ${errorMessage(error)}`)
        return
      }

      const eof = transfer.readOffset === transfer.fileSize
      try {
        await sendFrame(context.sender, [
          'DATA',
          transfer.transferID,
          u64Frame(transfer.nextSequence),
          u64Frame(transfer.nextOffset),
          boolFrame(eof),
          compressed
        ])
      } catch {
        finishReadTransferAfterSendFailure(context, transfer)
        return
      }

      transfer.nextSequence += 1
      transfer.nextOffset += compressed.byteLength
      transfer.credit -= compressed.byteLength
      transfer.chunksSent += 1
    }

    await maybeFinishReadTransfer(context, transfer)
  } catch (error) {
    await finishReadTransferWithError(
      context,
      transfer,
      errorMessage(error),
      error instanceof FileTransferError ? error.code : 'operation_failed'
    )
  } finally {
    transfer.draining = false
    // Credit may have arrived while this drain was in flight (sendReadData would
    // have bailed on `draining`). Re-kick if there is still work to do.
    if (!transfer.finished && transfer.credit > 0 && transfer.readOffset < transfer.fileSize) {
      void drainReadTransfer(context, transfer)
    }
  }
}

function readTransferBlock(transfer: GetTransfer, size: number): Buffer {
  const buffer = Buffer.alloc(size)
  let totalRead = 0
  while (totalRead < size) {
    const bytesRead = readSync(transfer.fd, buffer, totalRead, size - totalRead, transfer.readOffset)
    if (bytesRead === 0) {
      throw new FileTransferError('file_changed', `file changed during read: ${transfer.address.virtualPath}`)
    }
    totalRead += bytesRead
    transfer.readOffset += bytesRead
  }

  return buffer
}

async function maybeFinishReadTransfer(context: FileTransferContext, transfer: GetTransfer): Promise<void> {
  if (transfer.finished || transfer.readOffset < transfer.fileSize) {
    return
  }

  if (!readSourceStillStable(transfer)) {
    await finishReadTransferWithError(
      context,
      transfer,
      `file changed during read: ${transfer.address.virtualPath}`,
      'file_changed'
    )
    return
  }

  transfer.finished = true
  closeTransferFile(transfer)
  context.state.gets.delete(transfer.transferID)
  try {
    await sendFrame(context.sender, [
      'READ_DONE',
      transfer.transferID,
      u64Frame(transfer.chunksSent),
      u64Frame(transfer.nextOffset)
    ])
  } catch {
    // The transfer is already cleaned up. A broken sender cannot carry an ERROR either.
  }
}

/**
 * Reports whether the path still names the file the sent bytes came from.
 *
 * RuntimeFabric does not accept bytes from a stale descriptor as a successful
 * read, so this compares the file's identity (`dev`/`ino`), not only its
 * observable size and mtime: a replacement can reproduce both, but not the
 * inode the descriptor is bound to.
 */
function readSourceStillStable(transfer: GetTransfer): boolean {
  let current: Stats
  try {
    current = statSync(transfer.filePath)
  } catch {
    return false
  }
  return (
    current.isFile() &&
    current.dev === transfer.initialDev &&
    current.ino === transfer.initialIno &&
    current.size === transfer.initialSize &&
    current.mtimeMs === transfer.initialMtimeMs
  )
}

function closeTransferFile(transfer: GetTransfer): void {
  if (transfer.fd !== -1) {
    try {
      closeSync(transfer.fd)
    } catch {
      // Best-effort close; the transfer is ending either way.
    }
    transfer.fd = -1
  }
}

async function finishReadTransferWithError(
  context: FileTransferContext,
  transfer: GetTransfer,
  message: string,
  code: FileTransferErrorCode | 'operation_failed' = 'operation_failed'
): Promise<void> {
  if (transfer.finished) return

  transfer.finished = true
  closeTransferFile(transfer)
  context.state.gets.delete(transfer.transferID)
  try {
    await sendError(context.sender, transfer.transferID, code, message)
  } catch {
    // If the sender is gone, there is no second channel for reporting the failure.
  }
}

function finishReadTransferAfterSendFailure(context: FileTransferContext, transfer: GetTransfer): void {
  transfer.finished = true
  closeTransferFile(transfer)
  context.state.gets.delete(transfer.transferID)
}
