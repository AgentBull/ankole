import { zstdCompressBlock } from '@ankole/kernel'
import { closeSync, existsSync, openSync, readSync, statSync } from 'node:fs'
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
import { fileFingerprint } from './fingerprint'
import { parseVirtualPathFrame, resolveFileAddress } from './path-security'
import type { FileTransferContext, GetTransfer } from './types'

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
  const filePath = resolveFileAddress(context.config, address)
  if (!existsSync(filePath)) {
    throw new Error(`file does not exist: ${address.virtualPath}`)
  }
  if (!statSync(filePath).isFile()) {
    throw new Error(`not a regular file: ${address.virtualPath}`)
  }

  const stableStat = statSync(filePath)
  const fd = openSync(filePath, 'r')

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
      fingerprint === 'none' ? '' : fileFingerprint(context.state, address.root, address.relativePath, filePath)
    ])
  } catch (error) {
    handleReadAbort(context, transferID)
    throw error
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
      if (!block) break

      let compressed: Buffer
      try {
        compressed = await zstdCompressBlock(block, zstdLevel)
      } catch (error) {
        await finishReadTransferWithError(
          context,
          transfer,
          `zstd encode failed: ${error instanceof Error ? error.message : String(error)}`
        )
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
    await finishReadTransferWithError(context, transfer, error instanceof Error ? error.message : String(error))
  } finally {
    transfer.draining = false
    // Credit may have arrived while this drain was in flight (sendReadData would
    // have bailed on `draining`). Re-kick if there is still work to do.
    if (!transfer.finished && transfer.credit > 0 && transfer.readOffset < transfer.fileSize) {
      void drainReadTransfer(context, transfer)
    }
  }
}

function readTransferBlock(transfer: GetTransfer, size: number): Buffer | null {
  const buffer = Buffer.alloc(size)
  let totalRead = 0
  while (totalRead < size) {
    let bytesRead: number
    try {
      bytesRead = readSync(transfer.fd, buffer, totalRead, size - totalRead, transfer.readOffset)
    } catch {
      return null
    }
    if (bytesRead === 0) break
    totalRead += bytesRead
    transfer.readOffset += bytesRead
  }

  return totalRead === 0 ? null : buffer.subarray(0, totalRead)
}

async function maybeFinishReadTransfer(context: FileTransferContext, transfer: GetTransfer): Promise<void> {
  if (transfer.finished || transfer.readOffset < transfer.fileSize) {
    return
  }

  if (!readSourceStillStable(transfer)) {
    await finishReadTransferWithError(context, transfer, `file changed during read: ${transfer.address.virtualPath}`)
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

function readSourceStillStable(transfer: GetTransfer): boolean {
  if (!existsSync(transfer.filePath)) return false
  const current = statSync(transfer.filePath)
  return current.isFile() && current.size === transfer.initialSize && current.mtimeMs === transfer.initialMtimeMs
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
  message: string
): Promise<void> {
  if (transfer.finished) return

  transfer.finished = true
  closeTransferFile(transfer)
  context.state.gets.delete(transfer.transferID)
  try {
    await sendError(context.sender, transfer.transferID, 'operation_failed', message)
  } catch {
    // If the sender is gone, there is no second channel for reporting the failure.
  }
}

function finishReadTransferAfterSendFailure(context: FileTransferContext, transfer: GetTransfer): void {
  transfer.finished = true
  closeTransferFile(transfer)
  context.state.gets.delete(transfer.transferID)
}
