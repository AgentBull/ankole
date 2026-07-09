import { match } from '@pleisto/active-support'
import {
  boolFrame,
  encodeEntries,
  isFileTransferFrame,
  requiredTextFrame,
  sendError,
  sendFrame,
  textFrame,
  u64Frame
} from './codec'
import { handleReadAbort, handleReadOpen, sendReadData } from './transfer-read'
import {
  cleanupWriteTransfer,
  handleData,
  handleWriteAbort,
  handleWriteCommit,
  handleWriteOpen
} from './transfer-write'
import { deletePath, listPath, movePath, statPath } from './vfs'
import type { FileTransferContext, FileTransferState } from './types'
import type { FileFrameSender } from '../../fabric/fabric'
import type { WorkerConfig } from '../../worker/config'

export type FileTransferLane = {
  handle(frames: Buffer[]): Promise<void>
}

export function createFileTransferLane(config: WorkerConfig, sender: FileFrameSender): FileTransferLane {
  const context: FileTransferContext = {
    config,
    sender,
    state: createState()
  }

  return {
    handle: frames => dispatchFrame(context, frames)
  }
}

function createState(): FileTransferState {
  return { puts: new Map(), gets: new Map(), fingerprints: new Map() }
}

async function dispatchFrame(context: FileTransferContext, frames: Buffer[]): Promise<void> {
  const transferId = textFrame(frames[2]) || 'unknown'
  let command = 'unknown'

  try {
    if (!isFileTransferFrame(frames)) {
      throw new Error('invalid file-transfer protocol marker')
    }

    command = requiredTextFrame(frames[1], 'command')
    await match(command)
      .with('WRITE_OPEN', () => handleWriteOpen(context, transferId, frames))
      .with('DATA', () => handleData(context, transferId, frames))
      .with('WRITE_COMMIT', () => handleWriteCommit(context, transferId))
      .with('WRITE_ABORT', () => handleWriteAbort(context, transferId))
      .with('READ_OPEN', () => handleReadOpen(context, transferId, frames))
      .with('READ_ABORT', () => handleReadAbort(context, transferId))
      .with('CREDIT', () => sendReadData(context, transferId, frames))
      .with('STAT', async () => {
        const result = statPath(context.config, context.state, frames)
        await sendFrame(context.sender, [
          'STAT_OK',
          transferId,
          result.address.virtualPath,
          result.kind,
          u64Frame(result.size),
          u64Frame(result.modifiedUnixMs),
          result.fingerprint
        ])
      })
      .with('DELETE', async () => {
        const result = await deletePath(context.config, context.state, frames)
        await sendFrame(context.sender, ['DELETE_OK', transferId, result.address.virtualPath])
      })
      .with('MOVE', async () => {
        const result = await movePath(context.config, context.state, frames)
        await sendFrame(context.sender, ['MOVE_OK', transferId, result.from.virtualPath, result.to.virtualPath])
      })
      .with('LIST', async () => {
        const result = listPath(context.config, frames)
        await sendFrame(context.sender, [
          'LIST_OK',
          transferId,
          result.address.virtualPath,
          boolFrame(result.recursive),
          boolFrame(result.truncated),
          encodeEntries(result.entries)
        ])
      })
      .otherwise(() => {
        throw new Error(`unsupported file lane command: ${command}`)
      })
    return
  } catch (error) {
    if (command === 'DATA') {
      cleanupWriteTransfer(context, transferId)
    }
    await sendError(
      context.sender,
      transferId,
      'operation_failed',
      error instanceof Error ? error.message : String(error)
    )
  }
}
