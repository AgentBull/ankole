import type { FileFrameSender } from '../../fabric/fabric'
import type { WorkerConfig } from '../../worker/config'
import type { FileRoot } from './roots'

export type { FileRoot } from './roots'

export type FingerprintMode = 'none' | 'xxh3_128'

export type FileAddress = {
  root: FileRoot
  relativePath: string
  virtualPath: string
}

export type FingerprintCacheEntry = {
  size: number
  mtimeMs: number
  xxh3_128: string
}

export type PutTransfer = {
  transferID: string
  address: FileAddress
  targetPath: string
  tempDir: string
  decodedPath: string
  nextSequence: number
  nextOffset: number
  expectedOriginalSize: number
  decodedSize: number
}

export type GetTransfer = {
  transferID: string
  address: FileAddress
  filePath: string
  fd: number
  fileSize: number
  readOffset: number
  nextSequence: number
  nextOffset: number
  credit: number
  chunksSent: number
  /**
   * Identity of the file the descriptor was opened on, taken from the open
   * descriptor itself. `dev`/`ino` are what make the completion check an
   * identity check: size and mtime alone cannot tell the original file from a
   * replacement that happens to match both.
   */
  initialDev: number
  initialIno: number
  initialSize: number
  initialMtimeMs: number
  draining: boolean
  finished?: boolean
}

export type FileTransferState = {
  puts: Map<string, PutTransfer>
  gets: Map<string, GetTransfer>
  fingerprints: Map<string, FingerprintCacheEntry>
}

export type FileTransferContext = {
  config: WorkerConfig
  sender: FileFrameSender
  state: FileTransferState
}

export type ListEntry = {
  relative_path: string
  kind: 'file' | 'directory' | 'other'
  size: number
  modified_unix_ms: number
}
