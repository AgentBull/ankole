import { match } from '@agentbull/active-support'
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
import { FileTransferError } from './errors'
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
import { errorMessage } from '../../common/errors'

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
  const transferID = textFrame(frames[2]) || 'unknown'
  let command = 'unknown'

  try {
    if (!isFileTransferFrame(frames)) {
      throw new Error('invalid file-transfer protocol marker')
    }

    command = requiredTextFrame(frames[1], 'command')
    await match(command)
      .with('WRITE_OPEN', () => handleWriteOpen(context, transferID, frames))
      .with('DATA', () => handleData(context, transferID, frames))
      .with('WRITE_COMMIT', () => handleWriteCommit(context, transferID))
      .with('WRITE_ABORT', () => handleWriteAbort(context, transferID))
      .with('READ_OPEN', () => handleReadOpen(context, transferID, frames))
      .with('READ_ABORT', () => handleReadAbort(context, transferID))
      .with('CREDIT', () => sendReadData(context, transferID, frames))
      .with('STAT', async () => {
        const result = await statPath(context.config, context.state, frames)
        await sendFrame(context.sender, [
          'STAT_OK',
          transferID,
          result.address.virtualPath,
          result.kind,
          u64Frame(result.size),
          u64Frame(result.modifiedUnixMs),
          result.fingerprint
        ])
      })
      .with('DELETE', async () => {
        const result = await deletePath(context.config, context.state, frames)
        await sendFrame(context.sender, ['DELETE_OK', transferID, result.address.virtualPath])
      })
      .with('MOVE', async () => {
        const result = await movePath(context.config, context.state, frames)
        await sendFrame(context.sender, ['MOVE_OK', transferID, result.from.virtualPath, result.to.virtualPath])
      })
      .with('LIST', async () => {
        const result = listPath(context.config, frames)
        await sendFrame(context.sender, [
          'LIST_OK',
          transferID,
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
      cleanupWriteTransfer(context, transferID)
    }
    await sendError(
      context.sender,
      transferID,
      error instanceof FileTransferError ? error.code : 'operation_failed',
      errorMessage(error)
    )
  }
}
