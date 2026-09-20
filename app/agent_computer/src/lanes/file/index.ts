import type { MessageInitShape } from '@bufbuild/protobuf'
import type {
  WorkerFileDeleteRequest,
  WorkerFileDeleteResponseSchema,
  WorkerFileListRequest,
  WorkerFileListResponseSchema,
  WorkerFileMoveRequest,
  WorkerFileMoveResponseSchema,
  WorkerFileTransferRequest,
  WorkerFileTransferResponseSchema
} from '../../fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { pullFile, pushFile } from './relay'
import type { FileLaneState } from './types'
import { deletePath, listPath, movePath } from './vfs'
import type { WorkerConfig } from '../../worker/config'

export { FileTransferError, type FileTransferErrorCode } from './errors'
export type { FileLaneState } from './types'

/**
 * Worker-owned file operations that the control plane calls over RPC.
 *
 * Bulk bytes move over the HTTP relay URL in each transfer request; the
 * RPC reply only reports the result. The lane state holds the fingerprint
 * cache, nothing else survives one call.
 */
export function createFileLaneState(): FileLaneState {
  return { fingerprints: new Map() }
}

export async function handleWorkerFilePull(
  config: WorkerConfig,
  state: FileLaneState,
  request: WorkerFileTransferRequest
): Promise<MessageInitShape<typeof WorkerFileTransferResponseSchema>> {
  const result = await pullFile(config, state, request)
  return transferResponse(result)
}

export async function handleWorkerFilePush(
  config: WorkerConfig,
  state: FileLaneState,
  request: WorkerFileTransferRequest
): Promise<MessageInitShape<typeof WorkerFileTransferResponseSchema>> {
  const result = await pushFile(config, state, request)
  return transferResponse(result)
}

export function handleWorkerFileList(
  config: WorkerConfig,
  request: WorkerFileListRequest
): MessageInitShape<typeof WorkerFileListResponseSchema> {
  const result = listPath(config, request.root, request.relativePath, request.recursive, Number(request.maxEntries))
  return {
    root: result.address.root,
    relativePath: result.address.relativePath,
    truncated: result.truncated,
    entries: result.entries.map(entry => ({
      relativePath: entry.relative_path,
      kind: entry.kind,
      size: BigInt(entry.size),
      modifiedUnixMs: BigInt(entry.modified_unix_ms)
    }))
  }
}

export async function handleWorkerFileMove(
  config: WorkerConfig,
  state: FileLaneState,
  request: WorkerFileMoveRequest
): Promise<MessageInitShape<typeof WorkerFileMoveResponseSchema>> {
  const result = await movePath(
    config,
    state,
    request.root,
    request.fromRelativePath,
    request.toRelativePath,
    request.overwrite
  )
  return {
    root: result.from.root,
    fromRelativePath: result.from.relativePath,
    toRelativePath: result.to.relativePath
  }
}

export async function handleWorkerFileDelete(
  config: WorkerConfig,
  state: FileLaneState,
  request: WorkerFileDeleteRequest
): Promise<MessageInitShape<typeof WorkerFileDeleteResponseSchema>> {
  const result = await deletePath(config, state, request.root, request.relativePath, request.recursive)
  return { root: result.address.root, relativePath: result.address.relativePath }
}

function transferResponse(result: {
  address: { root: string; relativePath: string }
  size: number
  xxh3_128: string
}): MessageInitShape<typeof WorkerFileTransferResponseSchema> {
  return {
    root: result.address.root,
    relativePath: result.address.relativePath,
    size: BigInt(result.size),
    xxh3128: result.xxh3_128
  }
}
